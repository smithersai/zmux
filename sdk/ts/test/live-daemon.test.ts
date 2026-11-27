import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { spawn, type ChildProcess } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { ZmuxBridge } from "../src/bridge.ts";
import { ZmuxClient } from "../src/client.ts";
import { ZmuxRpcError } from "../src/errors.ts";
import { attachXterm, type XtermLike } from "../src/xterm.ts";

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, "..", "..", "..");
const zmuxdBin = path.join(repoRoot, "zig-out", "bin", "zmuxd");
const dec = new TextDecoder();

function makeTempSocketDir(prefix: string): { dir: string; socketPath: string } {
  const suffix = crypto.randomBytes(4).toString("hex");
  const dir = `/tmp/${prefix}-${suffix}`;
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  return { dir, socketPath: `${dir}/s.sock` };
}

async function waitForSocket(socketPath: string, timeoutMs = 4000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const client = await ZmuxClient.connect({ socketPath, connectTimeoutMs: 200 });
      try {
        await client.ping({ timeoutMs: 500 });
        return;
      } finally {
        client.close();
      }
    } catch {
      await new Promise((r) => setTimeout(r, 30));
    }
  }
  throw new Error(`zmuxd did not become ready at ${socketPath}`);
}

describe("live zmuxd integration: ZmuxClient, AttachedPane, zmux-ws bridge, xterm", () => {
  let daemonDir = "";
  let socketPath = "";
  let daemonProc: ChildProcess | null = null;
  let bridge: ZmuxBridge | null = null;

  beforeAll(async () => {
    if (!fs.existsSync(zmuxdBin)) {
      throw new Error(`Expected zmuxd binary at ${zmuxdBin}. Run zig build first.`);
    }
    const tmp = makeTempSocketDir("zmux-ts");
    daemonDir = tmp.dir;
    socketPath = tmp.socketPath;

    daemonProc = spawn(zmuxdBin, ["--socket", socketPath, "--idle-seconds", "0"], {
      stdio: "ignore",
    });
    await waitForSocket(socketPath);

    bridge = new ZmuxBridge({
      socketPath,
      host: "127.0.0.1",
      port: 0,
      serveDemo: true,
    });
    await bridge.start();
  });

  afterAll(async () => {
    if (bridge) {
      await bridge.close();
      bridge = null;
    }
    try {
      const client = await ZmuxClient.connect({ socketPath, connectTimeoutMs: 500 });
      await client.shutdown({ timeoutMs: 1000 }).catch(() => {});
      client.close();
    } catch {
      // Already stopped.
    }
    if (daemonProc && daemonProc.exitCode === null) {
      daemonProc.kill("SIGTERM");
    }
    if (daemonDir) {
      fs.rmSync(daemonDir, { recursive: true, force: true });
    }
  });

  test("ZmuxClient exercises core v0.4.0 RPCs, mux tree, keys, commands, and errors", async () => {
    const client = await ZmuxClient.connect({ socketPath });
    try {
      const ping = await client.ping();
      expect(ping.version).toBe("0.5.0");
      expect(ping.socketPath).toBe(socketPath);
      expect(ping.pid).toBeGreaterThan(0);

      const created = await client.createSession({
        id: "alpha",
        rows: 24,
        cols: 80,
        command: "/bin/sh",
      });
      expect(created.sessionId).toBeTruthy();
      expect(created.windowId).toBeTruthy();
      expect(created.paneId).toBeTruthy();
      expect(created.state).toBe("running");

      const list = await client.listSessions();
      expect(list.some((item) => item.paneId === created.paneId && item.sessionName === "alpha")).toBe(true);

      const info = await client.infoSession(created.paneId);
      expect(info.id).toBe(created.paneId);

      await client.resizeSession({ sessionId: created.paneId, rows: 32, cols: 100 });

      const renamedSnap = await client.renameSession({ sessionId: created.sessionId, name: "alpha-renamed" });
      expect(renamedSnap.sessions.some((s) => s.name === "alpha-renamed")).toBe(true);

      const win2 = await client.newWindow({ sessionId: created.sessionId, title: "second", command: "/bin/sh" });
      expect(win2.windowId).not.toBe(created.windowId);
      await client.renameWindow({ windowId: win2.windowId, name: "logs" });
      await client.selectWindow(win2.windowId);

      const split = await client.splitPane({ paneId: win2.paneId, axis: "horizontal", command: "/bin/sh" });
      expect(split.paneId).not.toBe(win2.paneId);
      await client.renamePane({ paneId: split.paneId, title: "right-pane", custom: true });
      await client.selectPane(split.paneId);

      const bindings = await client.bindKey({ key: "x", command: "new-window", table: "prefix" });
      expect(bindings.some((b) => b.key === "x" && b.command === "new-window")).toBe(true);
      const listedKeys = await client.listKeys();
      expect(listedKeys.length).toBeGreaterThanOrEqual(1);

      const unhandled = await client.dispatchKey({ paneId: split.paneId, key: "unbound-key-zzz" });
      expect("handled" in unhandled && unhandled.handled).toBe(false);

      const execSnap = await client.execCommand({ paneId: split.paneId, command: "split-window -v" });
      expect(execSnap.sessions.length).toBeGreaterThanOrEqual(1);

      const sub = await client.subscribeEvents(["*"]);
      expect(sub.ok).toBe(true);
      expect(sub.all).toBe(true);

      // Typed ZmuxRpcError check on nonexistent pane
      try {
        await client.infoSession("does-not-exist-pane");
        expect.unreachable("expected ZmuxRpcError");
      } catch (err) {
        expect(err).toBeInstanceOf(ZmuxRpcError);
        const rpcErr = err as ZmuxRpcError;
        expect(rpcErr.code).toBe(-32000);
        expect(rpcErr.kind).toBe("not_found");
        expect(rpcErr.isKind("not_found")).toBe(true);
      }

      // AbortSignal cancellation check
      const ac = new AbortController();
      ac.abort(new Error("cancelled-by-test"));
      await expect(client.ping({ signal: ac.signal })).rejects.toThrow("cancelled-by-test");

      // Capture & terminate
      await client.send({ sessionId: created.paneId, text: "echo CAPTURE_OK_42", enter: true });
      await new Promise((r) => setTimeout(r, 120));
      const cap = await client.captureSession({ sessionId: created.paneId, lines: 50 });
      expect(cap.text).toContain("CAPTURE_OK_42");

      await client.terminateSession(created.sessionId);
    } finally {
      client.close();
    }
  });

  test("AttachedPane streams output with zero duplicates, waitFor pattern/exit, and reconnect", async () => {
    const client = await ZmuxClient.connect({ socketPath });
    try {
      const pane = await client.attachPane({
        paneId: "stream-test",
        rows: 24,
        cols: 80,
        createIfMissing: { id: "stream-test", command: "/bin/sh", rows: 24, cols: 80 },
      });

      const liveChunks: string[] = [];
      pane.on("data", (bytes) => liveChunks.push(dec.decode(bytes)));

      await pane.send("printf 'MARKER_ALPHA_111\\n'", true);
      const hit1 = await pane.waitFor({ pattern: "MARKER_ALPHA_111", timeoutMs: 5000 });
      expect(hit1.reason).toBe("pattern");
      expect(hit1.match).toBe("MARKER_ALPHA_111");

      // Reconnect on v0.4.0 daemon must NOT duplicate MARKER_ALPHA_111
      const beforeReconnectCount = (pane.bufferedText.match(/MARKER_ALPHA_111/g) ?? []).length;
      await pane.reconnect();
      const afterReconnectCount = (pane.bufferedText.match(/MARKER_ALPHA_111/g) ?? []).length;
      expect(afterReconnectCount).toBe(beforeReconnectCount);

      // Post-reconnect live output & exit detection
      await pane.send("echo MARKER_BETA_222 && exit 7", true);
      const hit2 = await pane.waitFor({ pattern: "MARKER_BETA_222", timeoutMs: 5000 });
      expect(hit2.reason).toBe("pattern");

      const exitRes = await pane.waitFor({ exit: true, timeoutMs: 5000 });
      expect(exitRes.reason).toBe("exit");
      expect(exitRes.exitCode).toBe(7);
      expect(pane.exited).toBe(true);

      await pane.detach();
      await client.terminateSession(pane.sessionId);
    } finally {
      client.close();
    }
  });

  test("ZmuxClient auto-spawns zmuxd when spawnDaemon is true", async () => {
    const tmp = makeTempSocketDir("zmux-spawn");
    try {
      const client = await ZmuxClient.connect({
        socketPath: tmp.socketPath,
        spawnDaemon: true,
        daemonBinary: zmuxdBin,
        daemonIdleSeconds: 10,
        connectTimeoutMs: 4000,
      });
      try {
        const ping = await client.ping();
        expect(ping.version).toBe("0.5.0");
        expect(ping.socketPath).toBe(tmp.socketPath);
        await client.shutdown();
      } finally {
        client.close();
      }
    } finally {
      fs.rmSync(tmp.dir, { recursive: true, force: true });
    }
  });

  test("zmux-ws bridge serves /healthz, authenticated /rpc, /events SSE, and /ws + xterm live", async () => {
    expect(bridge).not.toBeNull();
    const b = bridge!;

    // 1. /healthz
    const healthRes = await fetch(`${b.httpUrl}/healthz`);
    expect(healthRes.status).toBe(200);
    const health = (await healthRes.json()) as { ok: boolean; daemonReachable: boolean };
    expect(health.ok).toBe(true);
    expect(health.daemonReachable).toBe(true);

    // 2. Demo page served at /
    const demoRes = await fetch(`${b.httpUrl}/`);
    expect(demoRes.status).toBe(200);
    expect(await demoRes.text()).toContain("zmux Web Terminal Demo");

    // 3. Auth & Origin rejections on /rpc
    const unauthRes = await fetch(`${b.httpUrl}/rpc`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ id: 1, method: "daemon.ping" }),
    });
    expect(unauthRes.status).toBe(401);

    const badOriginRes = await fetch(`${b.httpUrl}/rpc`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${b.token}`,
        Origin: "https://evil.example",
      },
      body: JSON.stringify({ id: 1, method: "daemon.ping" }),
    });
    expect(badOriginRes.status).toBe(403);

    // 4. Valid POST /rpc
    const rpcRes = await fetch(`${b.httpUrl}/rpc`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${b.token}`,
        Origin: "http://localhost:5173",
      },
      body: JSON.stringify({ jsonrpc: "2.0", id: 9, method: "daemon.ping", params: {} }),
    });
    expect(rpcRes.status).toBe(200);
    expect(rpcRes.headers.get("access-control-allow-origin")).toBe("http://localhost:5173");
    const rpcBody = (await rpcRes.json()) as { id: number; result: { version: string } };
    expect(rpcBody.id).toBe(9);
    expect(rpcBody.result.version).toBe("0.5.0");

    // 5. SSE /events live stream
    const unauthSse = await fetch(`${b.httpUrl}/events`);
    expect(unauthSse.status).toBe(401);

    const sseAbort = new AbortController();
    const sseRes = await fetch(`${b.httpUrl}/events?panes=*`, {
      headers: { Authorization: `Bearer ${b.token}` },
      signal: sseAbort.signal,
    });
    expect(sseRes.status).toBe(200);
    expect(sseRes.headers.get("content-type")).toContain("text/event-stream");

    // Spawn a pane via /rpc that prints a unique token and read it from SSE
    const createRes = await fetch(`${b.httpUrl}/rpc`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${b.token}`,
      },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 10,
        method: "session.create",
        params: { id: "sse-pane", command: "/bin/sh -c 'echo SSE_LIVE_TOKEN_999; sleep 0.2'" },
      }),
    });
    const createdPane = (await createRes.json()) as { result: { sessionId: string; paneId: string } };
    expect(createdPane.result.paneId).toBeTruthy();

    const reader = sseRes.body!.getReader();
    let sseAccum = "";
    let sawOutput = false;
    const sseDeadline = Date.now() + 5000;
    while (Date.now() < sseDeadline) {
      const { value, done } = await reader.read();
      if (done) break;
      sseAccum += dec.decode(value, { stream: true });
      if (sseAccum.includes("event: pane_output") && sseAccum.includes(createdPane.result.paneId)) {
        sawOutput = true;
        break;
      }
    }
    sseAbort.abort();
    expect(sawOutput).toBe(true);

    // 6. Live WebSocket /ws end-to-end via @smithers/zmux/xterm attachXterm!
    const xtermWritten: string[] = [];
    let termInput: ((data: string) => void) | null = null;
    const mockXterm: XtermLike = {
      cols: 90,
      rows: 26,
      write(data) {
        xtermWritten.push(typeof data === "string" ? data : dec.decode(data));
      },
      onData(cb) {
        termInput = cb;
        return { dispose() {} };
      },
    };

    const attachedPromise = new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("xterm attach timed out")), 5000);
      const attachment = attachXterm(mockXterm, {
        url: b.wsUrl,
        token: b.token,
        target: "ws-xterm-live",
        createIfMissing: { id: "ws-xterm-live", command: "/bin/sh", rows: 26, cols: 90 },
        onAttach() {
          clearTimeout(timer);
          resolve();
        },
        onError(err) {
          clearTimeout(timer);
          reject(err);
        },
      });
      // Save for cleanup below
      (mockXterm as unknown as { _att?: typeof attachment })._att = attachment;
    });

    await attachedPromise;
    const attachment = (mockXterm as unknown as { _att: ReturnType<typeof attachXterm> })._att;
    try {
      expect(attachment.status).toBe("connected");
      expect(attachment.paneId).toBeTruthy();

      termInput!("echo WS_XTERM_E2E_777\r");

      const deadline = Date.now() + 5000;
      while (Date.now() < deadline && !xtermWritten.join("").includes("WS_XTERM_E2E_777")) {
        await new Promise((r) => setTimeout(r, 30));
      }
      expect(xtermWritten.join("")).toContain("WS_XTERM_E2E_777");

      // Clean up sessions created in this test
      const ctl = await ZmuxClient.connect({ socketPath });
      try {
        await ctl.terminateSession(attachment.sessionId).catch(() => {});
        await ctl.terminateSession(createdPane.result.sessionId).catch(() => {});
      } finally {
        ctl.close();
      }
    } finally {
      attachment.dispose();
    }
  });

  test("ZmuxClient exercises live v0.5.0 VT screen, agent RPCs, layout ops, recording, and delta resume", async () => {
    const client = await ZmuxClient.connect({ socketPath });
    const recPath = path.join(path.dirname(socketPath), "live-v05.cast");
    try {
      await client.subscribeEvents(["*"]);
      const titleEvents: string[] = [];
      client.on("pane_title_changed", (ev) => titleEvents.push(ev.title));

      const created = await client.createSession({
        id: "v05-live",
        command: "/bin/sh",
        rows: 20,
        cols: 70,
        env: { HOME: "/nonexistent", PS1: "$ " },
      });

      // pane.exec with output capture + exitCode 0 and non-zero
      const ex0 = await client.execPane({
        paneId: created.paneId,
        command: "printf '\\033]2;ts-v05-title\\007\\033]7;file://h/tmp\\007HELLO_V05_EXEC'",
        timeoutMs: 5000,
      });
      expect(ex0.exitCode).toBe(0);
      expect(ex0.timedOut).toBe(false);
      expect(ex0.output).toContain("HELLO_V05_EXEC");

      const ex7 = await client.execPane({
        paneId: created.paneId,
        command: "(exit 7)",
        captureOutput: false,
        timeoutMs: 5000,
      });
      expect(ex7.exitCode).toBe(7);

      // session.screen + formatted session.capture
      const screen = await client.screen({
        paneId: created.paneId,
        includeCells: true,
        includeAnsiRestore: true,
        includeScrollback: 5,
      });
      expect(screen.rows).toBe(20);
      expect(screen.cols).toBe(70);
      expect(screen.title).toBe("ts-v05-title");
      expect(screen.cwd).toBe("/tmp");
      expect(screen.text).toContain("HELLO_V05_EXEC");
      expect(Array.isArray(screen.cells)).toBe(true);
      expect(typeof screen.ansiRestore).toBe("string");
      expect(screen.ansiRestore!.length).toBeGreaterThan(0);

      const capPlain = await client.captureSession({
        paneId: created.paneId,
        format: "plain",
      });
      expect(capPlain.text).toContain("HELLO_V05_EXEC");

      // pane.wait + pane.signal
      await client.send({
        paneId: created.paneId,
        text: "trap 'echo SIG_TRAPPED_TS' USR1; echo WAIT_READY_TS",
        enter: true,
      });
      const w1 = await client.waitPane({
        paneId: created.paneId,
        pattern: "WAIT_READY_TS",
        timeoutMs: 5000,
      });
      expect(w1.matched).toBe(true);
      expect(w1.reason).toBe("pattern");

      const sigRes = await client.signalPane({ paneId: created.paneId, signal: "SIGUSR1" });
      expect(sigRes.ok).toBe(true);
      expect(sigRes.signal).toBe("SIGUSR1");

      const w2 = await client.waitPane({
        paneId: created.paneId,
        pattern: "SIG_TRAPPED_TS",
        timeoutMs: 5000,
      });
      expect(w2.matched).toBe(true);

      // pane.record start -> status -> stop (asciicast v2)
      const recStart = await client.recordPane({
        paneId: created.paneId,
        action: "start",
        path: recPath,
      });
      expect(recStart.recording).toBe(true);
      expect(recStart.format).toBe("asciicast-v2");
      await client.send({ paneId: created.paneId, text: "echo CAST_LINE", enter: true });
      await client.waitPane({ paneId: created.paneId, pattern: "CAST_LINE", timeoutMs: 5000 });
      const recStop = await client.recordPane({ paneId: created.paneId, action: "stop" });
      expect(recStop.recording).toBe(false);
      expect(recStop.bytesWritten).toBeGreaterThan(0);
      expect(fs.readFileSync(recPath, "utf8")).toContain('"version":2');

      // pane.metadata + pane.split + pane.resizeSplit + pane.zoom + client.attach(vt, readOnly, resume) + client.setMode
      const meta = await client.setMetadata({
        paneId: created.paneId,
        set: { agent: "claude", task: "v05-test" },
      });
      expect(meta.metadata.agent).toBe("claude");
      expect(meta.metadata.task).toBe("v05-test");

      const split = await client.splitPane({
        paneId: created.paneId,
        axis: "horizontal",
        command: "/bin/sh",
      });
      await client.resizeSplit({ paneId: split.paneId, ratio: 0.65 });
      const zoomedSnap = await client.zoomPane({ paneId: split.paneId, zoomed: true });
      const zoomedWin = zoomedSnap.sessions
        .find((s) => s.id === created.sessionId)
        ?.windows.find((w) => w.id === created.windowId);
      expect(zoomedWin?.zoomedPaneId).toBe(split.paneId);

      const attVt = await client.attach({
        paneId: created.paneId,
        rows: 20,
        cols: 70,
        readOnly: true,
        replayMode: "vt",
      });
      expect(attVt.readOnly).toBe(true);
      expect(attVt.replayMode).toBe("ansi_restore");

      const modeUpdated = await client.setClientMode({
        clientId: attVt.clientId,
        readOnly: false,
        resizePolicy: "smallest",
      });
      expect(modeUpdated.readOnly).toBe(false);
      expect(modeUpdated.resizePolicy).toBe("smallest");

      const attResume = await client.attach({
        paneId: created.paneId,
        readOnly: true,
        resumeFromOffset: attVt.replayEndOffset,
        resumeGeneration: attVt.generation,
      });
      expect(attResume.resumed).toBe(true);
      expect(attResume.truncated).toBe(false);

      // pane.close + window.close
      await client.closePane(split.paneId);
      const afterWinClose = await client.closeWindow(created.windowId);
      expect(afterWinClose.sessions.find((s) => s.id === created.sessionId)).toBeUndefined();
      expect(titleEvents).toContain("ts-v05-title");
    } finally {
      fs.rmSync(recPath, { force: true });
      client.close();
    }
  });
});
