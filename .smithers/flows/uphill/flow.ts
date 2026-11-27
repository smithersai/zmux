import { Flow } from "@smthrs/flow"
import { Node } from "@smthrs/plan"
import { CiJob } from "@smthrs/sandbox"
import { Schema } from "effect"

const uphillJob = CiJob.make("uphill", {
  steps: [{ name: "uphill-audit", run: "sh .smithers/scripts/hosted-uphill.sh" }]
})

export default Flow.make("uphill", {
  description: "Run Uphill continuous metrics, validate metric definitions, and report compact scores and opportunities.",
  capabilities: ["proc:spawn:sh .smithers/scripts/hosted-uphill.sh"],
  effects: {
    reads: ["**"],
    writes: [".uphill/**"],
    mode: "expected",
    onConflict: "serialize",
    tier: "irreversible"
  },
  modelInvocable: true,
  payload: {
    run: Schema.String, repo: Schema.String, sha: Schema.String, ref: Schema.String, event: Schema.String
  },
  success: Schema.Struct({
    uphill: CiJob.Result
  }),
  body: (run) => Node.all({ uphill: uphillJob.call(run) })
})
