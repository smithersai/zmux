import { Smithers as S } from "@smthrs/targets"

export const Workspace = S.Workspace("smithersai-zmux", {
  repository: "git+https://github.com/smithersai/zmux.git",
  cache: S.Cache({
    directory: ".smithers/cache",
    hostDirectories: [".zig-cache", "zig-out", ".benchmarks", ".uphill", "dist/site"],
    // Shared Smithers Cloud object store (/ac + /cas at https://build.smithers.sh).
    // Untrusted runs (forks, PRs, non-maintainer local runs, agent sandboxes) read
    // through SMITHERS_CACHE_READ_TOKEN only and can never write or poison cache entries.
    // Trusted runs (Smithers Cloud controlled sandboxes and post-merge main) hold
    // SMITHERS_CACHE_WRITE_TOKEN and publish verified action results and artifacts.
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
  host: S.Host({ bins: ["zig", "node", "bun", "python3", "sh"] }),
  sandboxes: S.Sandboxes({
    default: S.Sandbox.None()
  }),
  discovery: {
    prune: [
      ".zig-cache",
      "zig-out",
      ".benchmarks",
      ".flows",
      ".smithers/cache",
      ".smithers/reports",
      ".uphill",
      "dist"
    ]
  }
})
