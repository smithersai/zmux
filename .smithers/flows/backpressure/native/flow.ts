import { Action, Flow } from "@smthrs/flow"
import { Node } from "@smthrs/plan"
import { Config, Effect, Schema } from "effect"
import { ChildProcess, ChildProcessSpawner } from "effect/process"

const version = "backpressure/native-v1"
const payload = Schema.Struct({
  input: Schema.Struct({ args: Schema.String.check(Schema.isMaxLength(4096)) })
})

class BackpressureFailed extends Schema.TaggedError<BackpressureFailed>()("BackpressureAuditFailed", {}) {}

const CollectAudit = Action.make("backpressure/collect-native", {
  implementationVersion: version,
  payload,
  success: Schema.Json,
  error: BackpressureFailed
})

export const layer = CollectAudit.toLayer(
  (request) =>
    Effect.gen(function*() {
      const spawner = yield* ChildProcessSpawner.ChildProcessSpawner
      const path = yield* Config.String("PATH")
      const command = ChildProcess.make("node", [".smithers/views/backpressure/run.mjs", request.input.args], {
        extendEnv: false,
        env: { PATH: path },
        stdin: "ignore"
      })
      const stdout = yield* spawner.string(command)
      return yield* Schema.decodeEffect(Schema.fromJsonString(Schema.Json))(stdout)
    }).pipe(
      Effect.timeout("25 seconds"),
      Effect.mapError(() => new BackpressureFailed())
    ),
  { implementationVersion: version }
)

export default Flow.make("backpressure/native", {
  description: "Collect the zmux Lighthouse backpressure audit JSON (Uphill scores, fuzz harnesses, benchmarks, and trust provenance)",
  capabilities: ["fs:read:**", "proc:spawn:node .smithers/views/backpressure/run.mjs *"],
  effects: {
    reads: [".uphill/**", ".agents/uphill/**", "bench/baseline.json", ".smithers/trust-policy.json", "src/**", "test/fuzz/**"],
    writes: [],
    mode: "expected",
    onConflict: "serialize"
  },
  modelInvocable: false,
  payload,
  success: Schema.Json,
  error: BackpressureFailed,
  body: Node.capture({ version }, (input: typeof payload.Type) => CollectAudit.call(input))
})
