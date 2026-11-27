# zmux Engineering Wiki

The zmux engineering wiki is the living architectural map of `smithersai/zmux`.
Every page is cataloged in [`.smithers/coding-project.json`](../coding-project.json),
grounded in exact public source files, and validated in CI by `//.smithers:wiki-check`.

## Pages

1. [Start here](pages/start-here.md): architecture overview, binaries, module map, and entry points.
2. [PTY and process lifecycle](pages/pty-and-process-lifecycle.md): PTY creation, `O_CLOEXEC`, signal escalation, and foreground detection.
3. [JSON-RPC protocol and framing](pages/protocol-and-framing.md): UNIX-socket wire contract, v0.4.0 D1 to D6 decisions, and bounded parsing.
4. [Daemon lifecycle and socket security](pages/daemon-and-security.md): 0700 private directories, same-UID peer credentials, startup locks, and backpressure.
5. [Mux model and scrollback replay](pages/mux-model-and-scrollback.md): sessions, windows, panes, multi-client attach, and ring-buffer replay.
6. [Testing, fuzzing, benchmarks, and Uphill](pages/testing-fuzzing-and-benchmarks.md): incremental Zig targets, fuzz suites, benchmarks, and Lighthouse backpressure.
7. [Smithers Cloud factory, object store, and trust model](pages/factory-and-trust-model.md): personalized UI, Cloud MCP, one-time sandbox auth, and trusted vs untrusted execution.
8. [Mythical history, stacked changesets, and releases](pages/mythical-history.md): TODO to Change to Land to GitHub mirror auto-release and docs publishing.
9. [VT engine, OS reactor, CLI, MCP, and SDK ecosystem](pages/vt-reactor-and-ecosystem.md): pure-Zig VT100/OSC state engine, kqueue/epoll reactor, unified `zmux` CLI + MCP server, OpenRPC 1.3.2, TS/Python SDKs, and `libzmux` C99 ABI.

## Freshness and Security Rules

- Only public repository files belong in `.smithers/coding-project.json`. Never add secrets, `.env`, caches, or private operational notes.
- Every wiki page must cite real owning source files verified by `node .smithers/scripts/validate-factory.mjs --wiki`.
- Every merge landing on `main` refreshes the published wiki, `llms.txt` index, and Lighthouse backpressure report automatically.
