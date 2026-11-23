import { Smithers as S } from "@smthrs/targets"

const zig = S.Host.bin("zig", { env: "ZIG" })

// Exact per-module Zig dependency closures so Smithers invalidates and runs
// only the unit tests and performance benchmarks whose inputs actually changed.
const buildManifests = ["build.zig", "build.zig.zon"] as const
const benchHarness = ["bench/bench.zig"] as const

const files = (paths: ReadonlyArray<string>) => [...new Set(paths)].sort().map((path) => S.file(path))

const bufferSrcs = ["src/buffer.zig"] as const
const protocolSrcs = ["src/protocol.zig"] as const
const logSrcs = ["src/log.zig"] as const
const foregroundSrcs = ["src/foreground.zig"] as const
const sysSrcs = ["src/sys.zig"] as const
const rpcLineReaderSrcs = ["src/rpc_line_reader.zig", ...sysSrcs] as const
const ptySrcs = ["src/pty.zig", ...sysSrcs] as const
const nativeSrcs = ["src/native.zig", ...bufferSrcs, ...foregroundSrcs, ...ptySrcs, ...protocolSrcs] as const
const muxSrcs = ["src/mux.zig", ...bufferSrcs, ...nativeSrcs] as const
const connectSrcs = ["src/connect.zig", ...rpcLineReaderSrcs, ...protocolSrcs, ...sysSrcs] as const
const serverSrcs = [
  "src/server.zig",
  ...logSrcs,
  ...muxSrcs,
  ...nativeSrcs,
  ...protocolSrcs,
  ...rpcLineReaderSrcs,
  ...sysSrcs,
  ...bufferSrcs
] as const
const daemonSrcs = ["src/daemon.zig", ...logSrcs, ...protocolSrcs, ...serverSrcs, ...sysSrcs] as const
const mainSrcs = ["src/main.zig", ...daemonSrcs, ...connectSrcs] as const

const unitTest = (step: string, cacheKey: string, srcs: ReadonlyArray<string>) =>
  S.Shell.Test({
    bin: zig,
    args: ["build", "--cache-dir", `.zig-cache/smthrs-test-${cacheKey}`, step],
    data: files([...srcs, ...buildManifests]),
    timeout: "5m"
  })

const benchTarget = (step: string, fileStem: string, srcs: ReadonlyArray<string>) =>
  S.Shell.Test({
    exclusive: true,
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

// --- Incremental Unit, Fuzz & Integration Tests -----------------------------

const testBuffer = unitTest("test-buffer", "buffer", bufferSrcs)
const testProtocol = unitTest("test-protocol", "protocol", protocolSrcs)
const testRpcLineReader = unitTest("test-rpc-line-reader", "rpc-line-reader", rpcLineReaderSrcs)
const testLog = unitTest("test-log", "log", logSrcs)
const testForeground = unitTest("test-foreground", "foreground", foregroundSrcs)
const testSys = unitTest("test-sys", "sys", sysSrcs)
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

export const Package = S.Package({
  defaultVisibility: "public",
  targets: {
    fmtCheck,
    build,
    testBuffer,
    testProtocol,
    testRpcLineReader,
    testLog,
    testForeground,
    testSys,
    testPty,
    testNative,
    testMux,
    testConnect,
    testServer,
    testDaemon,
    testMain,
    testFuzz,
    testIntegration,
    benchBuffer,
    benchProtocol,
    benchRpcLineReader,
    benchLog,
    benchForeground,
    benchSys,
    benchPty,
    benchNative,
    benchMux,
    benchConnect,
    benchDaemon,
    benchServer,
    benchReport,
    bench,
    benchUpdateBaseline
  }
})
