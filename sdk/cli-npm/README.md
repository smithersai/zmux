# @smithers/zmux-cli

Thin zero-dependency npm and bunx CLI launcher for [zmux](https://github.com/smithersai/zmux).

## Usage

Run directly via `bunx` or `npx`:

```sh
bunx @smithers/zmux-cli --version
npx @smithers/zmux-cli ls
```

Or install globally:

```sh
npm install -g @smithers/zmux-cli
zmux --version
```

## How binary resolution works

On each invocation, the launcher resolves the native `zmux` binary in this order:

1. Explicit `ZMUX_BIN` environment variable if set
2. An existing native `zmux` executable on `PATH` (skipping this launcher wrapper to avoid recursion)
3. The cached binary under `~/.cache/zmux/bin/<version>/zmux` (or `$ZMUX_CACHE_DIR/bin/<version>/zmux`)
4. First-run download from GitHub Releases for your host target (`linux-x64`, `linux-arm64`, `macos-arm64`, or `macos-x64`), verified against `SHA256SUMS` before extraction and atomic installation into the cache directory

Any sibling `zmuxd` and `zmux-connect` binaries inside the verified tarball are installed alongside `zmux` so daemon auto-spawning works immediately.

## Environment variables

- `ZMUX_BIN`: Override the path to the native `zmux` binary
- `ZMUX_CACHE_DIR`: Override the cache root directory (defaults to `~/.cache/zmux`)
- `ZMUX_VERSION`: Override the release version to download
- `ZMUX_RELEASE_BASE_URL`: Override the release download base URL (useful for mirrors or offline setups)

## Running tests

```sh
node --test sdk/cli-npm/test/launcher.test.mjs
```
