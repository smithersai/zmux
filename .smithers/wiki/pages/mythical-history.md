# Mythical history, stacked changesets, and releases

`zmux` develops itself publicly through Smithers Cloud's **mythical history** and stacked changeset pipeline, then mirrors landed work to GitHub where releases and documentation publish automatically.

## Five Eras of zmux

```text
  Jun 2026                 Jul 2026                  Nov 22, 2026              Nov 23-24, 2026            Nov 26, 2026
  ========                 ========                  ============              ===============            ============
  [v0.1.0]                 [Audit A-G]               [v0.2.0 -> v0.3.0]        [v0.4.0 Hardening]         [Cloud Factory]
  Genesis & PR #1          7 Security &              Zig 0.17.1 std.Io         Decisions D1-D6            Uphill Lighthouse
  350 ms -> 1.6 ms         Concurrency Batches       Linux /proc & O_PATH      32+ Fuzzers & 85+ Bench    Wiki, MCP & Trust
```

### Era I: Genesis & The 218x Latency Drop (`v0.1.0`, June 2026)

`zmux` started with a direct architectural goal: keep `tmux(1)`'s long-lived server-owns-the-PTY model (`server.c`, `client.c`, `proc.c`, `spawn.c`) while replacing opaque format strings and CLI screen-scraping with a structured JSON-RPC 2.0 protocol over a UNIX domain socket. Community PR #1 by `@patcito` replaced coarse polling in `zmux-connect` and fixed the open-or-create attach path, dropping interactive keystroke latency from **~350 ms down to ~1.6 ms**.

### Era II: The Seven Audit Batches (`v0.2.0` & `v0.2.1`, July to Nov 2026)

Seven systematic audit sweeps (`90e0b5d0` through `4e7071e6`) plus November hardening (`9e435dcb`, `d088ddb0`, `8fc26861`, `6f48be5a`, `97cce865`) locked down OS-level safety:
- Advisory `flock(2)` startup locking so concurrent daemons never unlink a live socket.
- Race-free `0600` socket binding inside pinned `0700` private directories without mutating global `umask(2)`.
- Same-UID peer credential verification via `SO_PEERCRED` (Linux) and `getpeereid(3)` (macOS).
- Linux `/proc` foreground inspection, `POLL.HUP` EOF line draining, and replacing `O_PATH` with `O_RDONLY | O_DIRECTORY | O_NOFOLLOW` so `fchmod(2)` succeeds reliably under `umask 0022`.

### Era III: The Zig 0.17 `std.Io` Crossing (`v0.3.0`, Nov 22, 2026)

In commit `335234ec`, `zmux` migrated to **Zig 0.17.1** and explicit `std.Io` injection across `Server.init`, `NativeSession.create`, and `SessionManager.init`. All raw POSIX syscalls moved into `src/sys.zig`, heap allocations between `fork(2)` and `exec` were eliminated, `MSG_NOSIGNAL` / `SO_NOSIGPIPE` removed `SIGPIPE` crash hazards for embedders, and idle timeouts moved to the monotonic clock.

### Era IV: Wire Contract D1-D6, Coverage-Guided Fuzzing & Incremental Benchmarks (`v0.4.0`, Nov 22-24, 2026)

Three multi-track review rounds (`bb5bc114` through `693d92a0`) formalized the `v0.4.0` wire contract (Decisions D1 through D6), added a 32-target LLVM SanitizerCoverage fuzz suite (`test/fuzz/`) plus live-PTY chaos fuzzers, built 85+ ReleaseFast benchmarks (`bench/baseline.json`, with 64-byte ring-buffer appends at ~5.9 ns median and 58 GB/s throughput), added privileged Ubuntu foreign-UID CI tests, and wired the first incremental `PACKAGE.ts` build graph to `https://build.smithers.sh`.

### Era V: Public Smithers Cloud Coding Factory (Nov 26, 2026)

Starting with Uphill continuous metrics (`9d241246`), `zmux` completed its permanent switchover to `https://smithers.sh/smithersai/zmux` with a 6-gauge Lighthouse Backpressure Audit UI, personalized Maintainer / Contributor / Viewer home pages, authenticated BYOA Cloud MCP with one-time sandbox auth, split cache trust boundaries, and automatic GitHub release and docs publishing.

## Lifecycle of a change

```text
  GitHub / Smithers Issue ──▶ Maintainer labels `todo` ──▶ Stacked Change on Mythical History
                                                                     │
                                            ┌────────────────────────┴────────────────────────┐
                                            ▼                                                 ▼
                                 Automated Review (`checks/review`)             Untrusted CI + Uphill Audit
                                 (PTY, protocol, daemon, memory)                (read-only cache feedback)
                                            └────────────────────────┬────────────────────────┘
                                                                     ▼
                                                  Maintainer Approval + Trusted Gate
                                                  (Smithers sandbox / maintainer run)
                                                                     │
                                                                     ▼
                                                  Land on Smithers Cloud (`main`)
                                                                     │
                                                                     ▼
                                                  Mirror Push to GitHub (`main`)
                                                      ├── Auto Release (if version bumped: 4 targets + checksums + tag)
                                                      ├── Auto Docs, Wiki, History & llms.txt Deploy (GitHub Pages)
                                                      └── Auto Lighthouse Backpressure Audit Refresh
```

## Mythical history and stacked changesets

- Every piece of work begins as an issue or TODO tracked through the Smithers Cloud MCP server (`issues_list`, `issue_create`, `todo_list`, `todo_draft`, `work_link_post`).
- Maintainer-approved TODOs enter the mythical history stack (`.smithers/merge.json`, `.smithers/FACTORY.ts`), allowing dependent changesets to stack, rebase, and review cleanly using Jujutsu (`jj`).
- Agents file issues, draft TODOs, open changesets, attach audit artifacts, and request review, while a human maintainer always owns final triage, approval, and landing.
- Every contributor PR merges with full contributor attribution preserved.

## Automated releases and docs publishing on merge to GitHub

`.github/workflows/release.yml` watches pushes to `main` (including every mirror push from Smithers Cloud):

1. **Release detection:** Compares `build.zig.zon` and `src/protocol.zig` versions against the latest GitHub Release tag. When a bump lands on `main`, CI automatically runs full qualification (`ci.yml`), compiles `ReleaseSafe` tarballs + `.sha256` sidecars + `SHA256SUMS` for `linux-x64`, `linux-arm64`, `macos-arm64`, and `macos-x64`, smoke-tests each binary, tags `vX.Y.Z`, extracts `CHANGELOG.md` notes, and publishes the GitHub Release.
2. **Docs, Wiki, Mythical History, and Lighthouse Audit publishing:** Every push to `main` rebuilds `dist/site/` (documentation home, `llms.txt`, `llms-full.txt`, rendered Engineering Wiki, interactive Mythical History timeline, interactive Protocol Inspector, and live Lighthouse Backpressure Audit Report) and publishes it to `https://smithersai.github.io/zmux/`.
3. **Smithers Cloud Docs tab sync:** Because `.smithers/home.json` declares `"docs": "https://smithersai.github.io/zmux/llms.txt"`, `smithers.sh/smithersai/zmux` and the `docs_list` / `docs_read` MCP tools automatically serve the freshly published pages.
