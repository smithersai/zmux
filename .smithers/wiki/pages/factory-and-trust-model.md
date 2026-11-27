# Smithers Cloud factory, object store, and trust model

`zmux` runs publicly on Smithers Cloud at `https://smithers.sh/smithersai/zmux` and mirrors every landed change to `https://github.com/smithersai/zmux`.

## Personalized UI by audience

`.smithers/home.json` declares three tailored views using the `@smthrs/views` audience contract (`contributors: "role"`):

- **Maintainers (`maintainer`):** Control room with one-key branch creation, live issues and pull requests, recent factory runs (failures first), mythical history stack, live Lighthouse backpressure audit view, and ops links.
- **Contributors (`contributor`):** Anyone who has contributed at least one merged change or holds a repository role sees fast setup commands, how-a-change-lands cards, factory flows, wiki links, and an internals prompt in addition to the public view.
- **Viewers (`everyone`):** Clean product landing page with hero, `zig fetch` install snippet, key stats, UNIX-socket and Zig embedding examples, feature cards, interactive Protocol Inspector, Lighthouse Backpressure Report, releases, and docs.

## Shared Smithers Cloud object store and trust boundary

All builds, tests, fuzz runs, and benchmarks share the remote action cache and CAS at `https://build.smithers.sh` (`result-only-v1`, `/ac` + `/cas`), governed by `.smithers/trust-policy.json`:

| Execution context | Allowed? | Object store access | Can write cache? | Can satisfy merge gates? |
| --- | --- | --- | --- | --- |
| Non-maintainer local run or PR | Yes, encouraged | Read-only (`SMITHERS_CACHE_READ_TOKEN`) | No | No (`trust: "untrusted"`) |
| Agent sandbox (BYOA / MCP) | Yes, encouraged | Read-only via egress proxy | No | No (`trust: "untrusted"`) |
| Smithers-controlled sandbox / maintainer gate | Yes | Read-write (`SMITHERS_CACHE_WRITE_TOKEN`) | Yes | Yes (`trust: "trusted"`) |

Untrusted contributors get the full speed benefit of warm cache hits without any ability to poison cache entries or bypass merge and release gates.

## Authenticated Cloud MCP and one-time-use sandbox auth

Agents interact with `zmux` through the authenticated Streamable HTTP MCP endpoint at `https://smithers.sh/smithersai/zmux/mcp` (OAuth 2.1 + PKCE S256, `sma_` scoped tokens, attributed as `<login> (agent)`):

```sh
claude mcp add zmux --transport http https://smithers.sh/smithersai/zmux/mcp
codex mcp add zmux --url https://smithers.sh/smithersai/zmux/mcp
agy mcp add zmux --transport http https://smithers.sh/smithersai/zmux/mcp
```

To print a fresh one-time-use PKCE challenge and read-only sandbox environment without exposing maintainer secrets, run:

```sh
node .smithers/scripts/mint-sandbox-auth.mjs
```

Person-only actions (`pull/merge`, `issue/triage`, `issue/commitment`, `todo/commit`, `secrets/write`) remain permanently blocked on every MCP agent token.
