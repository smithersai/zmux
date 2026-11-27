#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const VALID_SCHEMA_TYPES = new Set([
  "string",
  "number",
  "integer",
  "boolean",
  "object",
  "array",
  "null",
]);

const REQUIRED_ERROR_CODES = [-32700, -32600, -32601, -32602, -32603, -32000];
const REQUIRED_ERROR_KINDS = [
  "parse",
  "invalid_request",
  "method_not_found",
  "invalid_params",
  "not_found",
  "terminated",
  "conflict",
  "limit",
  "spawn_failed",
  "io",
  "internal",
];

const EXPECTED_V040_METHODS = [
  "daemon.ping",
  "daemon.shutdown",
  "mux.snapshot",
  "session.create",
  "session.terminate",
  "session.list",
  "session.info",
  "session.resize",
  "session.capture",
  "session.send",
  "session.sendKey",
  "session.rename",
  "window.new",
  "window.select",
  "window.rename",
  "pane.split",
  "pane.select",
  "pane.rename",
  "pane.respawn",
  "client.attach",
  "client.detach",
  "client.switch",
  "client.list",
  "events.subscribe",
  "key.bind",
  "key.dispatch",
  "key.list",
  "command.exec",
];

const EXPECTED_V040_NOTIFICATIONS = [
  "pane_output",
  "pane_output_dropped",
  "pane_activity",
  "pane_bell",
  "session_exited",
  "foreground_changed",
  "pane_respawned",
  "client_detached",
  "client_switched",
];

const EXPECTED_EXTENSION_METHODS = [
  "session.screen",
  "pane.wait",
  "pane.exec",
  "pane.signal",
  "pane.close",
  "window.close",
  "pane.resizeSplit",
  "pane.zoom",
  "pane.metadata",
  "pane.record",
  "client.setMode",
];

const EXPECTED_EXTENSION_NOTIFICATIONS = [
  "pane_title_changed",
  "pane_cwd_changed",
  "pane_prompt_changed",
  "pane_status_changed",
];

/**
 * Strip line comments and top-level `test "..." { ... }` blocks from Zig source
 * so static extraction only inspects production code.
 */
export function stripZigTestsAndComments(source) {
  const lines = source.split(/\r?\n/);
  const out = [];
  let inTest = false;
  let braceDepth = 0;

  for (const rawLine of lines) {
    const line = rawLine.replace(/\/\/.*$/, "");
    if (!inTest && /^\s*test(?:\s+"[^"]*")?\s*\{/.test(line)) {
      inTest = true;
      braceDepth = 0;
    }
    if (inTest) {
      for (const ch of line) {
        if (ch === "{") braceDepth += 1;
        else if (ch === "}") braceDepth -= 1;
      }
      if (braceDepth <= 0) {
        inTest = false;
      }
      continue;
    }
    out.push(line);
  }
  return out.join("\n");
}

function collectZigFiles(repoRoot, baseFile, baseDir) {
  const files = [];
  const mainFile = path.join(repoRoot, baseFile);
  if (fs.existsSync(mainFile)) files.push(mainFile);

  const dirPath = path.join(repoRoot, baseDir);
  if (fs.existsSync(dirPath) && fs.statSync(dirPath).isDirectory()) {
    const walk = (dir) => {
      for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) walk(full);
        else if (entry.isFile() && entry.name.endsWith(".zig")) files.push(full);
      }
    };
    walk(dirPath);
  }
  return files.sort();
}

/**
 * Extract every dispatched JSON-RPC method string from `src/server.zig` and `src/server/*.zig`.
 */
export function extractServerMethods(repoRoot) {
  const files = collectZigFiles(repoRoot, "src/server.zig", "src/server");
  const methods = new Set();
  const patterns = [
    /std\.mem\.eql\s*\(\s*u8\s*,\s*(?:req\.method|method)\s*,\s*"([^"]+)"\s*\)/g,
    /\.method\s*=\s*"([a-z]+\.[A-Za-z]+)"/g,
  ];

  for (const file of files) {
    const source = stripZigTestsAndComments(fs.readFileSync(file, "utf8"));
    for (const re of patterns) {
      let match;
      while ((match = re.exec(source)) !== null) {
        methods.add(match[1]);
      }
    }
  }
  return [...methods].sort();
}

/**
 * Extract notification method names declared in `src/protocol.zig`, `src/server.zig`, and `src/server/*.zig`.
 */
export function extractProtocolNotifications(repoRoot) {
  const files = [
    ...collectZigFiles(repoRoot, "src/protocol.zig", "src/protocol"),
    ...collectZigFiles(repoRoot, "src/server.zig", "src/server"),
  ];
  const notifications = new Set();
  const re = /\bconst\s+[a-z0-9_]+_method\s*(?::[^=]+)?=\s*"([^"]+)"/g;

  for (const file of files) {
    const source = stripZigTestsAndComments(fs.readFileSync(file, "utf8"));
    let match;
    while ((match = re.exec(source)) !== null) {
      notifications.add(match[1]);
    }
  }
  return [...notifications].sort();
}

/**
 * Extract `ErrorKind` enum variants from `src/protocol.zig` (or `src/protocol/*.zig`).
 */
export function extractErrorKinds(repoRoot) {
  const files = collectZigFiles(repoRoot, "src/protocol.zig", "src/protocol");
  const kinds = new Set();

  for (const file of files) {
    const source = stripZigTestsAndComments(fs.readFileSync(file, "utf8"));
    const match = /pub\s+const\s+ErrorKind\s*=\s*enum\s*\{([\s\S]*?)\};/.exec(source);
    if (!match) continue;
    for (const token of match[1].split(",")) {
      const cleaned = token.trim();
      if (/^[a-z][a-z0-9_]*$/.test(cleaned)) {
        kinds.add(cleaned);
      }
    }
  }
  return [...kinds].sort();
}

/**
 * Resolve a local JSON Pointer (`#/a/b/c`) inside `root`.
 */
export function resolveJsonPointer(root, ref) {
  if (typeof ref !== "string" || !ref.startsWith("#/")) {
    return { ok: false, reason: `invalid $ref format: ${String(ref)}` };
  }
  const parts = ref
    .slice(2)
    .split("/")
    .map((p) => p.replace(/~1/g, "/").replace(/~0/g, "~"));
  let current = root;
  for (const part of parts) {
    if (current === null || typeof current !== "object" || !(part in current)) {
      return { ok: false, reason: `unresolved $ref: ${ref}` };
    }
    current = current[part];
  }
  return { ok: true, value: current };
}

function validateNode(root, node, location, errors) {
  if (node === null || typeof node !== "object") return;
  if (Array.isArray(node)) {
    for (let i = 0; i < node.length; i += 1) {
      validateNode(root, node[i], `${location}[${i}]`, errors);
    }
    return;
  }

  if ("$ref" in node) {
    const resolved = resolveJsonPointer(root, node.$ref);
    if (!resolved.ok) {
      errors.push(`${location}: ${resolved.reason}`);
    }
    return;
  }

  if ("type" in node && location.includes("schema")) {
    const t = node.type;
    if (typeof t === "string") {
      if (!VALID_SCHEMA_TYPES.has(t)) {
        errors.push(`${location}: unknown JSON Schema type "${t}"`);
      }
    } else if (Array.isArray(t)) {
      if (t.length === 0) {
        errors.push(`${location}: empty type union`);
      }
      for (const item of t) {
        if (!VALID_SCHEMA_TYPES.has(item)) {
          errors.push(`${location}: unknown JSON Schema type "${item}"`);
        }
      }
    } else {
      errors.push(`${location}: invalid type field`);
    }
  }

  if (Array.isArray(node.required) && node.properties && typeof node.properties === "object") {
    for (const reqProp of node.required) {
      if (!(reqProp in node.properties)) {
        errors.push(`${location}: required property "${reqProp}" missing from properties`);
      }
    }
  }

  for (const [key, value] of Object.entries(node)) {
    validateNode(root, value, `${location}.${key}`, errors);
  }
}

export function validateSpec(options = {}) {
  const scriptDir = path.dirname(fileURLToPath(import.meta.url));
  const repoRoot = options.repoRoot ?? path.resolve(scriptDir, "..");
  const specPath = options.specPath ?? path.join(repoRoot, "protocol", "openrpc.json");
  const checkSources = options.checkSources ?? true;

  const errors = [];
  let spec;
  try {
    spec = JSON.parse(fs.readFileSync(specPath, "utf8"));
  } catch (err) {
    return {
      ok: false,
      errors: [`failed to read or parse ${specPath}: ${err.message}`],
      stats: null,
    };
  }

  if (spec.openrpc !== "1.3.2") {
    errors.push(`expected openrpc version "1.3.2", got ${JSON.stringify(spec.openrpc)}`);
  }
  if (!spec.info || typeof spec.info.title !== "string" || typeof spec.info.version !== "string") {
    errors.push("spec.info must include string title and version");
  }

  // Validate all $ref pointers and JSON Schema basics across the whole spec.
  validateNode(spec, spec, "$", errors);

  // Validate methods.
  const methodNames = new Map();
  if (!Array.isArray(spec.methods) || spec.methods.length === 0) {
    errors.push("spec.methods must be a non-empty array");
  } else {
    for (let i = 0; i < spec.methods.length; i += 1) {
      const m = spec.methods[i];
      const loc = `methods[${i}]`;
      if (!m || typeof m.name !== "string" || m.name.length === 0) {
        errors.push(`${loc}: missing string name`);
        continue;
      }
      if (methodNames.has(m.name)) {
        errors.push(`${loc}: duplicate method name "${m.name}"`);
      }
      methodNames.set(m.name, m);

      if (typeof m.summary !== "string" || m.summary.length === 0) {
        errors.push(`${loc} (${m.name}): missing summary`);
      }
      if (m.paramStructure !== "by-name") {
        errors.push(`${loc} (${m.name}): paramStructure must be "by-name"`);
      }
      if (!Array.isArray(m.params)) {
        errors.push(`${loc} (${m.name}): params must be an array`);
      } else {
        const seenParams = new Set();
        for (let p = 0; p < m.params.length; p += 1) {
          let descriptor = m.params[p];
          if (descriptor && "$ref" in descriptor) {
            const resolved = resolveJsonPointer(spec, descriptor.$ref);
            if (!resolved.ok) continue;
            descriptor = resolved.value;
          }
          if (!descriptor || typeof descriptor.name !== "string" || !descriptor.schema) {
            errors.push(`${loc} (${m.name}).params[${p}]: invalid ContentDescriptor`);
          } else {
            if (seenParams.has(descriptor.name)) {
              errors.push(`${loc} (${m.name}): duplicate param "${descriptor.name}"`);
            }
            seenParams.add(descriptor.name);
          }
        }
      }
      if (!m.result || typeof m.result.name !== "string" || !m.result.schema) {
        errors.push(`${loc} (${m.name}): missing valid result ContentDescriptor`);
      }
      if (!["0.4.0", "0.5.0", "0.6.0"].includes(m["x-zmux-since"])) {
        errors.push(`${loc} (${m.name}): invalid or missing x-zmux-since`);
      }
    }
  }

  // Validate notifications.
  const notificationNames = new Map();
  const notifications = spec["x-notifications"];
  if (!Array.isArray(notifications) || notifications.length === 0) {
    errors.push("spec['x-notifications'] must be a non-empty array");
  } else {
    for (let i = 0; i < notifications.length; i += 1) {
      const n = notifications[i];
      const loc = `x-notifications[${i}]`;
      if (!n || typeof n.name !== "string" || n.name.length === 0) {
        errors.push(`${loc}: missing string name`);
        continue;
      }
      if (notificationNames.has(n.name)) {
        errors.push(`${loc}: duplicate notification "${n.name}"`);
      }
      notificationNames.set(n.name, n);
      if (!n.params || typeof n.params.name !== "string" || !n.params.schema) {
        errors.push(`${loc} (${n.name}): missing valid params ContentDescriptor`);
      }
      if (!["0.4.0", "0.5.0", "0.6.0"].includes(n["x-zmux-since"])) {
        errors.push(`${loc} (${n.name}): invalid or missing x-zmux-since`);
      }
    }
  }

  // Validate error codes and error kinds.
  const errorObjects = Object.values(spec.components?.errors ?? {});
  const presentCodes = new Set(errorObjects.map((e) => e.code));
  const presentErrorKinds = new Set(errorObjects.map((e) => e.data?.kind).filter(Boolean));
  for (const code of REQUIRED_ERROR_CODES) {
    if (!presentCodes.has(code)) {
      errors.push(`components.errors missing required JSON-RPC error code ${code}`);
    }
  }
  const schemaKinds = new Set(spec.components?.schemas?.ErrorKind?.enum ?? []);
  for (const kind of REQUIRED_ERROR_KINDS) {
    if (!presentErrorKinds.has(kind)) {
      errors.push(`components.errors missing required error data.kind "${kind}"`);
    }
    if (!schemaKinds.has(kind)) {
      errors.push(`components.schemas.ErrorKind missing "${kind}"`);
    }
  }

  // Validate expected v0.4.0 and extension coverage.
  for (const name of EXPECTED_V040_METHODS) {
    const entry = methodNames.get(name);
    if (!entry) errors.push(`missing required v0.4.0 method "${name}"`);
    else if (entry["x-zmux-since"] !== "0.4.0") {
      errors.push(`v0.4.0 method "${name}" must have x-zmux-since "0.4.0"`);
    }
  }
  for (const name of EXPECTED_V040_NOTIFICATIONS) {
    const entry = notificationNames.get(name);
    if (!entry) errors.push(`missing required v0.4.0 notification "${name}"`);
    else if (entry["x-zmux-since"] !== "0.4.0") {
      errors.push(`v0.4.0 notification "${name}" must have x-zmux-since "0.4.0"`);
    }
  }
  for (const name of EXPECTED_EXTENSION_METHODS) {
    const entry = methodNames.get(name);
    if (!entry) errors.push(`missing expected extension method "${name}"`);
    else if (!["0.5.0", "0.6.0"].includes(entry["x-zmux-since"])) {
      errors.push(`extension method "${name}" must be tagged 0.5.0 or 0.6.0`);
    }
  }
  for (const name of EXPECTED_EXTENSION_NOTIFICATIONS) {
    const entry = notificationNames.get(name);
    if (!entry) errors.push(`missing expected extension notification "${name}"`);
    else if (!["0.5.0", "0.6.0"].includes(entry["x-zmux-since"])) {
      errors.push(`extension notification "${name}" must be tagged 0.5.0 or 0.6.0`);
    }
  }

  // Cross-check against Zig sources (src/server.zig, src/server/*.zig, src/protocol.zig).
  let serverMethods = [];
  let sourceNotifications = [];
  let sourceErrorKinds = [];
  if (checkSources) {
    serverMethods = extractServerMethods(repoRoot);
    if (serverMethods.length === 0) {
      errors.push(`no dispatched req.method calls found under ${repoRoot}/src/server(.zig|/*.zig)`);
    }
    for (const method of serverMethods) {
      if (!methodNames.has(method)) {
        errors.push(`server dispatches method "${method}" which is missing from protocol/openrpc.json`);
      }
    }

    sourceNotifications = extractProtocolNotifications(repoRoot);
    for (const notif of sourceNotifications) {
      if (!notificationNames.has(notif)) {
        errors.push(`source declares notification "${notif}" which is missing from protocol/openrpc.json`);
      }
    }

    sourceErrorKinds = extractErrorKinds(repoRoot);
    for (const kind of sourceErrorKinds) {
      if (!schemaKinds.has(kind)) {
        errors.push(`src/protocol.zig declares ErrorKind.${kind} which is missing from openrpc.json`);
      }
    }
  }

  return {
    ok: errors.length === 0,
    errors,
    stats: {
      methods: methodNames.size,
      notifications: notificationNames.size,
      schemas: Object.keys(spec.components?.schemas ?? {}).length,
      errorDefinitions: errorObjects.length,
      serverMethodsChecked: serverMethods.length,
      sourceNotificationsChecked: sourceNotifications.length,
      sourceErrorKindsChecked: sourceErrorKinds.length,
    },
  };
}

const isMain = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  const result = validateSpec();
  if (!result.ok) {
    console.error("OpenRPC validation failed:");
    for (const err of result.errors) {
      console.error(`  - ${err}`);
    }
    process.exit(1);
  }
  const s = result.stats;
  console.log(
    `OpenRPC 1.3.2 spec valid: ${s.methods} methods (${s.serverMethodsChecked} verified in Zig server), ` +
      `${s.notifications} notifications (${s.sourceNotificationsChecked} verified in Zig source), ` +
      `${s.schemas} schemas, ${s.errorDefinitions} error definitions (${s.sourceErrorKindsChecked} kinds verified).`,
  );
}
