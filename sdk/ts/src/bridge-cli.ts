#!/usr/bin/env node
import { ZmuxBridge } from "./bridge.ts";

interface CliConfig {
  host: string;
  port: number;
  socketPath?: string;
  token?: string;
  allowOrigins: string[];
  spawnDaemon: boolean;
  serveDemo: boolean;
  help: boolean;
}

function parseArgs(argv: string[]): CliConfig {
  const cfg: CliConfig = {
    host: "127.0.0.1",
    port: 7681,
    allowOrigins: [],
    spawnDaemon: false,
    serveDemo: false,
    help: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i]!;
    switch (arg) {
      case "-h":
      case "--help":
        cfg.help = true;
        break;
      case "--host":
        cfg.host = argv[++i] ?? cfg.host;
        break;
      case "--port": {
        const raw = argv[++i];
        const parsed = Number(raw);
        if (!Number.isInteger(parsed) || parsed < 0 || parsed > 65535) {
          throw new Error(`Invalid --port value: ${String(raw)}`);
        }
        cfg.port = parsed;
        break;
      }
      case "--socket":
        cfg.socketPath = argv[++i];
        break;
      case "--token":
        cfg.token = argv[++i];
        break;
      case "--allow-origin": {
        const val = argv[++i];
        if (!val) throw new Error("--allow-origin requires a value");
        for (const item of val.split(",")) {
          const trimmed = item.trim();
          if (trimmed.length > 0) cfg.allowOrigins.push(trimmed);
        }
        break;
      }
      case "--spawn-daemon":
        cfg.spawnDaemon = true;
        break;
      case "--demo":
        cfg.serveDemo = true;
        break;
      default:
        throw new Error(`Unknown option: ${arg}`);
    }
  }
  return cfg;
}

function printHelp(): void {
  console.log(`zmux-ws: Authenticated WebSocket and HTTP/SSE bridge for zmuxd

Usage:
  zmux-ws [options]

Options:
  --host <addr>           Bind address (default 127.0.0.1)
  --port <port>           Listen port (default 7681)
  --socket <path>         Path to zmuxd UNIX socket
  --token <secret>        Bearer token (generated randomly if omitted)
  --allow-origin <url>    Allowed CORS/WebSocket Origin (repeatable, defaults to localhost)
  --spawn-daemon          Auto-spawn zmuxd if not already listening
  --demo                  Serve the browser terminal demo at GET /
  -h, --help              Show this help message`);
}

async function main(): Promise<void> {
  const cfg = parseArgs(process.argv.slice(2));
  if (cfg.help) {
    printHelp();
    return;
  }

  const bridge = new ZmuxBridge({
    host: cfg.host,
    port: cfg.port,
    socketPath: cfg.socketPath,
    token: cfg.token ?? process.env.ZMUX_WS_TOKEN,
    allowOrigins: cfg.allowOrigins.length > 0 ? cfg.allowOrigins : undefined,
    spawnDaemon: cfg.spawnDaemon,
    serveDemo: cfg.serveDemo,
  });

  const info = await bridge.start();
  console.log(`zmux-ws listening on ${info.httpUrl}`);
  console.log(`  WebSocket : ${info.wsUrl}`);
  console.log(`  HTTP RPC  : ${info.httpUrl}/rpc`);
  console.log(`  SSE Events: ${info.httpUrl}/events`);
  console.log(`  Health    : ${info.httpUrl}/healthz`);
  if (cfg.serveDemo) {
    console.log(`  Demo UI   : ${info.httpUrl}/`);
  }
  console.log(`  UNIX Sock : ${bridge.socketPath}`);
  if (bridge.tokenGenerated) {
    console.log(`  Token     : ${bridge.token}`);
  }

  const shutdown = () => {
    void bridge.close().finally(() => process.exit(0));
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

main().catch((err) => {
  console.error(`zmux-ws failed: ${(err as Error).message}`);
  process.exit(1);
});
