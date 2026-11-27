# Testing, fuzzing, benchmarks, and Uphill

Every quality gate in `zmux` is declared as a cacheable target in `PACKAGE.ts` or `.smithers/PACKAGE.ts` and verified continuously by Uphill (`uphill`).

## Incremental per-module Zig closures

`PACKAGE.ts` defines exact per-module Zig dependency closures (`bufferSrcs`, `protocolSrcs`, `sysSrcs`, `ptySrcs`, `nativeSrcs`, `muxSrcs`, `connectSrcs`, `serverSrcs`, `daemonSrcs`, `mainSrcs`):

- Editing `src/buffer.zig` invalidates only targets whose closure includes `buffer.zig`.
- Unchanged unit tests, cross-compiles, coverage fuzzers, and benchmarks replay instantaneously from `.smithers/cache` or the shared `https://build.smithers.sh` object store.
- Running `smthrs ci '//...'` locally runs the exact same target graph as GitHub Actions.

## Unit, integration, and foreign-UID suites

- Every `src/*.zig` module carries inline `test "..."` blocks verified under `std.testing.allocator` for zero memory leaks.
- `test/integration/session_daemon.zig` exercises real daemon spawns, UNIX-socket JSON-RPC attach/detach, scrollback replay, and foreign-UID rejection (run with elevated privileges on Linux CI to prove cross-UID refusal).
- Alpine Linux (`musl`) CI compiles and runs the full test suite against `x86_64-linux-musl`.

## Coverage-guided and live PTY fuzzing

- `//:testFuzz` replays deterministic corpus seeds under `test/fuzz/`.
- `//:fuzzCoverage` runs bounded coverage-guided fuzzing (`--fuzz=10K`) keyed on its input closure.
- `//:fuzzLive` (exclusive tier) runs stateful model-checking fuzzers against real PTYs and UNIX sockets.
- Weekly `fuzz-soak` runs extended 1M-iteration campaigns and minimizes any crash into a corpus seed.

## Incremental benchmarks and Lighthouse backpressure

- Every core module has a benchmark target (`//:benchBuffer` through `//:benchServer`) that writes `.benchmarks/<module>.json` as a cacheable output. `smthrs run //:bench` aggregates all cached and fresh results against `bench/baseline.json`.
- Uphill (`.agents/uphill/uphill.yaml`) scores five categories from 0 to 100 in a Lighthouse-style audit report:
  1. **Footprint** (module line count, module byte size, zero external dependencies)
  2. **Style and TigerStyle** (`zig fmt`, max function length <= 70 lines, line length <= 120, `std.debug.assert` density >= 15 per kLOC)
  3. **Correctness** (zero production `@panic`/`unreachable`, zero TODOs, zero `std.debug.print`, zero silent `catch {}`)
  4. **Testing** (unit test density >= 20 per module, fuzz harness parity, benchmark suite parity)
  5. **Documentation** (`pub` `///` doc coverage >= 90%, valid Markdown links, core root docs)
