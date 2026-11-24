import { Smithers as S } from "@smthrs/targets"

// Factory projections for smithers.sh/smithersai/zmux. Zig build, test, fuzz,
// and benchmark targets live in the root //:PACKAGE.ts.
const factorySources = S.Filegroup({
  srcs: [S.glob("**", { exclude: ["cache/**", "reports/**"] })]
})

export const Package = S.Package({
  defaultVisibility: "public",
  targets: {
    "factory-sources": factorySources,
    "factory-write": S.FactoryProjection({ mode: "write" }),
    "factory-check": S.FactoryProjection({ mode: "check" })
  }
})
