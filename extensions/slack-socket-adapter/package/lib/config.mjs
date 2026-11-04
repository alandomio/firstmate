// Source configuration reference parsing.
//
// A source configuration reference is a bounded, non-secret string that
// firstmate stores in the registration and sends in every source.poll request.
// Grammar (keys separated by ";", order free, each key at most once):
//
//   slack-socket:v1;channels=<id>:<mode>[,<id>:<mode>...][;mentions=<id>[,<id>...]][;wait=<seconds>]
//                  [;cred=keychain|secret-tool|file][;keychain=<service>][;credfile=<absolute path>]
//
// The literal "default" stands for "slack-socket:v1" with every default below.
//
//   channels  Watched channel ids and their filter mode. Default C08D5AM39F0:all.
//             all   every new top-level human message
//             asks  only top-level human messages that mention one of the
//                   "mentions" user ids or read as a direct ask
//   mentions  User ids whose <@id> mention makes an "asks" message match.
//   wait      Long-poll window in seconds before source.poll returns
//             no-result (1..3500). Default 240, inside the default 300 s host
//             bound. Raise it only together with a larger bind --timeout-ms.
//   cred      Where the app-level xapp- token is read (credentials.mjs).
//             Default keychain on macOS, secret-tool everywhere else.
//             keychain     macOS keychain item with service <keychain>
//             secret-tool  libsecret item with attribute service=<keychain>
//             file         the file at <credfile>
//   keychain  Service name of the keychain or secret-tool item.
//             Default fm-slack-ask-devops-socket. Not allowed with cred=file.
//   credfile  Absolute path of the token file. Required with cred=file and
//             allowed only with it.
// Only item names and paths live here, never the token.

export const DEFAULT_CHANNELS = Object.freeze([{ id: "C08D5AM39F0", mode: "all" }]);
export const DEFAULT_WAIT_SECONDS = 240;
export const MAX_WAIT_SECONDS = 3500;
export const DEFAULT_KEYCHAIN_SERVICE = "fm-slack-ask-devops-socket";
const PREFIX = "slack-socket:v1";
const CHANNEL_RE = /^[CG][A-Z0-9]{2,20}$/;
const USER_RE = /^[UW][A-Z0-9]{2,20}$/;
const SERVICE_RE = /^[A-Za-z0-9._-]{1,128}$/;
const MODES = new Set(["all", "asks"]);
const BACKENDS = new Set(["keychain", "secret-tool", "file"]);
const MAX_CREDFILE_CHARS = 256;

export function defaultCredentialBackend(platform = process.platform) {
  return platform === "darwin" ? "keychain" : "secret-tool";
}

export class ConfigError extends Error {}

function fail(message) {
  throw new ConfigError(message);
}

export function parseConfigRef(reference, platform = process.platform) {
  if (typeof reference !== "string" || reference.length === 0 || reference.length > 512) {
    fail("config_ref must be a non-empty string of at most 512 characters");
  }
  const text = reference === "default" ? PREFIX : reference;
  const parts = text.split(";");
  if (parts[0] !== PREFIX) fail(`config_ref must be "default" or start with "${PREFIX}"`);
  const config = {
    channels: DEFAULT_CHANNELS.map((channel) => ({ ...channel })),
    mentions: [],
    waitSeconds: DEFAULT_WAIT_SECONDS,
    keychainService: DEFAULT_KEYCHAIN_SERVICE,
    credentialBackend: defaultCredentialBackend(platform),
    credentialFile: null,
  };
  const seen = new Set();
  for (const part of parts.slice(1)) {
    const index = part.indexOf("=");
    if (index <= 0) fail(`config_ref entry "${part}" is not key=value`);
    const key = part.slice(0, index);
    const value = part.slice(index + 1);
    if (seen.has(key)) fail(`config_ref key "${key}" appears more than once`);
    seen.add(key);
    if (key === "channels") {
      config.channels = parseChannels(value);
    } else if (key === "mentions") {
      config.mentions = parseList(value, USER_RE, "mentions user id");
    } else if (key === "wait") {
      if (!/^[0-9]{1,4}$/.test(value)) fail("wait must be whole seconds");
      const seconds = Number(value);
      if (seconds < 1 || seconds > MAX_WAIT_SECONDS) fail(`wait must be 1..${MAX_WAIT_SECONDS} seconds`);
      config.waitSeconds = seconds;
    } else if (key === "keychain") {
      if (!SERVICE_RE.test(value)) fail("keychain must be a plain keychain service name");
      config.keychainService = value;
    } else if (key === "cred") {
      if (!BACKENDS.has(value)) fail("cred must be keychain, secret-tool, or file");
      config.credentialBackend = value;
    } else if (key === "credfile") {
      config.credentialFile = parseCredentialFile(value);
    } else {
      fail(`config_ref key "${key}" is not supported`);
    }
  }
  if (config.credentialBackend === "file") {
    if (config.credentialFile === null) fail("cred=file needs credfile=<absolute path>");
    if (seen.has("keychain")) fail("keychain does not apply to cred=file");
  } else if (config.credentialFile !== null) {
    fail("credfile applies only to cred=file");
  }
  // An asks channel without mentions still matches the direct-ask phrases.
  return config;
}

function parseCredentialFile(value) {
  if (value.length === 0 || value.length > MAX_CREDFILE_CHARS) fail(`credfile must be 1..${MAX_CREDFILE_CHARS} characters`);
  if (!value.startsWith("/")) fail("credfile must be an absolute path");
  if (/[\u0000-\u001f\u007f]/.test(value)) fail("credfile must not contain control characters");
  if (value.split("/").some((segment) => segment === "." || segment === "..")) fail("credfile must not contain . or .. segments");
  return value;
}

function parseList(value, pattern, label) {
  const items = value.split(",");
  if (items.length === 0 || items.length > 32) fail(`${label} list must hold 1..32 entries`);
  const unique = new Set();
  for (const item of items) {
    if (!pattern.test(item)) fail(`${label} "${item}" is not valid`);
    if (unique.has(item)) fail(`${label} "${item}" is listed twice`);
    unique.add(item);
  }
  return [...unique];
}

function parseChannels(value) {
  const entries = value.split(",");
  if (entries.length === 0 || entries.length > 32) fail("channels must hold 1..32 entries");
  const result = [];
  const ids = new Set();
  for (const entry of entries) {
    const [id, mode = "all", extra] = entry.split(":");
    if (extra !== undefined) fail(`channel entry "${entry}" has too many fields`);
    if (!CHANNEL_RE.test(id)) fail(`channel id "${id}" is not valid`);
    if (!MODES.has(mode)) fail(`channel mode "${mode}" must be all or asks`);
    if (ids.has(id)) fail(`channel id "${id}" is listed twice`);
    ids.add(id);
    result.push({ id, mode });
  }
  return result;
}
