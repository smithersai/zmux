import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  ensureBinary,
  findOnPath,
  getCacheDir,
  resolveTarget,
  runCli,
  sha256File,
  spawnBinary,
} from "../lib/launcher.mjs";

function makeExecutableScript(filePath, body) {
  fs.writeFileSync(filePath, `#!/bin/sh\n${body}\n`, "utf8");
  fs.chmodSync(filePath, 0o755);
}

async function withStaticServer(rootDir, fn) {
  const requests = [];
  const server = http.createServer((req, res) => {
    const reqPath = (req.url || "/").split("?")[0];
    requests.push(reqPath);
    const fullPath = path.join(rootDir, path.posix.basename(reqPath));
    if (!fs.existsSync(fullPath) || !fs.statSync(fullPath).isFile()) {
      res.writeHead(404);
      res.end("not found");
      return;
    }
    res.writeHead(200);
    fs.createReadStream(fullPath).pipe(res);
  });

  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  const baseUrl = `http://127.0.0.1:${address.port}`;
  try {
    return await fn({ baseUrl, requests });
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

test("resolveTarget maps all 4 host targets and rejects unsupported ones", () => {
  assert.equal(resolveTarget("linux", "x64"), "linux-x64");
  assert.equal(resolveTarget("linux", "arm64"), "linux-arm64");
  assert.equal(resolveTarget("darwin", "arm64"), "macos-arm64");
  assert.equal(resolveTarget("darwin", "x64"), "macos-x64");

  assert.throws(() => resolveTarget("win32", "x64"), /unsupported zmux platform/);
  assert.throws(() => resolveTarget("linux", "ia32"), /unsupported zmux platform/);
});

test("getCacheDir uses ~/.cache/zmux/bin/<version> and respects ZMUX_CACHE_DIR", () => {
  assert.equal(
    getCacheDir("v0.5.0", { homeDir: "/home/alice", env: {} }),
    path.join("/home/alice", ".cache", "zmux", "bin", "0.5.0"),
  );
  assert.equal(
    getCacheDir("0.5.0", {
      homeDir: "/home/alice",
      env: { ZMUX_CACHE_DIR: "/var/cache/custom-zmux" },
    }),
    path.join("/var/cache/custom-zmux", "bin", "0.5.0"),
  );
});

test("findOnPath locates native zmux and skips self wrapper symlinks", () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "zmux-cli-path-"));
  try {
    const dirA = path.join(tmpDir, "a");
    const dirB = path.join(tmpDir, "b");
    fs.mkdirSync(dirA);
    fs.mkdirSync(dirB);

    const selfTarget = path.join(tmpDir, "self-zmux.mjs");
    makeExecutableScript(selfTarget, "echo self");
    const selfLink = path.join(dirA, "zmux");
    fs.symlinkSync(selfTarget, selfLink);

    const realBin = path.join(dirB, "zmux");
    makeExecutableScript(realBin, "echo native");

    const found = findOnPath("zmux", {
      env: { PATH: `${dirA}${path.delimiter}${dirB}` },
      selfRealPaths: [selfTarget],
    });
    assert.equal(found, realBin);

    const onlySelf = findOnPath("zmux", {
      env: { PATH: dirA },
      selfRealPaths: [selfTarget],
    });
    assert.equal(onlySelf, null);
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("ensureBinary downloads, SHA-256 verifies, caches siblings, and reuses cache on second run", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "zmux-cli-dl-test-"));
  try {
    const hostTarget = resolveTarget();
    const stageDir = path.join(tmpDir, "stage");
    const releaseDir = path.join(tmpDir, "release");
    const cacheRoot = path.join(tmpDir, "cache");
    fs.mkdirSync(stageDir);
    fs.mkdirSync(releaseDir);

    makeExecutableScript(path.join(stageDir, "zmux"), 'echo "zmux 0.5.0 ($*)"');
    makeExecutableScript(path.join(stageDir, "zmuxd"), 'echo "zmuxd 0.5.0"');
    makeExecutableScript(
      path.join(stageDir, "zmux-connect"),
      'echo "zmux-connect 0.5.0"',
    );

    const archiveName = `zmux-${hostTarget}.tar.gz`;
    const archivePath = path.join(releaseDir, archiveName);
    execFileSync(
      "tar",
      ["-czf", archivePath, "-C", stageDir, "zmux", "zmuxd", "zmux-connect"],
      { stdio: "pipe" },
    );
    const digest = sha256File(archivePath);
    fs.writeFileSync(
      path.join(releaseDir, "SHA256SUMS"),
      `${digest}  ${archiveName}\n`,
      "utf8",
    );

    await withStaticServer(releaseDir, async ({ baseUrl, requests }) => {
      const first = await ensureBinary({
        version: "0.5.0",
        baseUrl,
        env: { ZMUX_CACHE_DIR: cacheRoot },
        skipPathLookup: true,
      });
      assert.equal(first.source, "download");
      assert.equal(first.target, hostTarget);
      assert.ok(fs.existsSync(first.binaryPath));
      assert.ok(fs.existsSync(path.join(first.cacheDir, "zmuxd")));
      assert.ok(fs.existsSync(path.join(first.cacheDir, "zmux-connect")));
      assert.deepEqual(requests, ["/SHA256SUMS", `/${archiveName}`]);

      // Execute the downloaded binary via runCli and confirm args/exit code.
      const out = execFileSync(first.binaryPath, ["--version"], {
        encoding: "utf8",
      }).trim();
      assert.equal(out, "zmux 0.5.0 (--version)");

      // Second call hits cache with zero network requests.
      const beforeCount = requests.length;
      const second = await ensureBinary({
        version: "0.5.0",
        baseUrl,
        env: { ZMUX_CACHE_DIR: cacheRoot },
        skipPathLookup: true,
      });
      assert.equal(second.source, "cache");
      assert.equal(second.binaryPath, first.binaryPath);
      assert.equal(requests.length, beforeCount);
    });
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("ensureBinary fails loudly on corrupted SHA-256 and leaves cache clean", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "zmux-cli-bad-hash-"));
  try {
    const hostTarget = resolveTarget();
    const stageDir = path.join(tmpDir, "stage");
    const releaseDir = path.join(tmpDir, "release");
    const cacheDir = path.join(tmpDir, "cache-bin");
    fs.mkdirSync(stageDir);
    fs.mkdirSync(releaseDir);

    makeExecutableScript(path.join(stageDir, "zmux"), "echo tampered");
    const archiveName = `zmux-${hostTarget}.tar.gz`;
    execFileSync(
      "tar",
      ["-czf", path.join(releaseDir, archiveName), "-C", stageDir, "zmux"],
      { stdio: "pipe" },
    );
    fs.writeFileSync(
      path.join(releaseDir, "SHA256SUMS"),
      `${"0".repeat(64)}  ${archiveName}\n`,
      "utf8",
    );

    await withStaticServer(releaseDir, async ({ baseUrl }) => {
      await assert.rejects(
        () =>
          ensureBinary({
            version: "0.5.0",
            baseUrl,
            cacheDir,
            env: {},
            skipPathLookup: true,
          }),
        /SHA-256 checksum mismatch/,
      );
      assert.equal(fs.existsSync(cacheDir), false);
    });
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("runCli and spawnBinary propagate exit codes and forward signals cleanly", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "zmux-cli-spawn-"));
  try {
    const okBin = path.join(tmpDir, "ok-zmux");
    makeExecutableScript(okBin, "exit 0");
    assert.equal(
      await runCli([], { env: { ZMUX_BIN: okBin }, stdio: "ignore" }),
      0,
    );

    const exit42Bin = path.join(tmpDir, "exit42-zmux");
    makeExecutableScript(exit42Bin, "exit 42");
    assert.equal(
      await runCli(["--bad"], { env: { ZMUX_BIN: exit42Bin }, stdio: "ignore" }),
      42,
    );

    // Verify signal forwarding via a child Node process invoking bin/zmux.mjs.
    const markerFile = path.join(tmpDir, "sigterm-received");
    const sigBin = path.join(tmpDir, "sig-zmux");
    makeExecutableScript(
      sigBin,
      `trap 'echo got-term > "${markerFile}"; exit 0' TERM\necho READY\nwhile true; do sleep 0.05; done`,
    );

    const binEntry = path.resolve(
      path.dirname(new URL(import.meta.url).pathname),
      "../bin/zmux.mjs",
    );
    const launcherProc = spawn(process.execPath, [binEntry], {
      env: { ...process.env, ZMUX_BIN: sigBin },
      stdio: ["ignore", "pipe", "pipe"],
    });

    await new Promise((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error("timed out waiting for child READY")),
        5000,
      );
      let buf = "";
      launcherProc.stdout.on("data", (chunk) => {
        buf += chunk.toString("utf8");
        if (buf.includes("READY")) {
          clearTimeout(timer);
          resolve();
        }
      });
      launcherProc.on("error", (err) => {
        clearTimeout(timer);
        reject(err);
      });
    });

    launcherProc.kill("SIGTERM");
    const closeCode = await new Promise((resolve) =>
      launcherProc.on("close", (code) => resolve(code)),
    );
    assert.equal(closeCode, 0);
    assert.equal(fs.readFileSync(markerFile, "utf8").trim(), "got-term");

    // Direct spawnBinary smoke check
    const res = await spawnBinary(okBin, [], { stdio: "ignore" });
    assert.equal(res.exitCode, 0);
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});
