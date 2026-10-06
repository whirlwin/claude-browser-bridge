# claude-browser-bridge

Lets a locally running [Claude Code](https://claude.com/claude-code) drive the
Chrome you are already logged in to: list and open tabs, read and screenshot
pages, evaluate JavaScript, inject CSS, install persistent user scripts
("mods"), rewrite network requests and call most `chrome.*` APIs.

## How it works

```
Claude Code -stdio (MCP)-> cbb mcp -Unix socket-> cbb host <-native messaging-> extension
```

Chrome starts `cbb host` when the extension connects to it through native
messaging. Claude Code starts `cbb mcp`, which exposes the MCP tools and reaches
the host through a Unix socket owned by your user. Nothing listens on a TCP
port. See [docs/architecture.md](docs/architecture.md) for the protocol,
methods and error codes.

## Install

Requires macOS (the installer has Linux paths too, but they are untested),
Node 24 or newer and a
Chromium browser (Chrome 135+, Brave, Edge, Vivaldi, Arc, Chromium).

```sh
git clone https://github.com/whirlwin/claude-browser-bridge.git
cd claude-browser-bridge
scripts/install.sh
```

The installer is safe to re-run. It:

- runs `npm ci` (first time) and `npm run build`;
- writes a wrapper at `~/Library/Application Support/claude-browser-bridge/cbb-host`
  that runs the host with an absolute Node path (Chrome does not use your shell
  `PATH`, so mise shims are resolved to the real binary);
- registers the native messaging host `io.whirlwin.claude_browser_bridge` with
  every installed Chromium browser, allowed for this extension's ID only;
- registers the `claude-browser-bridge` MCP server with Claude Code at user
  scope, if `claude` is on your `PATH`.

Then:

1. Open `chrome://extensions`, turn on **Developer mode**, click **Load
   unpacked** and pick `extension/dist`. The ID must match
   `extension/extension-id.txt`.
2. For mods, open the extension's Details page
   (`chrome://extensions/?id=cbapdndkoijjfggigdfalnjgjopdebid`) and turn on
   **Allow User Scripts**. The toggle only appears there, and only because the
   extension requests the `userScripts` permission. Without it the `mods_*`
   tools return `unavailable`.
3. Restart Claude Code and ask it to run `bridge_status`.

## Tools

| Tool | What it does |
|------|--------------|
| `bridge_status` | Whether the extension is connected, plus its version and user agent |
| `tabs_list` | List open tabs |
| `tabs_open` | Open a URL in a new tab |
| `tabs_close` | Close tabs |
| `tabs_navigate` | Load a URL in an existing tab |
| `tabs_focus` | Activate a tab and raise its window |
| `tabs_group` | Put tabs into a titled, coloured group |
| `page_eval` | Evaluate a JavaScript expression in a tab |
| `page_cdp` | Send a raw Chrome DevTools Protocol command to a tab |
| `page_css` | Insert or remove CSS in a tab |
| `page_screenshot` | Screenshot a tab's viewport |
| `page_text` | Get a tab's URL, title and visible text |
| `mods_list` | List registered mods (persistent user scripts) |
| `mods_register` | Register or update a mod for matching URLs |
| `mods_unregister` | Remove mods |
| `net_rules_list` | List `declarativeNetRequest` dynamic rules |
| `net_rules_add` | Add rules that block, redirect or rewrite requests |
| `net_rules_remove` | Remove rules |
| `chrome_call` | Call any `chrome.*` function by path, e.g. `bookmarks.getTree` |

## Kill switch and badge

The toolbar badge shows `ON` while the bridge is connected, `...` while it is
reconnecting and `OFF` when disabled. The popup has an on/off button and a log
of recent commands. Switching it off detaches every debugger session, closes
the native port and stops reconnecting until you switch it back on.

`page_eval`, `page_cdp`, `page_screenshot` and `page_text` attach
`chrome.debugger` to the tab and stay attached; while they are, Chrome shows its
"started debugging this browser" bar. The other tools leave no mark beyond the
badge and the popup log.

## Keyboard shortcuts

| Shortcut (macOS / other) | Action |
|--------------------------|--------|
| `⌘J` / `Alt+J` | Next tab, one down (wraps around) |
| `⌘K` / `Alt+K` | Previous tab, one up (wraps around) |

They work everywhere, including the new tab page, and keep working while the
kill switch is off. `⌘J` replaces Chrome's Downloads shortcut. Rebind or clear
them at `chrome://extensions/shortcuts`. Chrome applies these defaults only on
first install; after an update that changes them, set them there by hand.

## Security

Be clear about what this is: a remote control for every site you are logged in
to.

- **The trust boundary is your macOS user.** The socket is mode `0600` in a
  `0700` directory, so other users cannot reach it, but any process running as
  you can connect and drive your browser with your sessions. There is no extra
  secret on top of that.
- **Native messaging is restricted to this extension.** The host manifest only
  allows `chrome-extension://<id>/` from `extension/extension-id.txt`.
- **Activity is only partly visible.** The badge shows that the bridge is
  connected, not what it is doing. The debugger bar appears only for the CDP
  tools (`page_eval`, `page_cdp`, `page_screenshot`, `page_text`). Tab, CSS,
  mod, network rule and `chrome_call` operations (for example reading cookies
  or history) show nothing beyond the `ON` badge and the popup's command log.
  The kill switch cuts everything.
- **Page content is untrusted input.** Text, screenshots and eval results flow
  back to Claude and can carry prompt injection. Be deliberate about which
  pages you let Claude read, especially in a session where it also has other
  tools (shell, email, file access) it could be talked into using.

## Uninstall

```sh
scripts/uninstall.sh
```

This removes the host manifests, the wrapper and the MCP registration. Remove
the extension itself from `chrome://extensions`.

## Development

```sh
npm test            # unit tests for host and extension
npm run build       # builds extension/dist and host/dist/cbb.js
```

- `extension/scripts/keygen.sh` creates `extension/key.pem` (gitignored),
  prints the manifest `key` and writes `extension/extension-id.txt`. The
  extension ID is derived from the public key committed in
  `extension/static/manifest.json`, so every checkout gets the same ID; the
  private `key.pem` is only needed to pack a `.crx`.
- `node extension/scripts/icons.mjs` regenerates the toolbar icons.
- After changing the host, re-run `npm run build` (or `scripts/install.sh`).
  After changing the extension, rebuild and click reload on
  `chrome://extensions`.
