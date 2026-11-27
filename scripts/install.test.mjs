import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { dirname, join } from "node:path"
import test from "node:test"
import { fileURLToPath } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))
const script = join(here, "install.sh")

test("install.sh passes POSIX sh syntax check", () => {
  execFileSync("sh", ["-n", script], { stdio: "pipe" })
})

for (const [osName, archName, expectedTarget] of [
  ["Linux", "x86_64", "linux-x64"],
  ["Linux", "aarch64", "linux-arm64"],
  ["Darwin", "arm64", "macos-arm64"],
  ["Darwin", "x86_64", "macos-x64"]
]) {
  test(`install.sh --dry-run resolves ${osName}/${archName} to ${expectedTarget}`, () => {
    const out = execFileSync("sh", [script, "--dry-run", "--version=v0.4.0", "--dir=/tmp/zmux-bin"], {
      encoding: "utf8",
      env: { ...process.env, ZMUX_TEST_OS: osName, ZMUX_TEST_ARCH: archName }
    })
    assert.ok(out.includes(`target=${expectedTarget}\n`))
    assert.ok(out.includes(`archive=zmux-v0.4.0-${expectedTarget}.tar.gz\n`))
    assert.ok(out.includes(`sha256_url=https://github.com/smithersai/zmux/releases/download/v0.4.0/zmux-v0.4.0-${expectedTarget}.tar.gz.sha256\n`))
    assert.ok(out.includes("install_dir=/tmp/zmux-bin\n"))
  })
}

test("install.sh rejects unsupported operating systems cleanly", () => {
  assert.throws(
    () =>
      execFileSync("sh", [script, "--dry-run"], {
        stdio: "pipe",
        env: { ...process.env, ZMUX_TEST_OS: "FreeBSD", ZMUX_TEST_ARCH: "x86_64" }
      }),
    /Unsupported OS/
  )
})
