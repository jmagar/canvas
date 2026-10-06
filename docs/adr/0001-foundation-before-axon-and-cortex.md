# ADR 0001: Build the canvas foundation before integrating Axon and Cortex

- Status: Accepted
- Date: 2026-10-05
- Decision owner: Project owner

## Context

Canvas is exploring a spatial workspace for ideas, issues, tasks, pull requests, sources, and agent conversations. The initial spike added Axon acquisition/embedding adapters and anticipated Cortex logs and metrics. Integrating these services now would make it harder to evaluate the interaction model independently of crawling, indexing, telemetry, infrastructure, and credentials.

The owner requested project islands, agent trails, document previews, and labeled dots, with optional navigation and floating project windows. These are the current foundation.

## Decision

Defer Axon and Cortex integration until the foundation is implemented and validated. Added files and links stay local by default. Local source metadata, safe previews, reference catalog scaffolds, explicit relationships, persisted project context, and Codex app-server conversations remain in scope.

Retain ingestion as an agentic workflow: preserve source → prepare bounded context/preview → Codex analyst → validated reference entry → suggested graph relationships. The analyst explains what a source is, where to reference it, why it matters, when to use it, and how it connects to known context. It works from explicit source material and the project manifest; a vector index, embedding job, or retrieval-augmented generation pipeline is not a prerequisite.

The local pipeline can dispatch the analyst directly through the isolated runner. If the runner is unavailable, sources and previews remain usable and analysis is explicitly awaiting the runner. Automated link fetching and binary extraction still need bounded acquisition/extraction implementations; a URL alone is not treated as read content.

Do not automatically crawl, embed, fetch Cortex session logs, or require these services to use the canvas. Retain existing adapters as isolated experimental code; endpoint or token configuration alone does not activate automatic external ingestion. The current ingestion coordinator defaults to local catalog handling. Re-enabling external ingestion requires a deliberate follow-up implementation and review of this decision.

Use actual app-server notifications for agent status/activity. Trails reflect observed states, not invented completion percentages or fabricated work. VM dispatch remains explicit and requires an isolated runner.

## Foundation milestones

1. Validate project islands, labeled source dots, document/image previews, and agent trails with representative local context.
2. Make selecting, moving, connecting, searching, and steering work without a persistent sidebar.
3. Preserve project context, conversation history, relationships, and observable task states across reconnects/restarts.
4. Define the stable source, reference, relationship, and agent-event contracts that adapters will consume.

## Consequences

The core app can be developed and tested independently of Axon and Cortex. Links are references rather than automatically downloaded content. Binary document extraction, semantic retrieval, embedding-based relationship retrieval and cross-session telemetry are deferred. Agent-proposed relationships from available context remain in scope. Existing adapter tests establish response handling only; they do not demonstrate integration readiness.

## Revisit

Revisit when the foundation milestones are validated. Integrate Axon and Cortex separately against the stable contracts, with explicit source provenance, job lifecycle, context scoping, and observable failures. Update or supersede this ADR before enabling default external workflows.
