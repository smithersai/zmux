# Contributing to zmux

`zmux` is developed publicly on Smithers Cloud at [smithers.sh/smithersai/zmux](https://smithers.sh/smithersai/zmux) and mirrored to [github.com/smithersai/zmux](https://github.com/smithersai/zmux). Contributions from humans and agents are warmly welcomed.

## Quick setup

Install Zig 0.17.1 via `mise` and run the same incremental target graph used in CI:

```sh
mise install
smthrs ci '//...'
smthrs run //:bench
uphill --compact
```

Use Jujutsu (`jj`) for all version-control operations (`jj status`, `jj diff`, `jj describe`, `jj bookmark`).

## Connect your agent over Smithers Cloud MCP

All agents working on `zmux` should interact through the authenticated Cloud MCP server so issues, TODOs, pull requests, artifacts, and stacked changesets stay synchronized across Smithers Cloud and GitHub:

```sh
claude mcp add zmux --transport http https://smithers.sh/smithersai/zmux/mcp
codex mcp add zmux --url https://smithers.sh/smithersai/zmux/mcp
agy mcp add zmux --transport http https://smithers.sh/smithersai/zmux/mcp
```

To print a one-time-use attenuated authentication bundle (or shell bootstrap) for an isolated agent sandbox, and verify live Cloud MCP and shared object store connectivity:

```sh
node .smithers/scripts/mint-sandbox-auth.mjs
eval "$(node .smithers/scripts/mint-sandbox-auth.mjs --shell)"
node .smithers/scripts/mint-sandbox-auth.mjs --doctor
```

## Trusted vs untrusted execution

We encourage non-maintainers and contributor agents to run `smthrs ci '//...'`, fuzzing, benchmarks, and `uphill --compact` freely:

- **Untrusted runs** hydrate from the shared `https://build.smithers.sh` object store **read-only**. They give you instant feedback, are explicitly labeled `trust: "untrusted"`, and can never write cache entries or skip merge gates.
- **Trusted runs** execute only inside Smithers-controlled sandboxes or directly under maintainer approval (`roninjin10`). Only trusted runs publish to the shared object store, clear merge gates, and trigger GitHub mirror releases and docs publishing.

## Backpressure and quality bar

Every change is scored by our Lighthouse-style Uphill backpressure audit (`.agents/uphill/rules.md`):

- Format every Zig file with `zig fmt`.
- Keep functions concise (target <= 70 lines) and production lines <= 120 characters.
- Return explicit typed Zig errors instead of `@panic`, `unreachable`, `std.debug.print`, or silent `catch {}`.
- Pair behavior changes with focused unit tests (zero leaks under `std.testing.allocator`), integration tests in `test/integration/session_daemon.zig`, or fuzz seeds in `test/fuzz/`.
- Document `pub fn` and `pub const` declarations with `///` doc comments.
- Run `smthrs ci '//...'` and `uphill --compare HEAD --compact` before opening a change.

## How a change lands

1. Reproduce defects on a real PTY and UNIX socket before writing a fix.
2. Open one focused change or stacked changeset linked to its issue or TODO via Smithers Cloud MCP.
3. Let automated review (`checks/review`) and untrusted checks verify correctness, benchmarks, and Lighthouse scores.
4. A maintainer reviews, approves, and runs trusted gates to land your change onto `main` with your full contributor credit preserved.
5. Landing on Smithers Cloud mirrors to GitHub `main`, automatically publishing updated docs, `llms.txt`, wiki, Lighthouse audit report, and release binaries when the version bumps.
