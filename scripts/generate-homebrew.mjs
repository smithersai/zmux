#!/usr/bin/env node
/**
 * Homebrew formula generator for zmux.
 * Parses SHA256SUMS + release version and renders packaging/homebrew/zmux.rb.tmpl.
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

export const DEFAULT_REPO = "smithersai/zmux";
export const DEFAULT_ASSET_PREFIX = "zmux";
export const DEFAULT_TEMPLATE_PATH = path.resolve(
  __dirname,
  "../packaging/homebrew/zmux.rb.tmpl",
);
export const REQUIRED_TARGETS = Object.freeze([
  "macos-arm64",
  "macos-x64",
  "linux-arm64",
  "linux-x64",
]);

const SHA256_RE = /^[0-9a-f]{64}$/i;
const SEMVER_RE = /^v?(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)$/;

/**
 * Validate and normalize a version string into `{ version, tag }`.
 * @param {string} rawVersion
 * @returns {{ version: string, tag: string }}
 */
export function normalizeVersion(rawVersion) {
  if (typeof rawVersion !== "string") {
    throw new Error("version must be a non-empty string");
  }
  const trimmed = rawVersion.trim();
  const match = SEMVER_RE.exec(trimmed);
  if (!match) {
    throw new Error(
      `invalid version "${rawVersion}": expected semver like 0.5.0 or v0.5.0`,
    );
  }
  const version = match[1];
  return { version, tag: `v${version}` };
}

/**
 * Parse a SHA256SUMS file into a Map of archive basename -> lowercase SHA-256 hex digest.
 * @param {string} content
 * @returns {Map<string, string>}
 */
export function parseSha256Sums(content) {
  if (typeof content !== "string") {
    throw new Error("SHA256SUMS content must be a string");
  }
  const entries = new Map();
  const lines = content.split(/\r?\n/);

  for (let i = 0; i < lines.length; i += 1) {
    const rawLine = lines[i].trim();
    if (!rawLine || rawLine.startsWith("#")) {
      continue;
    }

    const match = /^(\S+)\s+(.+)$/.exec(rawLine);
    if (!match) {
      throw new Error(`malformed SHA256SUMS line ${i + 1}: "${rawLine}"`);
    }

    const hash = match[1].toLowerCase();
    if (!SHA256_RE.test(hash)) {
      throw new Error(
        `invalid SHA-256 digest on line ${i + 1}: "${match[1]}"`,
      );
    }

    let fileName = match[2].trim();
    if (fileName.startsWith("*")) {
      fileName = fileName.slice(1);
    }
    const baseName = path.posix.basename(fileName.replace(/\\/g, "/"));
    if (!baseName) {
      throw new Error(`missing filename on SHA256SUMS line ${i + 1}`);
    }

    const existing = entries.get(baseName);
    if (existing !== undefined && existing !== hash) {
      throw new Error(
        `conflicting SHA-256 entries for "${baseName}": ${existing} vs ${hash}`,
      );
    }
    entries.set(baseName, hash);
  }

  return entries;
}

/**
 * Render the Homebrew formula string from parsed checksums and template text.
 * @param {object} options
 * @param {string} options.version
 * @param {Map<string, string>} options.checksums
 * @param {string} [options.repo]
 * @param {string} [options.baseUrl]
 * @param {string} [options.assetPrefix]
 * @param {string} options.template
 * @returns {string}
 */
export function renderFormula({
  version: rawVersion,
  checksums,
  repo = DEFAULT_REPO,
  baseUrl,
  assetPrefix = DEFAULT_ASSET_PREFIX,
  template,
}) {
  if (!(checksums instanceof Map)) {
    throw new Error("checksums must be a Map returned by parseSha256Sums");
  }
  if (typeof template !== "string" || template.length === 0) {
    throw new Error("template must be a non-empty string");
  }

  const { version, tag } = normalizeVersion(rawVersion);
  const resolvedBaseUrl = (
    baseUrl ?? `https://github.com/${repo}/releases/download/${tag}`
  ).replace(/\/+$/, "");

  const missing = [];
  const replacements = new Map([
    ["REPO", repo],
    ["VERSION", version],
    ["TAG", tag],
  ]);

  for (const target of REQUIRED_TARGETS) {
    const assetName = `${assetPrefix}-${target}.tar.gz`;
    const sha = checksums.get(assetName);
    if (!sha) {
      missing.push(assetName);
      continue;
    }
    if (!SHA256_RE.test(sha)) {
      throw new Error(`invalid SHA-256 digest for "${assetName}": "${sha}"`);
    }
    const keySuffix = target.toUpperCase().replace(/-/g, "_");
    replacements.set(`URL_${keySuffix}`, `${resolvedBaseUrl}/${assetName}`);
    replacements.set(`SHA256_${keySuffix}`, sha.toLowerCase());
  }

  if (missing.length > 0) {
    throw new Error(
      `missing required target checksums in SHA256SUMS: ${missing.join(", ")}`,
    );
  }

  let output = template;
  for (const [token, value] of replacements.entries()) {
    output = output.replaceAll(`{{${token}}}`, value);
  }

  const unresolved = output.match(/\{\{[A-Z0-9_]+\}\}/g);
  if (unresolved) {
    throw new Error(
      `unresolved template placeholder(s): ${unresolved.join(", ")}`,
    );
  }

  return output;
}

/**
 * Generate a Homebrew formula from a SHA256SUMS file or text and optionally write it to disk.
 * @param {object} options
 * @param {string} options.version
 * @param {string} [options.checksumsPath]
 * @param {string} [options.checksumsText]
 * @param {string} [options.templatePath]
 * @param {string} [options.outPath]
 * @param {string} [options.repo]
 * @param {string} [options.baseUrl]
 * @param {string} [options.assetPrefix]
 * @returns {string}
 */
export function generateHomebrewFormula({
  version,
  checksumsPath,
  checksumsText,
  templatePath = DEFAULT_TEMPLATE_PATH,
  outPath,
  repo = DEFAULT_REPO,
  baseUrl,
  assetPrefix = DEFAULT_ASSET_PREFIX,
}) {
  const rawSums =
    checksumsText !== undefined
      ? checksumsText
      : fs.readFileSync(checksumsPath, "utf8");
  const template = fs.readFileSync(templatePath, "utf8");
  const checksums = parseSha256Sums(rawSums);
  const formula = renderFormula({
    version,
    checksums,
    repo,
    baseUrl,
    assetPrefix,
    template,
  });

  if (outPath) {
    fs.mkdirSync(path.dirname(path.resolve(outPath)), { recursive: true });
    fs.writeFileSync(outPath, formula, "utf8");
  }

  return formula;
}

function parseCliArgs(argv) {
  const args = {
    version: "",
    checksumsPath: "",
    outPath: "",
    templatePath: DEFAULT_TEMPLATE_PATH,
    repo: DEFAULT_REPO,
    baseUrl: undefined,
    assetPrefix: DEFAULT_ASSET_PREFIX,
    help: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = () => {
      if (i + 1 >= argv.length) {
        throw new Error(`missing value for ${arg}`);
      }
      i += 1;
      return argv[i];
    };

    if (arg === "--version") {
      args.version = next();
    } else if (arg.startsWith("--version=")) {
      args.version = arg.slice("--version=".length);
    } else if (arg === "--checksums") {
      args.checksumsPath = next();
    } else if (arg.startsWith("--checksums=")) {
      args.checksumsPath = arg.slice("--checksums=".length);
    } else if (arg === "--out") {
      args.outPath = next();
    } else if (arg.startsWith("--out=")) {
      args.outPath = arg.slice("--out=".length);
    } else if (arg === "--template") {
      args.templatePath = next();
    } else if (arg.startsWith("--template=")) {
      args.templatePath = arg.slice("--template=".length);
    } else if (arg === "--repo") {
      args.repo = next();
    } else if (arg.startsWith("--repo=")) {
      args.repo = arg.slice("--repo=".length);
    } else if (arg === "--base-url") {
      args.baseUrl = next();
    } else if (arg.startsWith("--base-url=")) {
      args.baseUrl = arg.slice("--base-url=".length);
    } else if (arg === "--asset-prefix") {
      args.assetPrefix = next();
    } else if (arg.startsWith("--asset-prefix=")) {
      args.assetPrefix = arg.slice("--asset-prefix=".length);
    } else if (arg === "-h" || arg === "--help") {
      args.help = true;
    } else {
      throw new Error(`unknown argument: ${arg}`);
    }
  }

  return args;
}

function printUsage() {
  console.log(`Usage: generate-homebrew.mjs --version vX.Y.Z --checksums SHA256SUMS [OPTIONS]

Options:
  --version VER          Release version (e.g. 0.5.0 or v0.5.0)
  --checksums FILE       Path to SHA256SUMS file
  --out FILE             Write generated formula to FILE (default: stdout)
  --template FILE        Template file path (default: packaging/homebrew/zmux.rb.tmpl)
  --repo OWNER/REPO      GitHub repository (default: smithersai/zmux)
  --base-url URL         Override release download base URL
  --asset-prefix PREFIX  Archive filename prefix (default: zmux)
  -h, --help             Show this help message`);
}

function runCli() {
  try {
    const args = parseCliArgs(process.argv.slice(2));
    if (args.help) {
      printUsage();
      return;
    }
    if (!args.version) {
      throw new Error("--version is required");
    }
    if (!args.checksumsPath) {
      throw new Error("--checksums is required");
    }
    const formula = generateHomebrewFormula({
      version: args.version,
      checksumsPath: args.checksumsPath,
      templatePath: args.templatePath,
      outPath: args.outPath || undefined,
      repo: args.repo,
      baseUrl: args.baseUrl,
      assetPrefix: args.assetPrefix,
    });
    if (!args.outPath) {
      process.stdout.write(formula);
    }
  } catch (err) {
    console.error(`generate-homebrew: error: ${err.message}`);
    process.exit(1);
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === __filename) {
  runCli();
}
