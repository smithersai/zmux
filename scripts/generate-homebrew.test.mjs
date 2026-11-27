import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  DEFAULT_TEMPLATE_PATH,
  REQUIRED_TARGETS,
  generateHomebrewFormula,
  normalizeVersion,
  parseSha256Sums,
  renderFormula,
} from "./generate-homebrew.mjs";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const GENERATOR_CLI = path.resolve(__dirname, "generate-homebrew.mjs");

const SAMPLE_HASHES = {
  "macos-arm64": "a".repeat(64),
  "macos-x64": "b".repeat(64),
  "linux-arm64": "c".repeat(64),
  "linux-x64": "d".repeat(64),
};

function makeSha256Sums(entries = SAMPLE_HASHES, prefix = "zmux") {
  return Object.entries(entries)
    .map(([target, hash]) => `${hash}  ${prefix}-${target}.tar.gz`)
    .join("\n") + "\n";
}

test("normalizeVersion strips optional v prefix and rejects invalid semver", () => {
  assert.deepEqual(normalizeVersion("0.5.0"), { version: "0.5.0", tag: "v0.5.0" });
  assert.deepEqual(normalizeVersion("v0.5.0"), { version: "0.5.0", tag: "v0.5.0" });
  assert.deepEqual(normalizeVersion("v1.2.3-rc.1"), {
    version: "1.2.3-rc.1",
    tag: "v1.2.3-rc.1",
  });
  assert.throws(() => normalizeVersion(""), /invalid version/);
  assert.throws(() => normalizeVersion("latest"), /invalid version/);
});

test("parseSha256Sums handles standard, binary-star, prefixed paths, and comments", () => {
  const text = [
    "# Release checksums",
    "",
    `${SAMPLE_HASHES["macos-arm64"].toUpperCase()}  dist/zmux-macos-arm64.tar.gz`,
    `${SAMPLE_HASHES["macos-x64"]} *./zmux-macos-x64.tar.gz`,
    `${SAMPLE_HASHES["linux-arm64"]}  zmux-linux-arm64.tar.gz`,
    `${SAMPLE_HASHES["linux-x64"]}  zmux-linux-x64.tar.gz`,
  ].join("\n");

  const parsed = parseSha256Sums(text);
  assert.equal(parsed.get("zmux-macos-arm64.tar.gz"), SAMPLE_HASHES["macos-arm64"]);
  assert.equal(parsed.get("zmux-macos-x64.tar.gz"), SAMPLE_HASHES["macos-x64"]);
  assert.equal(parsed.get("zmux-linux-arm64.tar.gz"), SAMPLE_HASHES["linux-arm64"]);
  assert.equal(parsed.get("zmux-linux-x64.tar.gz"), SAMPLE_HASHES["linux-x64"]);

  assert.throws(() => parseSha256Sums("notahash  zmux-macos-arm64.tar.gz\n"), /invalid SHA-256/);
  assert.throws(
    () =>
      parseSha256Sums(
        `${"a".repeat(64)}  zmux-macos-arm64.tar.gz\n${"b".repeat(64)}  zmux-macos-arm64.tar.gz\n`,
      ),
    /conflicting SHA-256/,
  );
});

test("generateHomebrewFormula outputs valid Ruby formula with all 4 targets, URLs, checksums, and test do", () => {
  const formula = generateHomebrewFormula({
    version: "v0.5.0",
    checksumsText: makeSha256Sums(),
  });

  assert.match(formula, /class Zmux < Formula/);
  assert.match(formula, /version "0\.5\.0"/);
  assert.match(formula, /homepage "https:\/\/github\.com\/smithersai\/zmux"/);
  assert.match(formula, /on_macos do/);
  assert.match(formula, /on_linux do/);
  assert.match(formula, /on_arm do/);
  assert.match(formula, /on_intel do/);
  assert.match(formula, /test do[\s\S]*--version[\s\S]*end/);
  assert.doesNotMatch(formula, /\{\{[A-Z0-9_]+\}\}/);

  for (const target of REQUIRED_TARGETS) {
    assert.ok(
      formula.includes(
        `https://github.com/smithersai/zmux/releases/download/v0.5.0/zmux-${target}.tar.gz`,
      ),
      `missing URL for ${target}`,
    );
    assert.ok(
      formula.includes(`sha256 "${SAMPLE_HASHES[target]}"`),
      `missing sha256 for ${target}`,
    );
  }

  // Validate actual Ruby syntax when ruby is installed on the host.
  const rubyCheck = spawnSync("ruby", ["-c", "-"], {
    input: formula,
    encoding: "utf8",
  });
  if (!rubyCheck.error) {
    assert.equal(
      rubyCheck.status,
      0,
      `ruby -c failed: ${rubyCheck.stderr || rubyCheck.stdout}`,
    );
  }
});

test("renderFormula errors loudly when any required target is missing", () => {
  const template = fs.readFileSync(DEFAULT_TEMPLATE_PATH, "utf8");
  for (const omitted of REQUIRED_TARGETS) {
    const partial = { ...SAMPLE_HASHES };
    delete partial[omitted];
    const checksums = parseSha256Sums(makeSha256Sums(partial));
    assert.throws(
      () => renderFormula({ version: "0.5.0", checksums, template }),
      new RegExp(`missing required target checksums.*zmux-${omitted}\\.tar\\.gz`),
    );
  }
});

test("CLI writes generated formula to --out and exits non-zero on missing targets", () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "zmux-hb-test-"));
  try {
    const sumsPath = path.join(tmpDir, "SHA256SUMS");
    const outPath = path.join(tmpDir, "Formula", "zmux.rb");
    fs.writeFileSync(sumsPath, makeSha256Sums(), "utf8");

    execFileSync(
      process.execPath,
      [GENERATOR_CLI, "--version", "v0.5.0", "--checksums", sumsPath, "--out", outPath],
      { encoding: "utf8" },
    );

    const written = fs.readFileSync(outPath, "utf8");
    assert.match(written, /class Zmux < Formula/);
    assert.match(written, /version "0\.5\.0"/);

    // Missing target via CLI fails non-zero
    const badSumsPath = path.join(tmpDir, "BAD_SHA256SUMS");
    fs.writeFileSync(badSumsPath, `${"a".repeat(64)}  zmux-macos-arm64.tar.gz\n`, "utf8");
    const badRun = spawnSync(
      process.execPath,
      [GENERATOR_CLI, "--version", "0.5.0", "--checksums", badSumsPath],
      { encoding: "utf8" },
    );
    assert.notEqual(badRun.status, 0);
    assert.match(badRun.stderr, /missing required target checksums/);
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});
