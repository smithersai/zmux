/**
 * Thin zero-dependency launcher for native zmux binaries.
 * Resolves host target, checks PATH or ~/.cache/zmux/bin/<version>/,
 * downloads and SHA-256 verifies release tarballs on first run, and
 * spawns zmux forwarding stdio, exit codes, and POSIX signals.
 */

import { execFileSync, spawn } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

export const DEFAULT_REPO = "smithersai/zmux";
export const PACKAGE_JSON_PATH = path.resolve(__dirname, "../package.json");
export const PACKAGE_VERSION = JSON.parse(
  fs.readFileSync(PACKAGE_JSON_PATH, "utf8"),
).version;

const SHA256_RE = /^[0-9a-f]{64}$/i;
const FORWARDED_SIGNALS = ["SIGINT", "SIGTERM", "SIGHUP", "SIGQUIT"];

/**
 * Resolve Node `process.platform` + `process.arch` to a zmux release target.
 * @param {string} [platform]
 * @param {string} [arch]
 * @returns {"linux-x64" | "linux-arm64" | "macos-arm64" | "macos-x64"}
 */
export function resolveTarget(
  platform = process.platform,
  arch = process.arch,
) {
  if (platform === "linux" && arch === "x64") return "linux-x64";
  if (platform === "linux" && arch === "arm64") return "linux-arm64";
  if (platform === "darwin" && arch === "arm64") return "macos-arm64";
  if (platform === "darwin" && arch === "x64") return "macos-x64";
  throw new Error(
    `unsupported zmux platform/arch: ${platform}/${arch} (supported: linux-x64, linux-arm64, macos-arm64, macos-x64)`,
  );
}

/**
 * Strip an optional leading `v` from a version string.
 * @param {string} rawVersion
 * @returns {string}
 */
export function normalizeVersion(rawVersion) {
  const cleaned = String(rawVersion ?? "").trim().replace(/^v/, "");
  if (!cleaned) {
    throw new Error("zmux version must not be empty");
  }
  return cleaned;
}

/**
 * Resolve the per-version binary cache directory (`~/.cache/zmux/bin/<version>`).
 * @param {string} version
 * @param {{ homeDir?: string, env?: NodeJS.ProcessEnv }} [options]
 * @returns {string}
 */
export function getCacheDir(version, { homeDir, env = process.env } = {}) {
  const cleanVersion = normalizeVersion(version);
  if (env?.ZMUX_CACHE_DIR && env.ZMUX_CACHE_DIR.trim() !== "") {
    return path.join(env.ZMUX_CACHE_DIR.trim(), "bin", cleanVersion);
  }
  const home = homeDir ?? env?.HOME ?? os.homedir();
  return path.join(home, ".cache", "zmux", "bin", cleanVersion);
}

/**
 * Parse a SHA256SUMS file into a Map of archive basename -> lowercase SHA-256 hex digest.
 * @param {string} text
 * @returns {Map<string, string>}
 */
export function parseSha256Sums(text) {
  const entries = new Map();
  for (const rawLine of String(text).split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const match = /^(\S+)\s+(.+)$/.exec(line);
    if (!match) {
      throw new Error(`malformed SHA256SUMS line: "${line}"`);
    }
    const digest = match[1].toLowerCase();
    if (!SHA256_RE.test(digest)) {
      throw new Error(`invalid SHA-256 digest in SHA256SUMS: "${match[1]}"`);
    }
    let fileName = match[2].trim();
    if (fileName.startsWith("*")) fileName = fileName.slice(1);
    const baseName = path.posix.basename(fileName.replace(/\\/g, "/"));
    entries.set(baseName, digest);
  }
  return entries;
}

/**
 * Compute the lowercase hex SHA-256 digest of a file on disk.
 * @param {string} filePath
 * @returns {string}
 */
export function sha256File(filePath) {
  const hash = crypto.createHash("sha256");
  hash.update(fs.readFileSync(filePath));
  return hash.digest("hex");
}

/**
 * Return true if `filePath` is an existing regular executable file.
 * @param {string} filePath
 * @returns {boolean}
 */
export function isExecutableFile(filePath) {
  try {
    const st = fs.statSync(filePath);
    if (!st.isFile()) return false;
    fs.accessSync(filePath, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function safeRealpath(filePath) {
  try {
    return fs.realpathSync(filePath);
  } catch {
    return path.resolve(filePath);
  }
}

/**
 * Search PATH for an executable binary while skipping any paths in `selfRealPaths`.
 * @param {string} [binaryName]
 * @param {{ env?: NodeJS.ProcessEnv, selfRealPaths?: string[] }} [options]
 * @returns {string | null}
 */
export function findOnPath(
  binaryName = "zmux",
  { env = process.env, selfRealPaths = [] } = {},
) {
  const rawPath = env?.PATH ?? "";
  if (!rawPath) return null;

  const excluded = new Set(selfRealPaths.map((p) => safeRealpath(p)));
  for (const dir of rawPath.split(path.delimiter)) {
    if (!dir) continue;
    const candidate = path.join(dir, binaryName);
    if (!isExecutableFile(candidate)) continue;
    const real = safeRealpath(candidate);
    if (excluded.has(real)) continue;
    return candidate;
  }
  return null;
}

function installFileAtomic(srcPath, destDir, fileName) {
  fs.mkdirSync(destDir, { recursive: true });
  const tempPath = path.join(
    destDir,
    `.${fileName}.tmp.${process.pid}.${crypto.randomBytes(6).toString("hex")}`,
  );
  try {
    fs.copyFileSync(srcPath, tempPath);
    fs.chmodSync(tempPath, 0o755);
    fs.renameSync(tempPath, path.join(destDir, fileName));
  } catch (err) {
    try {
      fs.rmSync(tempPath, { force: true });
    } catch {
      // ignore cleanup errors
    }
    throw err;
  }
}

async function fetchBuffer(url, fetchImpl) {
  const res = await fetchImpl(url, { redirect: "follow" });
  if (!res.ok) {
    throw new Error(`HTTP ${res.status} downloading ${url}`);
  }
  const arrayBuf = await res.arrayBuffer();
  return Buffer.from(arrayBuf);
}

/**
 * Ensure the requested zmux binary is available locally, downloading and
 * SHA-256 verifying from releases on first run if needed.
 *
 * @param {object} [options]
 * @param {string} [options.version]
 * @param {string} [options.binaryName]
 * @param {string} [options.repo]
 * @param {string} [options.baseUrl]
 * @param {string} [options.cacheDir]
 * @param {NodeJS.ProcessEnv} [options.env]
 * @param {string} [options.homeDir]
 * @param {string} [options.platform]
 * @param {string} [options.arch]
 * @param {typeof fetch} [options.fetchImpl]
 * @param {boolean} [options.skipPathLookup]
 * @param {string[]} [options.selfRealPaths]
 * @returns {Promise<{ binaryPath: string, source: "env" | "path" | "cache" | "download", target?: string, cacheDir?: string }>}
 */
export async function ensureBinary({
  version = process.env.ZMUX_VERSION || PACKAGE_VERSION,
  binaryName = "zmux",
  repo = DEFAULT_REPO,
  baseUrl,
  cacheDir,
  env = process.env,
  homeDir,
  platform = process.platform,
  arch = process.arch,
  fetchImpl = globalThis.fetch,
  skipPathLookup = false,
  selfRealPaths = [],
} = {}) {
  if (env?.ZMUX_BIN && env.ZMUX_BIN.trim() !== "") {
    const override = env.ZMUX_BIN.trim();
    if (!isExecutableFile(override)) {
      throw new Error(`ZMUX_BIN is not an executable file: ${override}`);
    }
    return { binaryPath: override, source: "env" };
  }

  if (!skipPathLookup) {
    const onPath = findOnPath(binaryName, { env, selfRealPaths });
    if (onPath) {
      return { binaryPath: onPath, source: "path" };
    }
  }

  const cleanVersion = normalizeVersion(version);
  const target = resolveTarget(platform, arch);
  const resolvedCacheDir = cacheDir ?? getCacheDir(cleanVersion, { homeDir, env });
  const cachedBinary = path.join(resolvedCacheDir, binaryName);
  if (isExecutableFile(cachedBinary)) {
    return {
      binaryPath: cachedBinary,
      source: "cache",
      target,
      cacheDir: resolvedCacheDir,
    };
  }

  if (typeof fetchImpl !== "function") {
    throw new Error("global fetch API is required to download zmux binaries");
  }

  const resolvedBaseUrl = (
    baseUrl ??
    env?.ZMUX_RELEASE_BASE_URL ??
    `https://github.com/${repo}/releases/download/v${cleanVersion}`
  ).replace(/\/+$/, "");

  const sumsBuf = await fetchBuffer(`${resolvedBaseUrl}/SHA256SUMS`, fetchImpl);
  const sums = parseSha256Sums(sumsBuf.toString("utf8"));

  const candidateArchives = [];
  const unifiedAsset = `zmux-${target}.tar.gz`;
  if (sums.has(unifiedAsset)) {
    candidateArchives.push(unifiedAsset);
  }
  for (const splitAsset of [
    `zmuxd-${target}.tar.gz`,
    `zmux-connect-${target}.tar.gz`,
  ]) {
    if (sums.has(splitAsset)) {
      candidateArchives.push(splitAsset);
    }
  }

  if (candidateArchives.length === 0) {
    throw new Error(
      `no release tarball for target "${target}" listed in ${resolvedBaseUrl}/SHA256SUMS`,
    );
  }

  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "zmux-cli-dl-"));
  const extractDir = path.join(tempDir, "extract");
  fs.mkdirSync(extractDir, { recursive: true });

  try {
    for (const asset of candidateArchives) {
      const expected = sums.get(asset);
      const tarballBuf = await fetchBuffer(`${resolvedBaseUrl}/${asset}`, fetchImpl);
      const archivePath = path.join(tempDir, asset);
      fs.writeFileSync(archivePath, tarballBuf);

      const actual = sha256File(archivePath);
      if (actual !== expected) {
        throw new Error(
          `SHA-256 checksum mismatch for ${asset} (expected ${expected}, got ${actual})`,
        );
      }

      execFileSync("tar", ["-xzf", archivePath, "-C", extractDir], {
        stdio: "pipe",
      });
    }

    const extractedBins = ["zmux", "zmuxd", "zmux-connect"].filter((name) =>
      fs.existsSync(path.join(extractDir, name)),
    );

    if (!extractedBins.includes(binaryName)) {
      throw new Error(
        `verified release archive(s) did not contain expected binary "${binaryName}" (found: ${extractedBins.join(", ") || "none"})`,
      );
    }

    for (const name of extractedBins) {
      installFileAtomic(path.join(extractDir, name), resolvedCacheDir, name);
    }

    return {
      binaryPath: cachedBinary,
      source: "download",
      target,
      cacheDir: resolvedCacheDir,
    };
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
}

/**
 * Spawn a native binary, forwarding stdio, signals, and exit status cleanly.
 * @param {string} binaryPath
 * @param {string[]} argv
 * @param {{ env?: NodeJS.ProcessEnv, stdio?: any }} [options]
 * @returns {Promise<{ code: number | null, signal: NodeJS.Signals | null, exitCode: number }>}
 */
export function spawnBinary(
  binaryPath,
  argv = [],
  { env = process.env, stdio = "inherit" } = {},
) {
  return new Promise((resolve, reject) => {
    const child = spawn(binaryPath, argv, {
      stdio,
      env,
    });

    const signalHandlers = new Map();
    for (const sig of FORWARDED_SIGNALS) {
      const handler = () => {
        if (!child.killed) {
          try {
            child.kill(sig);
          } catch {
            // child may have already exited
          }
        }
      };
      signalHandlers.set(sig, handler);
      process.on(sig, handler);
    }

    const cleanupListeners = () => {
      for (const [sig, handler] of signalHandlers.entries()) {
        process.off(sig, handler);
      }
      signalHandlers.clear();
    };

    child.on("error", (err) => {
      cleanupListeners();
      reject(err);
    });

    child.on("close", (code, signal) => {
      cleanupListeners();
      let exitCode = 1;
      if (typeof code === "number") {
        exitCode = code;
      } else if (signal) {
        const sigNum = os.constants.signals[signal] ?? 1;
        exitCode = 128 + sigNum;
      }
      resolve({ code, signal, exitCode });
    });
  });
}

/**
 * Resolve/download `zmux` and execute it with `argv`.
 * @param {string[]} [argv]
 * @param {object} [options]
 * @returns {Promise<number>}
 */
export async function runCli(argv = process.argv.slice(2), options = {}) {
  const { stdio = "inherit", ...ensureOpts } = options;
  const resolved = await ensureBinary(ensureOpts);
  const result = await spawnBinary(resolved.binaryPath, argv, {
    env: ensureOpts.env ?? process.env,
    stdio,
  });
  return result.exitCode;
}
