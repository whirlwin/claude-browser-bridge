# Architecture

```
Claude Code ──stdio (MCP)──▶ cbb mcp ──Unix socket (NDJSON)──▶ cbb host ◀──native messaging──▶ extension
```

Chrome spawns the native host when the extension calls `chrome.runtime.connectNative`,
so Claude Code can never be the host itself, nor wake the extension. A small MCP
server, spawned by Claude Code, reaches the host through a Unix socket instead.

## Processes

| Process     | Started by  | stdin/stdout                        | Role                                  |
|-------------|-------------|-------------------------------------|---------------------------------------|
| extension   | Chrome      | n/a                                 | Executes commands with `chrome.*` APIs |
| `cbb host`  | Chrome      | native messaging framing            | Relays between extension and socket    |
| `cbb mcp`   | Claude Code | MCP over stdio                      | Exposes tools, forwards to socket      |

Both `cbb` modes use stdout as a protocol channel. Logging goes to stderr only;
a stray `console.log` corrupts the framing.

## Socket

- Path: `~/Library/Application Support/claude-browser-bridge/bridge.sock`
  (override with `CBB_SOCKET` for tests).
- Directory mode `0700`, socket mode `0600`. The trust boundary is the OS user:
  any process running as you can connect.
- The newest host wins: on startup the host unlinks any existing socket and binds.
  On exit (Chrome closed the port, stdin EOF) it unlinks the socket only if it
  still owns it (inode check). "Newest wins" only applies to new connections:
  an MCP client already connected to an older host (say, another Chrome
  profile) keeps talking to it until that connection drops.
- No socket, or connection refused, means "browser not connected".
- Multiple MCP clients may connect at once. The host rewrites request ids to
  `<clientNumber>:<id>` before forwarding and restores them on the way back.

## Messages

All three hops carry the same JSON shapes. Socket framing is newline-delimited
JSON. Native messaging framing is a 4-byte little-endian length prefix followed
by UTF-8 JSON.

Request (MCP → host → extension):

```json
{ "id": "42", "method": "tabs.list", "params": {} }
```

Response (extension → host → MCP), exactly one per request:

```json
{ "id": "42", "result": { } }
{ "id": "42", "error": { "code": "not_found", "message": "No tab with id 7" } }
```

Event (extension → host, no id), sent once on connect:

```json
{ "event": "hello", "version": "0.1.0", "userAgent": "..." }
```

The host answers a request with error code `not_connected` if the extension port
is gone, and `too_large` if the encoded message exceeds 1 MiB (Chrome's limit for
host → extension messages). Extension → host messages may be up to 64 MiB, so
screenshots are fine.

Error codes: `not_connected`, `too_large`, `bad_request`, `not_found`,
`unavailable` (API missing or disabled, message explains how to enable it),
`disabled` (kill switch on), `internal`, and `timeout`. `timeout` is produced
on the MCP side when the host never answered (30 s by default, 120 s for
`page_eval` with `awaitPromise`); it never travels over the socket.

## Methods

`tabId` is optional everywhere it appears; it defaults to the active tab of the
last focused window.

| Method              | Params                                              | Result                                   | Implementation                                  |
|---------------------|-----------------------------------------------------|------------------------------------------|-------------------------------------------------|
| `tabs.list`         | `{}`                                                | `{ tabs: [{id, windowId, url, title, active, groupId}] }` | `chrome.tabs.query`                 |
| `tabs.open`         | `{ url, active? }`                                  | `{ tab }`                                | `chrome.tabs.create`                            |
| `tabs.close`        | `{ tabIds: number[] }`                              | `{}`                                     | `chrome.tabs.remove`                            |
| `tabs.navigate`     | `{ tabId?, url }`                                   | `{ tab }`                                | `chrome.tabs.update`                            |
| `tabs.focus`        | `{ tabId }`                                         | `{}`                                     | `tabs.update` + `windows.update`                |
| `tabs.group`        | `{ tabIds, title?, color? }`                        | `{ groupId }`                            | `chrome.tabs.group` + `tabGroups.update`        |
| `page.eval`         | `{ tabId?, expression, awaitPromise? }`             | `{ value }` or error with exception text | CDP `Runtime.evaluate`, `returnByValue: true`   |
| `page.cdp`          | `{ tabId?, method, params? }`                       | `{ result }`                             | `chrome.debugger.sendCommand`                   |
| `page.css`          | `{ tabId?, css, remove? }`                          | `{}`                                     | `chrome.scripting.insertCSS` / `removeCSS`      |
| `page.screenshot`   | `{ tabId?, format? ("png"\|"jpeg") }`               | `{ data (base64), mimeType }`            | CDP `Page.captureScreenshot`                    |
| `page.text`         | `{ tabId? }`                                        | `{ url, title, text }`                   | CDP `Runtime.evaluate` of `document.body.innerText` |
| `mods.list`         | `{}`                                                | `{ mods: [...] }`                        | `chrome.userScripts.getScripts`                 |
| `mods.register`     | `{ id, matches, js, runAt?, world? }`               | `{}`                                     | `chrome.userScripts.register` (update if exists) |
| `mods.unregister`   | `{ ids }`                                           | `{}`                                     | `chrome.userScripts.unregister`                 |
| `net.rules.list`    | `{}`                                                | `{ rules }`                              | `declarativeNetRequest.getDynamicRules`         |
| `net.rules.add`     | `{ rules }` (DNR rule objects)                      | `{}`                                     | `updateDynamicRules({ addRules })`               |
| `net.rules.remove`  | `{ ids }`                                           | `{}`                                     | `updateDynamicRules({ removeRuleIds })`          |
| `chrome.call`       | `{ path: "cookies.getAll", args: [] }`              | `{ result }`                             | Resolves `chrome.<path>` and awaits it          |

`page.*` methods that use CDP attach `chrome.debugger` (protocol `1.3`) to the tab
on first use and stay attached; Chrome shows its "is debugging this browser" bar
while attached, which doubles as a visible indicator. The kill switch detaches
everything.

`mods.*` need the per-extension "Allow User Scripts" toggle (extension Details
page). Without it `chrome.userScripts` is undefined and the extension returns
`unavailable` with instructions.

## MCP tools

One tool per method, named with underscores (`tabs_list`, `page_eval`,
`net_rules_add`, `chrome_call`, ...). `page_screenshot` returns an MCP image
content block; everything else returns JSON text.

`bridge_status` (method `bridge.status`) is answered by the host itself:
`{ connected: true, hello }`. The host only runs while Chrome holds its port, so
when no host is listening (no socket, or connection refused) the MCP server
returns a normal, non-error result `{ "connected": false, "message": "..." }`,
so Claude can tell "not connected" apart from a failure.

## Kill switch

The popup toggles `enabled` in `chrome.storage.local`. When disabled the
extension detaches all debugger sessions, disconnects the native port, does not
reconnect, and the badge shows `OFF`. While connected the badge shows `ON`, and
`...` while it waits to reconnect.

The popup and the service worker never message each other directly; they
communicate through `chrome.storage`. The popup writes `enabled` to
`storage.local`; the worker publishes its connection status and a log of recent
commands to `storage.session`, which the popup reads and watches.

Reconnects back off with a `setTimeout`, backed by a `chrome.alarms` alarm
(hence the `alarms` permission) because an idle MV3 worker can be suspended and
lose its timers.
