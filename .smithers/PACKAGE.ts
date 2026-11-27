import { Smithers as S } from "@smthrs/targets"

const node = S.Host.bin("node")

const factorySources = S.Filegroup({
  srcs: [S.glob("**", { exclude: ["cache/**", "reports/**"] })]
})

const validatorInputs = [
  S.file("//.smithers/scripts/validate-factory.mjs"),
  S.file("//.smithers/FACTORY.ts"),
  S.file("//.smithers/factory.json"),
  S.file("//.smithers/home.json"),
  S.file("//.smithers/merge.json"),
  S.file("//.smithers/trust-policy.json"),
  S.file("//.smithers/coding-project.json"),
  S.glob("//.smithers/flows/**"),
  S.glob("//.smithers/wiki/**"),
  S.glob("//.smithers/views/**"),
  S.glob("//.smithers/playground/**"),
  S.file("//.smithers/scripts/mint-sandbox-auth.mjs"),
  S.file("//.github/workflows/ci.yml"),
  S.file("//bench/baseline.json")
]

// Validates .smithers/factory.json against every discovered flow, dispatcher
// rule, and GitHub push/land policy.
const factoryCheck = S.Shell.Test({
  bin: node,
  args: [".smithers/scripts/validate-factory.mjs", "--factory"],
  data: validatorInputs,
  timeout: "1m"
})

// Validates the personalized multi-audience .smithers/home.json (maintainer,
// contributor, everyone) against the @smthrs/views Home contract and copy rules.
const homeCheck = S.Shell.Test({
  bin: node,
  args: [".smithers/scripts/validate-factory.mjs", "--home"],
  data: validatorInputs,
  timeout: "1m"
})

// Validates trusted vs untrusted execution and shared object store boundaries.
const trustPolicyCheck = S.Shell.Test({
  bin: node,
  args: [".smithers/scripts/validate-factory.mjs", "--trust"],
  data: validatorInputs,
  timeout: "1m"
})

// Validates .smithers/coding-project.json and every source-cited wiki page.
const wikiCheck = S.Shell.Test({
  bin: node,
  args: [".smithers/scripts/validate-factory.mjs", "--wiki"],
  data: [
    ...validatorInputs,
    S.glob("//src/**/*.zig"),
    S.file("//PACKAGE.ts"),
    S.file("//build.zig"),
    S.file("//README.md"),
    S.file("//CHANGELOG.md"),
    S.file("//AGENTS.md"),
    S.file("//CONTRIBUTING.md")
  ],
  timeout: "1m"
})

// Exercises the Lighthouse backpressure view, protocol inspector, and one-time
// sandbox auth bootstrap script.
const viewsCheck = S.Shell.Test({
  bin: node,
  args: [".smithers/scripts/validate-factory.mjs", "--views"],
  data: validatorInputs,
  timeout: "2m"
})

// Prints a fresh one-time-use sandbox auth bundle for local or agent runs.
const sandboxAuth = S.Shell.Run({
  manual: true,
  bin: node,
  args: [".smithers/scripts/mint-sandbox-auth.mjs"],
  data: [S.file("//.smithers/scripts/mint-sandbox-auth.mjs")],
  timeout: "1m"
})

export const Package = S.Package({
  defaultVisibility: "public",
  targets: {
    "factory-sources": factorySources,
    "factory-check": factoryCheck,
    "home-check": homeCheck,
    "trust-policy-check": trustPolicyCheck,
    "wiki-check": wikiCheck,
    "views-check": viewsCheck,
    "sandbox-auth": sandboxAuth
  }
})
