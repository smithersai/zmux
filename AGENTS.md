# AGENTS.md: zmux Agent & Factory Guide

Follow the [Uphill rules](.agents/uphill/rules.md), which `uphill rules --write` rewrites from each metric's description: @/Users/williamcory/zmux/.agents/uphill/rules.md

## Public Smithers Cloud Factory

`zmux` is built publicly on Smithers Cloud ([smithers.sh/smithersai/zmux](https://smithers.sh/smithersai/zmux)) and mirrors landed changes to GitHub ([smithersai/zmux](https://github.com/smithersai/zmux)).

- **Authenticated Cloud MCP:** Connect to `https://smithers.sh/smithersai/zmux/mcp` (OAuth 2.1 + PKCE S256). Use Smithers MCP tools (`repo_*`, `docs_*`, `flows_*`, `issues_*`, `issue_create`, `issue_comment`, `pulls_*`, `todo_list`, `todo_draft`, `work_link_post`) to create and track artifacts, TODOs, issues, PRs, and stacked changesets.
- **One-time-use sandbox auth:** Print an attenuated single-use sandbox bootstrap bundle with `node .smithers/scripts/mint-sandbox-auth.mjs` (never print `SMITHERS_CACHE_WRITE_TOKEN`, personal cookies, or GitHub PATs).
- **Shared object store:** All `smthrs` targets share `https://build.smithers.sh` (`/ac` + `/cas`). Untrusted and agent runs read the cache read-only (`SMITHERS_CACHE_READ_TOKEN`), emit `trust: "untrusted"` receipts, and never write cache or bypass merge gates.
- **Version control:** Use Jujutsu (`jj --no-pager`) for every VCS operation. Never invoke the raw `git` CLI directly.
- **Engineering wiki:** Read [`.smithers/wiki/README.md`](.smithers/wiki/README.md) and keep `.smithers/coding-project.json` citations accurate whenever subsystem behavior changes.

## Local verification loop

1. Fast check: `zig fmt --check src test bench build.zig build.zig.zon` and affected per-module `smthrs test //:test<Module>`
2. Factory & contract check: `smthrs test '//.smithers/...'`
3. Lighthouse backpressure audit: `uphill --compare HEAD --compact`
4. Full verification: `smthrs ci '//...'` and `smthrs run //:bench`

## Hard invariants

- Never weaken tests, drop requirements, or silently alter the v0.4.0 D1-D6 JSON-RPC wire contract.
- Keep public user-facing copy in `.smithers/home.json`, docs, and wiki free of semicolons and em dashes.
- Person-only actions (`pull/merge`, `issue/triage`, `todo/commit`, `secrets/write`) remain strictly human-only.
