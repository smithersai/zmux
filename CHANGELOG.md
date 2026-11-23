# Changelog

## [0.2.1] - 2026-11-22

### Fixed

- Fixed Linux `createPrivateSocketParent` for Zig 0.15.2 consumers. Opening the
  directory without `O_PATH` lets `fchmod` enforce mode `0700` under `umask 0022`.

## [0.2.0] - 2026-11-22

### Added

- Added `--detach-key` and the `ls`, `kill`, `rename`, and `shutdown` management
  commands to `zmux-connect`.
- Exported the `zmux.connect` module for embedders.
- Added Linux foreground process inspection through `/proc/<pid>/comm` and
  `/proc/<pid>/cmdline`.
- Added structured daemon diagnostics on stderr, configurable with
  `--log-level` or `ZMUX_LOG_LEVEL`. The default level is `warn`.
- Added explicit Unix socket path length validation for macOS and Linux.

### Changed

- **Breaking release asset change.** Releases now ship `.tar.gz` archives
  with `.sha256` checksums for Linux x86_64 and arm64 and macOS x86_64 and
  arm64. v0.1.0 shipped raw binaries for Linux x86_64 and macOS arm64.
- Updated CI and release workflows to use Node 24 actions.

### Fixed

- Completed audit batches A–G, fixing daemon and session lifecycle issues,
  concurrency bugs, and mux correctness issues, improving PTY robustness,
  and hardening daemon security. The audit also delivered the CLI and module
  export changes listed above.
- Made Unix socket binding race-free and eliminated global `umask` mutation
  during socket creation.

## [0.1.0] - 2026-06-18

### Added

- Initial release.

### Fixed

- PR #1 reduced keystroke latency from approximately 350 ms to 1.6 ms and
  fixed open-or-create behavior in `zmux-connect`.
