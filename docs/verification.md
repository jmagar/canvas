# Spike verification

Local verification on 2026-10-05:

- `mix precommit`: 19 tests passed (including executable JSON-RPC fixture and advertised-model selection).
- `mix assets.build`: passed.
- Browser: created and saved a project; its description appeared on the canvas.
- Real installed Codex app-server: created a thread, surfaced an unsupported configured-model error, then resumed the same persisted thread after Phoenix restart using the advertised default model. The turn completed with the correct project title and goal from scoped context.
- Staged repository secret scan: no findings after replacing generated dev/test keys with obvious local-only placeholders.

Axon, Jev/CLEF, VM isolation/provisioning, and Cortex were not live-qualified. Depot discovery was attempted through the available gateway; its team endpoint was unreachable. Adapter unit validation is separate from these live-service gaps.
