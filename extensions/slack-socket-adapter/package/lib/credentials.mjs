// Credential backends for the app-level xapp- token. Every backend returns
// the token or throws AuthError; no backend ever logs, prints, or stores it.
//
//   keychain     macOS keychain: security find-generic-password -s <service> -w
//   secret-tool  libsecret (GNOME Keyring, KWallet bridge, KeePassXC):
//                secret-tool lookup service <service>
//   file         one regular file, owned by the current user, mode 0600,
//                holding only the token (for headless hosts without a keyring)

import { execFile } from "node:child_process";
import { constants, statSync } from "node:fs";
import { open } from "node:fs/promises";
import { AuthError } from "./errors.mjs";

const DEFAULT_SECURITY_BIN = "/usr/bin/security";
const DEFAULT_SECRET_TOOL_BIN = "secret-tool";
const EXEC_TIMEOUT_MS = 10000;
const MAX_FILE_BYTES = 4096;
const TOKEN_RE = /^xapp-[A-Za-z0-9-]{10,}$/;

function checked(token, where) {
  if (!TOKEN_RE.test(token)) {
    throw new AuthError(`${where} does not hold an xapp- app-level token (empty or wrong token type)`);
  }
  return token;
}

function run(bin, args, env) {
  return new Promise((resolve, reject) => {
    execFile(bin, args, { timeout: EXEC_TIMEOUT_MS, maxBuffer: 16384, env }, (error, stdout) => {
      if (error) reject(error);
      else resolve(String(stdout).trim());
    });
  });
}

async function fromKeychain(service, env) {
  const bin = env.SLACK_SOCKET_ADAPTER_SECURITY || DEFAULT_SECURITY_BIN;
  let token;
  try {
    token = await run(bin, ["find-generic-password", "-s", service, "-w"], { PATH: "/usr/bin:/bin", HOME: env.HOME || "" });
  } catch {
    throw new AuthError(`keychain item "${service}" is missing or unreadable`);
  }
  return checked(token, `keychain item "${service}"`);
}

function isSocket(file) {
  try {
    return statSync(file).isSocket();
  } catch {
    return false;
  }
}

// secret-tool needs the user's D-Bus session bus. The firstmate host passes
// only HOME and XDG_* config paths, so when the bus address is absent, use the
// systemd per-user bus socket at $XDG_RUNTIME_DIR/bus or /run/user/<uid>/bus.
export function secretToolEnvironment(env, uid = typeof process.getuid === "function" ? process.getuid() : null) {
  const child = { PATH: env.PATH || "/usr/local/bin:/usr/bin:/bin", HOME: env.HOME || "" };
  const runtimeDir = env.XDG_RUNTIME_DIR || (uid === null ? "" : `/run/user/${uid}`);
  if (runtimeDir) child.XDG_RUNTIME_DIR = runtimeDir;
  if (env.DBUS_SESSION_BUS_ADDRESS) {
    child.DBUS_SESSION_BUS_ADDRESS = env.DBUS_SESSION_BUS_ADDRESS;
  } else if (runtimeDir && isSocket(`${runtimeDir}/bus`)) {
    child.DBUS_SESSION_BUS_ADDRESS = `unix:path=${runtimeDir}/bus`;
  }
  return child;
}

async function fromSecretTool(service, env) {
  const bin = env.SLACK_SOCKET_ADAPTER_SECRET_TOOL || DEFAULT_SECRET_TOOL_BIN;
  let token;
  try {
    token = await run(bin, ["lookup", "service", service], secretToolEnvironment(env));
  } catch (error) {
    if (error && error.code === "ENOENT") {
      throw new AuthError("secret-tool is not installed (install libsecret-tools or use cred=file)");
    }
    throw new AuthError(`secret-tool item "service ${service}" is missing or the keyring is locked or unreachable`);
  }
  return checked(token, `secret-tool item "service ${service}"`);
}

async function fromFile(file) {
  let handle;
  try {
    // O_NOFOLLOW refuses a symlink; O_NONBLOCK keeps a FIFO from blocking.
    handle = await open(file, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  } catch (error) {
    if (error && error.code === "ELOOP") throw new AuthError(`credential file "${file}" is a symlink`);
    throw new AuthError(`credential file "${file}" is missing or unreadable`);
  }
  try {
    const stat = await handle.stat();
    if (!stat.isFile()) throw new AuthError(`credential file "${file}" is not a regular file`);
    if (typeof process.getuid === "function" && stat.uid !== process.getuid()) {
      throw new AuthError(`credential file "${file}" is not owned by the current user`);
    }
    if ((stat.mode & 0o777) !== 0o600) {
      throw new AuthError(`credential file "${file}" must have mode 0600 (it has ${(stat.mode & 0o777).toString(8).padStart(4, "0")})`);
    }
    if (stat.size > MAX_FILE_BYTES) throw new AuthError(`credential file "${file}" is larger than ${MAX_FILE_BYTES} bytes`);
    const token = (await handle.readFile({ encoding: "utf8" })).trim();
    return checked(token, `credential file "${file}"`);
  } finally {
    await handle.close();
  }
}

// Reads the xapp- token with the backend the parsed configuration selects.
export function readToken(config, env = process.env) {
  switch (config.credentialBackend) {
    case "keychain":
      return fromKeychain(config.keychainService, env);
    case "secret-tool":
      return fromSecretTool(config.keychainService, env);
    case "file":
      return fromFile(config.credentialFile);
    default:
      return Promise.reject(new AuthError(`credential backend "${config.credentialBackend}" is not supported`));
  }
}
