# Slack Socket Mode adapter

`extensions/slack-socket-adapter/` is an optional, home-bound `process-event-adapter/1` package that wakes firstmate within seconds when someone posts in a watched Slack channel.
It uses Slack Socket Mode, an outgoing WebSocket from the host, so it needs no public URL, tunnel, or server.
It is inert until an operator binds it in a home; Firstmate core never loads it on its own.

The package needs Node 22 or newer, because it uses the built-in `fetch` and `WebSocket`, and it has no npm dependencies.
It runs on macOS and Linux.
[`configuration.md`](configuration.md#trusted-external-process-event-adapters-configextensionsd) owns the general bind, verify, register, and retire mechanics for external packages; this page covers only what is specific to this one.

## One listener per app token

Slack delivers each event to only one of an app's open Socket Mode connections, load-balanced across up to 10 connections per app-level token.
If two people or two homes run this listener with the same app token, each message reaches only one of them, and nobody sees every message.

Choose one model before you install:

- One listener per app: only one home, for example the person on support duty, runs the listener with the shared app token.
- One app per person: each person creates their own Slack app with the same settings and uses their own app-level token.

A one-shot `listen` run (see below) is also a connection and takes a share of the events while it runs, so stop test listeners when you are done.
A history-based polling check that reads the channels with a bot token sees every message regardless, and is a good backup for events missed while a laptop sleeps.

## What it delivers

One `source.poll` reads the app-level token, opens a Socket Mode connection, acks every envelope at once, and returns the first matching message as a `result`.
After the first match it keeps the socket open for a quarter of a second, then closes it; other matches acked in that burst go to a bounded buffer (100 messages, deduplicated by `channel:ts`) in the package state, which survives restarts.
The next poll returns the oldest buffered message before it opens a new connection.
Messages that arrive while no socket is open, between two polls, go to another open connection or are not delivered at all; the history-based polling backup above covers them.
When nothing matches before the wait window ends, it returns `no-result`, and the watcher's next reconcile starts the next poll.
The result is untrusted evidence with this shape:

```json
{"schema":"slack-socket-adapter.message.v1","channel":"C0123456789","ts":"1793785000.123456","user":"U0123456789","text":"...","text_truncated":false,"matched":"all"}
```

`text` is cut at 2,000 characters, and `matched` is `all`, `mention`, or `ask-phrase`.
Only new top-level human messages match: thread replies, edits, deletes, joins, broadcasts, and bot messages never wake firstmate.

A rejected or missing token, or Socket Mode turned off for the app, returns a failed `unavailable` response once and then stays quiet for an hour, so a broken token does not flood the home.
Transient network errors and rate limits are retried inside the wait window and never wake anyone.

A system sleep usually kills the connection without a close, so a poll that sees the wall clock jump after a wake opens a new connection at once.
On macOS the host's poll time limit keeps running while the system sleeps, so on wake the host stops the poll before it can answer and captures a `timeout` error.
The package marks a stop that lands on a wake and answers the host's silence check with yes for that one capture, so it wakes nobody and the next reconcile starts a new poll.
A timeout while the system was awake is a real fault and still wakes the handler.

## Slack app settings

On the app's page at `https://api.slack.com/apps`:

- **Socket Mode** is on, with an app-level token (`xapp-`) that has the `connections:write` scope.
- **Event Subscriptions** is on, with the bot event `message.channels` (add `message.groups` for private channels).
- **OAuth & Permissions** grants the bot `channels:history` (and `groups:history` for private channels).
- The bot is a member of every watched channel (`/invite @<bot name>`).

The listener uses only the app-level token.
The bot token is needed only by a separate polling backup or by whatever posts replies.

## Store the app-level token

The token never appears in the configuration reference, a command line, an environment variable, logs, or extension state.
The package reads it at every poll from one of three credential backends, selected with `cred=` in the configuration reference.

| `cred` | Default on | Reads |
| --- | --- | --- |
| `keychain` | macOS | macOS keychain item with service `<keychain>` |
| `secret-tool` | Linux and other systems | libsecret item with attribute `service` = `<keychain>` |
| `file` | never | the file named by `credfile=` |

`<keychain>` is the `keychain=` key, default `fm-slack-ask-devops-socket`, and names the item in both the keychain and libsecret.

Run every interactive command below in a real terminal.
A hidden-input prompt run through a wrapper without a terminal, such as an agent's shell escape, reads nothing and stores an empty value.

### macOS keychain

```sh
security add-generic-password -U -a "$USER" -s fm-slack-ask-devops-socket -w
# paste the xapp- token at the prompt
security find-generic-password -s fm-slack-ask-devops-socket -w | wc -c   # must be well above 1
```

### Linux desktop keyring (secret-tool)

`secret-tool` comes with libsecret (package `libsecret-tools` on Debian and Ubuntu, `libsecret` on Fedora and Arch) and works with GNOME Keyring, KeePassXC, and the KWallet Secret Service bridge.

```sh
secret-tool store --label='Slack app token' service fm-slack-ask-devops-socket
# paste the xapp- token at the prompt
secret-tool lookup service fm-slack-ask-devops-socket | wc -c   # must be well above 1
```

The keyring must be unlocked in the user's session.
The extension host passes no D-Bus variables to packages, so when `DBUS_SESSION_BUS_ADDRESS` is absent the package uses the per-user session bus socket at `$XDG_RUNTIME_DIR/bus`, or `/run/user/<uid>/bus` when `XDG_RUNTIME_DIR` is also absent.

### Token file (headless hosts)

On a remote or headless host without a keyring, keep the token in one file that only you can read (in bash):

```sh
mkdir -p "$HOME/.config/firstmate-slack" && chmod 0700 "$HOME/.config/firstmate-slack"
( umask 077 && read -rs -p 'xapp- token: ' t && printf '%s\n' "$t" > "$HOME/.config/firstmate-slack/app-token" ); echo
chmod 0600 "$HOME/.config/firstmate-slack/app-token"
```

The package refuses the file unless it is a regular file, not a symlink, owned by the current user, mode exactly `0600`, and holds only an `xapp-` token.
Keep it outside every Git repository and Firstmate home.

## Channel configuration

The configuration reference passed to `register-extension --config-ref` holds no secrets:

```text
slack-socket:v1;channels=<id>:<mode>[,<id>:<mode>...][;mentions=<user-id>[,...]][;wait=<seconds>][;cred=keychain|secret-tool|file][;keychain=<service>][;credfile=<absolute path>]
```

The literal `default` stands for `slack-socket:v1` with every default below.

| Key | Default | Meaning |
| --- | --- | --- |
| `channels` | `C08D5AM39F0:all` | Watched channel ids and their mode; a missing mode means `all`. |
| `mentions` | none | User ids whose `<@id>` mention makes an `asks` message match. |
| `wait` | `240` | Long-poll window in seconds, 1 to 3500; keep it below the binding's `--timeout-ms` with margin (the default fits the host's default 300-second bound). |
| `cred` | `keychain` on macOS, `secret-tool` elsewhere | Credential backend, see above. |
| `keychain` | `fm-slack-ask-devops-socket` | Keychain or libsecret service name; not allowed with `cred=file`. |
| `credfile` | none | Absolute token file path; required with `cred=file` and allowed only with it. |

The two channel modes are:

- `all` wakes on every new top-level human message.
- `asks` wakes only when the message mentions a `mentions` user id, or reads as a direct ask: `can someone`, `could somebody`, `anyone`, and similar (case-insensitive, whole words).

For example, every message in a help channel plus direct asks in a team channel, on a Linux host with a token file:

```text
slack-socket:v1;channels=C0HELP00001:all,C0TEAM00001:asks;mentions=U0ME0000001;cred=file;credfile=/home/me/.config/firstmate-slack/app-token
```

## Try it once

The `listen` verb runs the same code outside firstmate and prints one JSON document.
It exits 0 on a match, a `no-result`, or, with `--connect-only`, a confirmed connection; 2 when the token or the Slack app needs attention; and 64 on bad arguments.

```sh
node extensions/slack-socket-adapter/package/bin/slack-socket-adapter.mjs listen --connect-only \
  --config-ref 'slack-socket:v1;cred=secret-tool'
```

## Bind, register, and retire

`bind` refuses a package inside a Git project, so copy the package to a persistent directory outside every repository first:

```sh
mkdir -p "$HOME/.local/share/firstmate-packages"
rm -rf "$HOME/.local/share/firstmate-packages/slack-socket-adapter"
cp -R extensions/slack-socket-adapter/package "$HOME/.local/share/firstmate-packages/slack-socket-adapter"
chmod -R go-w "$HOME/.local/share/firstmate-packages/slack-socket-adapter"
```

Then, from the Firstmate root:

```sh
bin/fm-extension.sh bind "$HOME/.local/share/firstmate-packages/slack-socket-adapter" \
  --adapter slack-socket --trust-same-user-code --consent network --consent credential-store
bin/fm-extension.sh verify de.peter-park.devops.slack-socket-adapter
bin/fm-procevent.sh register-extension slack-socket <source-id> --config-ref '<configuration reference>'
bin/fm-procevent.sh reconcile
bin/fm-procevent.sh list   # the source must show live
```

The `credential-store` consent is required: without it the host strips `HOME` and the credential backends cannot find the keychain, the keyring, or a token file under the home directory.
`register-extension` prints an owner token and the exact `retire` command; keep both.
Results arrive through the normal process-event check notification, are classified with `bin/fm-procevent.sh classify <result-file>`, and are acknowledged with `bin/fm-procevent.sh handled <source-id> <sequence>`.

For a remote secondmate on another host, bind with `bin/fm-extension.sh remote-bind <secondmate-id> ...` and register with `bin/fm-on.sh <secondmate-id> fm-procevent.sh register-extension ...`, as [`configuration.md`](configuration.md#trusted-external-process-event-adapters-configextensionsd) describes; store the token on that host, usually with `cred=file`.

To stop the listener, run `bin/fm-procevent.sh retire <source-id> --if-owner <owner-token>`.
To change the package, retire the registration, handle every captured result, retire the binding with `bin/fm-extension.sh retire-binding de.peter-park.devops.slack-socket-adapter --if-binding-digest <digest>`, copy the new package, and bind again; the binding pins the package digest.

## Token rotation

1. In the Slack app settings (Basic Information, App-Level Tokens), generate a new token with `connections:write`.
2. Replace the stored value with the same command you used to store it: `security add-generic-password -U ...`, `secret-tool store ...`, or a new token file.
3. Revoke the old token in the Slack app settings.
4. Tell everyone who uses the same app token.

No rebind or re-registration is needed, because every poll reads the token again.
A poll already running keeps its connection until its window ends, and the next poll uses the new token.
If the old token is revoked first, the running poll reports `unavailable` once; run `bin/fm-procevent.sh reconcile` after storing the new token.

## Tests

`tests/fm-slack-socket-adapter.test.sh` runs the package's `node:test` suites in `extensions/slack-socket-adapter/test/` against a local fake of Slack and fake credential tools, then binds a copy of the package with the real host and verifies its handshake.
The sleep suite freezes the adapter with `SIGSTOP` to stand in for a system sleep.
The suites never reach Slack, a real keychain, or a real keyring.
Three environment variables exist only for those tests, and the host never passes them: `SLACK_SOCKET_ADAPTER_API_BASE` (https, or plain http only to `127.0.0.1` or `localhost`), `SLACK_SOCKET_ADAPTER_SECURITY`, and `SLACK_SOCKET_ADAPTER_SECRET_TOOL`.
