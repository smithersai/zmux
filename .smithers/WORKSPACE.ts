import { Smithers as S } from "@smthrs/targets"

export const Workspace = S.Workspace("smithersai-zmux", {
  repository: "git+https://github.com/smithersai/zmux.git",
  cache: S.Cache({
    directory: ".smithers/cache",
    hostDirectories: [".zig-cache", "zig-out", ".benchmarks"],
    // Local-first action cache. Syncs through https://build.smithers.sh when
    // SMITHERS_CACHE_READ_TOKEN / SMITHERS_CACHE_WRITE_TOKEN are set locally
    // or in GitHub Actions.
    remote: S.RemoteCache.make({
      endpoint: "https://build.smithers.sh",
      read: S.Secret("SMITHERS_CACHE_READ_TOKEN"),
      write: S.Secret("SMITHERS_CACHE_WRITE_TOKEN")
    })
  }),
  // mise.toml is the Zig 0.17.1 pin authority (CI installs it with
  // jdx/mise-action). Targets resolve zig as a host binary whose bytes key
  // every Zig action, so bumping the pin invalidates exactly those targets.
  toolchains: [S.Mise({ config: S.file("//mise.toml") })],
  host: S.Host({ bins: ["zig"] }),
  sandboxes: S.Sandboxes({
    default: S.Sandbox.None()
  }),
  discovery: {
    prune: [".zig-cache", "zig-out", ".benchmarks", ".flows", ".smithers/cache", ".smithers/reports"]
  }
})
