import { Smithers as S } from "@smthrs/targets"

export const Workspace = S.Workspace("zmux", {
  repository: "git+https://github.com/smithersai/zmux.git",
  cache: S.Cache({
    directory: ".flows",
    hostDirectories: [".zig-cache", "zig-out"]
  }),
  host: S.Host({ bins: ["zig"] }),
  sandboxes: S.Sandboxes({
    default: S.Sandbox.None()
  }),
  discovery: {
    prune: [".zig-cache", "zig-out", ".benchmarks"]
  }
})
