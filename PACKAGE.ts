import { Smithers as S } from "@smthrs/targets"

// mise.toml pins Zig 0.17.1 (build.zig.zon minimum_zig_version). `mise install`
// puts it on PATH; set ZIG to an absolute zig when PATH carries another one,
// for example ZIG="$(mise which zig)". The binary's bytes are cache-key input.
const zig = S.Host.bin("zig", { env: "ZIG" })
const node = S.Host.bin("node")

// Exact per-module Zig dependency closures so Smithers invalidates and runs
// only the unit tests and performance benchmarks whose inputs actually changed.
const buildManifests = ["build.zig", "build.zig.zon"] as const
const benchHarness = ["bench/bench.zig"] as const

const files = (paths: ReadonlyArray<string>) => [...new Set(paths)].sort().map((path) => S.file(path))

const bufferSrcs = ["src/buffer.zig", "src/buffer/capture.zig"] as const
const protocolSrcs = [
  "src/protocol.zig",
  "src/protocol/errors.zig",
  "src/protocol/frames.zig",
  "src/protocol/request.zig",
  "src/protocol/text.zig"
] as const
const logSrcs = ["src/log.zig", "src/log/format.zig"] as const
const sysSrcs = [
  "src/sys.zig",
  "src/sys/child.zig",
  "src/sys/fd.zig",
  "src/sys/fs.zig",
  "src/sys/private.zig",
  "src/sys/socket.zig"
] as const
const foregroundSrcs = [
  "src/foreground.zig",
  "src/foreground/argv.zig",
  "src/foreground/darwin.zig",
  "src/foreground/linux.zig",
  ...protocolSrcs,
  ...sysSrcs
] as const
const socketPathSrcs = ["src/socket_path.zig", ...sysSrcs] as const
const rpcLineReaderSrcs = [
  "src/rpc_line_reader.zig",
  "src/rpc_line_reader/wait.zig",
  ...sysSrcs
] as const
const ptySrcs = [
  "src/pty.zig",
  "src/pty/child.zig",
  "src/pty/env.zig",
  "src/pty/proc.zig",
  "src/pty/session.zig",
  "src/pty/signal.zig",
  "src/pty/spawn.zig",
  ...sysSrcs
] as const
const nativeSrcs = [
  "src/native.zig",
  "src/native/control.zig",
  "src/native/events.zig",
  "src/native/harness.zig",
  "src/native/keys.zig",
  "src/native/reader.zig",
  "src/native/session.zig",
  ...bufferSrcs,
  ...foregroundSrcs,
  ...logSrcs,
  ...ptySrcs,
  ...protocolSrcs
] as const
const muxSrcs = [
  "src/mux.zig",
  "src/mux/attach.zig",
  "src/mux/commands.zig",
  "src/mux/creation.zig",
  "src/mux/events.zig",
  "src/mux/invariants.zig",
  "src/mux/json.zig",
  "src/mux/layout.zig",
  "src/mux/lookup.zig",
  "src/mux/removal.zig",
  "src/mux/respawn.zig",
  "src/mux/types.zig",
  ...bufferSrcs,
  ...nativeSrcs
] as const
const connectSrcs = [
  "src/connect.zig",
  "src/connect/cli.zig",
  "src/connect/events.zig",
  "src/connect/rpc.zig",
  "src/connect/run_loop.zig",
  "src/connect/spawn.zig",
  "src/connect/terminal.zig",
  "src/connect/verbs.zig",
  "src/connect/wire.zig",
  ...rpcLineReaderSrcs,
  ...protocolSrcs,
  ...socketPathSrcs,
  ...sysSrcs
] as const
const serverSrcs = [
  "src/server.zig",
  "src/server/accept.zig",
  "src/server/conn_queue.zig",
  "src/server/conn_routes.zig",
  "src/server/conn_writer.zig",
  "src/server/connection.zig",
  "src/server/dispatch.zig",
  "src/server/events.zig",
  "src/server/fuzz_hooks.zig",
  "src/server/lifecycle.zig",
  "src/server/limits.zig",
  "src/server/params.zig",
  "src/server/payload.zig",
  "src/server/rpc_client.zig",
  "src/server/rpc_layout.zig",
  "src/server/rpc_session.zig",
  "src/server/socket_bind.zig",
  "src/server/socket_dir.zig",
  "src/server/socket_io.zig",
  "src/server/startup.zig",
  "src/server/test_support.zig",
  ...logSrcs,
  ...muxSrcs,
  ...nativeSrcs,
  ...protocolSrcs,
  ...rpcLineReaderSrcs,
  ...socketPathSrcs,
  ...sysSrcs,
  ...bufferSrcs
] as const
const daemonSrcs = [
  "src/daemon.zig",
  "src/daemon/cli.zig",
  "src/daemon/lock.zig",
  "src/daemon/paths.zig",
  "src/daemon/pidfile.zig",
  ...logSrcs,
  ...protocolSrcs,
  ...serverSrcs,
  ...socketPathSrcs,
  ...sysSrcs
] as const
const mainSrcs = ["src/main.zig", ...daemonSrcs, ...connectSrcs] as const

const unitTest = (step: string, cacheKey: string, srcs: ReadonlyArray<string>) =>
  S.Shell.Test({
    bin: zig,
    args: ["build", "--cache-dir", `.zig-cache/smthrs-test-${cacheKey}`, step],
    data: files([...srcs, ...buildManifests]),
    timeout: "5m"
  })

// Benchmarks are Shell.Build targets so their JSON result is a declared,
// cacheable output: unchanged modules replay the cached JSON into
// .benchmarks/ and only modules whose closure changed re-measure.
// (Shell.Test has no outputs, so it cannot feed benchReport.)
const benchTarget = (step: string, fileStem: string, srcs: ReadonlyArray<string>) =>
  S.Shell.Build({
    bin: zig,
    args: [
      "build",
      "--cache-dir",
      `.zig-cache/smthrs-bench-${fileStem}`,
      `bench-${step}`,
      "--",
      "--json-out",
      `.benchmarks/${fileStem}.json`
    ],
    data: files([...srcs, ...benchHarness, `bench/${fileStem}_bench.zig`, ...buildManifests]),
    outFiles: [`.benchmarks/${fileStem}.json`],
    timeout: "5m"
  })

// --- Lint & Build -----------------------------------------------------------

const fmtCheck = S.Shell.Test({
  bin: zig,
  args: ["fmt", "--check", "src", "test", "bench", "build.zig", "build.zig.zon"],
  data: [
    S.glob("src/**/*.zig"),
    S.glob("test/**/*.zig"),
    S.glob("bench/**/*.zig"),
    ...files(buildManifests)
  ]
})

const build = S.Shell.Build({
  bin: zig,
  args: ["build", "--cache-dir", ".zig-cache/smthrs-build", "-Doptimize=ReleaseSafe"],
  data: files([...mainSrcs, ...buildManifests]),
  outDirs: ["zig-out/bin"],
  timeout: "10m"
})

// Release cross-compiles mirror .github/workflows/release.yml targets.
const crossBuild = (triple: string) =>
  S.Shell.Build({
    bin: zig,
    args: [
      "build",
      "--cache-dir",
      `.zig-cache/smthrs-build-${triple}`,
      "--prefix",
      `zig-out/cross/${triple}`,
      `-Dtarget=${triple}`,
      "-Doptimize=ReleaseSafe"
    ],
    data: files([...mainSrcs, ...buildManifests]),
    outDirs: [`zig-out/cross/${triple}/bin`],
    timeout: "10m"
  })

const buildX8664LinuxMusl = crossBuild("x86_64-linux-musl")
const buildAarch64LinuxMusl = crossBuild("aarch64-linux-musl")
const buildX8664Macos = crossBuild("x86_64-macos")
const buildAarch64Macos = crossBuild("aarch64-macos")

// --- Incremental Unit, Fuzz & Integration Tests -----------------------------

const testBuffer = unitTest("test-buffer", "buffer", bufferSrcs)
const testProtocol = unitTest("test-protocol", "protocol", protocolSrcs)
const testRpcLineReader = unitTest("test-rpc-line-reader", "rpc-line-reader", rpcLineReaderSrcs)
const testLog = unitTest("test-log", "log", logSrcs)
const testForeground = unitTest("test-foreground", "foreground", foregroundSrcs)
const testSys = unitTest("test-sys", "sys", sysSrcs)
const testSocketPath = unitTest("test-socket-path", "socket-path", socketPathSrcs)
const testPty = unitTest("test-pty", "pty", ptySrcs)
const testNative = unitTest("test-native", "native", nativeSrcs)
const testMux = unitTest("test-mux", "mux", muxSrcs)
const testConnect = unitTest("test-connect", "connect", connectSrcs)
const testServer = unitTest("test-server", "server", serverSrcs)
const testDaemon = unitTest("test-daemon", "daemon", daemonSrcs)
const testMain = unitTest("test-main", "main", [...mainSrcs, "README.md"])

const testFuzz = S.Shell.Test({
  bin: zig,
  args: ["build", "--cache-dir", ".zig-cache/smthrs-test-fuzz", "fuzz"],
  data: [...files([...mainSrcs, ...buildManifests]), S.glob("test/fuzz/**/*.zig")],
  timeout: "5m"
})

// Bounded coverage-guided fuzzing. Each run is keyed on its inputs, so an
// unchanged closure replays the green result instead of re-fuzzing.
const fuzzCoverage = S.Shell.Test({
  bin: zig,
  args: [
    "build",
    "--cache-dir",
    ".zig-cache/smthrs-fuzz-coverage",
    "fuzz",
    "-Doptimize=ReleaseSafe",
    "--fuzz=10K"
  ],
  data: [...files([...mainSrcs, ...buildManifests]), S.glob("test/fuzz/**/*.zig")],
  timeout: "15m"
})

// Live PTY and UNIX-socket chaos fuzzers spawn real PTYs and daemons, so they
// sit in the exclusive tier: run with --include-exclusive or by label.
const fuzzLive = S.Shell.Test({
  exclusive: true,
  bin: zig,
  args: ["build", "--cache-dir", ".zig-cache/smthrs-fuzz-live", "fuzz-live", "--fuzz=30"],
  data: [...files([...mainSrcs, ...buildManifests]), S.glob("test/fuzz/**/*.zig")],
  timeout: "15m"
})

const testIntegration = S.Shell.Test({
  bin: zig,
  args: ["build", "--cache-dir", ".zig-cache/smthrs-test-integration", "test-integration"],
  data: files([...mainSrcs, "test/integration/session_daemon.zig", ...buildManifests]),
  timeout: "10m"
})

// --- Incremental Performance Benchmarks -------------------------------------

const benchBuffer = benchTarget("buffer", "buffer", bufferSrcs)
const benchProtocol = benchTarget("protocol", "protocol", protocolSrcs)
const benchRpcLineReader = benchTarget("rpc-line-reader", "rpc_line_reader", [...rpcLineReaderSrcs, "src/main.zig"])
const benchLog = benchTarget("log", "log", logSrcs)
const benchForeground = benchTarget("foreground", "foreground", foregroundSrcs)
const benchSys = benchTarget("sys", "sys", sysSrcs)
const benchSocketPath = benchTarget("socket-path", "socket_path", socketPathSrcs)
const benchPty = benchTarget("pty", "pty", ptySrcs)
const benchNative = benchTarget("native", "native", [...nativeSrcs, "src/main.zig"])
const benchMux = benchTarget("mux", "mux", muxSrcs)
const benchConnect = benchTarget("connect", "connect", [...connectSrcs, "src/main.zig"])
const benchDaemon = benchTarget("daemon", "daemon", daemonSrcs)
const benchServer = benchTarget("server", "server", [...serverSrcs, "src/main.zig"])

const allBenchTargets = [
  benchBuffer,
  benchProtocol,
  benchRpcLineReader,
  benchLog,
  benchForeground,
  benchSys,
  benchSocketPath,
  benchPty,
  benchNative,
  benchMux,
  benchConnect,
  benchDaemon,
  benchServer
]

// Aggregates all per-module benchmark JSON outputs (newly run for modified
// modules, cache-restored for unchanged modules) and compares against
// bench/baseline.json so any change immediately shows the full perf diff.
// Kept as Shell.Run so `affected build` / `affected ci` never pulls unrelated
// benchmarks into a cold-cache run.
const benchReport = S.Shell.Run({
  bin: zig,
  args: [
    "build",
    "--cache-dir",
    ".zig-cache/smthrs-bench-report",
    "bench-report",
    "--",
    "--results-dir",
    ".benchmarks",
    "--baseline",
    "bench/baseline.json",
    "--markdown-out",
    ".benchmarks/report.md"
  ],
  data: [
    ...files(["bench/report.zig", ...benchHarness, "bench/baseline.json", ...buildManifests]),
    ...allBenchTargets
  ],
  timeout: "5m"
})

const bench = S.Alias(benchReport)

const benchUpdateBaseline = S.Shell.Run({
  manual: true,
  bin: zig,
  args: [
    "build",
    "--cache-dir",
    ".zig-cache/smthrs-bench-report",
    "bench-report",
    "--",
    "--results-dir",
    ".benchmarks",
    "--baseline",
    "bench/baseline.json",
    "--write-baseline",
    "bench/baseline.json"
  ],
  data: [
    ...files(["bench/report.zig", ...benchHarness, ...buildManifests]),
    ...allBenchTargets
  ],
  timeout: "5m"
})

// Builds the public static docs portal, llms.txt index, Engineering Wiki,
// Protocol Inspector, and Lighthouse Backpressure Audit Report into dist/site/.
const docsSite = S.Shell.Build({
  bin: node,
  args: ["scripts/build-docs.mjs"],
  data: [
    S.file("scripts/build-docs.mjs"),
    S.file("scripts/install.sh"),
    S.file("README.md"),
    S.file("CHANGELOG.md"),
    S.file("CONTRIBUTING.md"),
    S.file("AGENTS.md"),
    S.file(".agents/uphill/rules.md"),
    S.file(".smithers/coding-project.json"),
    S.file(".smithers/home.json"),
    S.file(".smithers/trust-policy.json"),
    S.file(".smithers/views/backpressure/run.mjs"),
    S.file(".smithers/views/backpressure/index.html"),
    S.file(".smithers/playground/index.html"),
    S.file("bench/baseline.json"),
    S.glob(".smithers/wiki/**")
  ],
  outDirs: ["dist/site"],
  timeout: "2m"
})

export const Package = S.Package({
  defaultVisibility: "public",
  targets: {
    fmtCheck,
    build,
    buildX8664LinuxMusl,
    buildAarch64LinuxMusl,
    buildX8664Macos,
    buildAarch64Macos,
    testBuffer,
    testProtocol,
    testRpcLineReader,
    testLog,
    testForeground,
    testSys,
    testSocketPath,
    testPty,
    testNative,
    testMux,
    testConnect,
    testServer,
    testDaemon,
    testMain,
    testFuzz,
    fuzzCoverage,
    fuzzLive,
    testIntegration,
    benchBuffer,
    benchProtocol,
    benchRpcLineReader,
    benchLog,
    benchForeground,
    benchSys,
    benchSocketPath,
    benchPty,
    benchNative,
    benchMux,
    benchConnect,
    benchDaemon,
    benchServer,
    benchReport,
    bench,
    benchUpdateBaseline,
    docsSite
  }
})
