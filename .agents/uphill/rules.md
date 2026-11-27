# Rules

Uphill writes these rules from each metric's `description`. Write code that meets them. `uphill` scores each metric against its target, and `uphill --compare HEAD --compact` lists what a change made worse.

## Footprint

Keep Zig modules focused and modular so daemon and client surfaces stay auditable.

- Keep each Zig source module under 600 production lines by splitting cohesive subsystems into focused modules. At most 600.
- Keep each Zig module concise and avoid duplicating framing, protocol, or syscall logic. At most 24 kB.
- Keep build.zig.zon free of unnecessary external dependencies.

## Style & TigerStyle

Enforce zig fmt and TigerStyle limits on function length, line length, and assertion density.

- Format all Zig source, benchmark, and test files with `zig fmt`.
- Keep every Zig function at or under 70 lines (TigerStyle rule); split state machines and RPC handlers into small helpers. At most 70.
- Keep production Zig lines at or under 120 characters.
- Assert preconditions, postconditions, and ring-buffer/protocol invariants with `std.debug.assert` (target >= 15 per kLOC). At least 15.

## Correctness

Eliminate panic paths, error swallowing, debug prints, and unresolved TODOs from daemon production code.

- Return explicit Zig error unions instead of `@panic`, `unreachable`, or `catch unreachable` in production code.
- Resolve or track TODO/FIXME items instead of leaving them in production Zig modules.
- Use structured logging (`src/log.zig`) instead of `std.debug.print` in production code.
- Handle or log errors explicitly instead of silently swallowing them with `catch {}`.

## Testing

Ensure every core Zig module carries thorough unit tests, fuzz harnesses, and benchmark coverage.

- Keep comprehensive inline unit tests in every src/*.zig module covering boundaries and error paths. At least 20.
- Pair every core src/*.zig module with a fuzz harness under `test/fuzz/`.
- Pair every core src/*.zig module with a benchmark suite in `bench/` and baseline entry in `bench/baseline.json`.

## Documentation

Keep public Zig APIs documented and repository Markdown docs free of broken links.

- Document public Zig functions and constants with `///` doc comments (target >= 90%). At least 90.
- Keep relative links in README.md, CHANGELOG.md, and AGENTS.md valid.
- Maintain README.md, CHANGELOG.md, and AGENTS.md at the repository root.
