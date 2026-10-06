# claude-browser-bridge

A browser extension that lets a locally running [Claude Code](https://claude.com/claude-code)
authenticate to your local browser and reshape how it behaves.

## Goal

Give a local Claude Code session as much control over the browser as the
extension platform allows: reading and editing pages, injecting scripts and
styles, managing tabs and windows, intercepting and rewriting requests, and
persisting those changes as reusable behaviours.

## Security model (to be designed)

An extension with this much reach is effectively a remote control for
everything you are logged in to, so the bridge must be locked down from day one:

- Listen only on the loopback interface (or use native messaging), never on the network.
- Pair explicitly: the extension and Claude Code exchange a secret once, and every
  request is authenticated with it.
- Keep a visible indicator in the browser whenever a session is connected, with a
  one-click kill switch.
- Treat page content as untrusted input to the agent; it can contain prompt injection.

## Status

Early days: nothing to install yet.
