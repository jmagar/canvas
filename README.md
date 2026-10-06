# Canvas

A Phoenix LiveView spike for a spatial, project-scoped Codex workspace. Ideas, issues, tasks, pull requests, source material, and agent runs live on one canvas.

## Run

```sh
mise install
mise exec -- mix setup
PORT=4077 mise exec -- mix phx.server
```

Open http://localhost:4077. Install and authenticate the official Codex CLI first (`codex login`). The app uses `codex app-server --stdio`; it does not use the desktop app's private internal APIs.

## Current direction

[ADR 0001](docs/adr/0001-foundation-before-axon-and-cortex.md) defers Axon and Cortex until the canvas foundation is validated. Ingestion stays agentic: local preservation and previews feed a Codex reference analyst without an embedding prerequisite. Existing Axon/Cortex integration is deferred; automatic analysis requires an isolated runner.

## What works

- Drag, pan, zoom, search, and filter canvas cards; persist positions and relationships.
- Describe each project and attach a repository, links, files, images, documents, or an explicitly selected Codex session.
- Chat with a dedicated, persisted Codex thread. Stream assistant text and activity; steer or interrupt a running turn. Normal chats use read-only filesystem access and never approve server requests.
- Dispatch linked agent cards through a configured VM runner. Missing VM configuration blocks dispatch visibly.
- Automatically preserve added sources locally and create a `REFERENCE.md` catalog scaffold. External acquisition and telemetry are deferred.
- With an isolated runner configured, dispatch a context analyst directly with a structured output schema. Save summaries, relevance, reference guidance, limitations, and relationship suggestions with thread provenance. Accept suggestions to connect sources on the graph.
- Classify context with Jev or CLEF, retaining model identity, confidence, answer distributions, taxonomy version, and review flags.

## Configure integrations

Set variables in your shell before starting Phoenix. `.env.example` documents the names; dotenv files are not loaded automatically. Secrets remain server-side.

| Integration | Configuration | Behavior |
| --- | --- | --- |
| Codex | `CANVAS_CODEX_BINARY` (default `codex`) | Per-item JSON-RPC app-server process and persisted thread ID |
| Axon | `CANVAS_AXON_URL`, optional `CANVAS_AXON_TOKEN` | Canonical `/v1/sources` and upload API; requires terminal completion and positive vector counts |
| Jev | `CANVAS_DECISION_PROVIDER=jev`, `TYPESAFE_API_KEY` | Typesafe System One API, default `jev-latest` |
| CLEF | `CANVAS_DECISION_PROVIDER=clef`, `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_AUTH_TOKEN` | Workers AI CLEF decision API |
| Depot | `CANVAS_LABBY_MCP_URL`, optional `CANVAS_LABBY_TOKEN` | Streamable HTTP MCP `codemode` capability search, bounded to eight results; incomplete coverage remains visible |
| Isolated agents | `CANVAS_VM_RUNNER` | Executable transport contract described below |
| Storage | `CANVAS_DATA_DIR` | Default `data/`, excluded from Git |

Codex selects the default returned by `model/list`; `CANVAS_CODEX_MODEL` can override it without changing your global CLI settings.

Optional `CANVAS_DECISION_MODEL` overrides the decision model. Classification does not replace agent synthesis: decision models provide typed answers, while Codex writes reference explanations.

### Microsandbox runner contract

`CANVAS_VM_RUNNER` must point to an executable that accepts `app-server --stdio`, provisions or selects a dedicated Microsandbox hardware-isolated VM, and transports JSON-RPC stdin/stdout to Codex inside that guest. Keep stdout exclusively for protocol messages. The runner must arrange guest Codex authentication and make the supplied workspace/context paths available inside the guest. The spike does **not** provision VMs itself, copy files into guests, manage guest secrets, or verify guest isolation. There is no fallback to host execution for dispatched agents. Agent app-server sessions currently use read-only policy too; writable coding execution needs a deliberate next implementation step.

### Ingestion flow

`attach → preserve locally → safe preview/context manifest → isolated Codex analyst → validated reference notes → suggested graph links`

Embeddings are not required. Without an isolated runner, sources and previews remain usable while analysis is visibly awaiting the runner. Analysts must report unavailable content rather than invent it; relationship suggestions must name existing sources. Axon acquisition/embedding code remains experimental and disabled in automatic processing under ADR 0001. Cortex is deferred. Queued work is held in memory; after restart, use **Refresh catalog** for unfinished sources.

## Spike boundaries

This is a single-user local app without authentication. Keep it on loopback; development and production HTTP bindings default to loopback. Do not expose it publicly without authentication, authorization, request controls, and audited sandbox provisioning.

Storage is an atomically replaced JSON file, not a multi-user database. Source context is bounded (30 attachments, excerpts, eight local images); classification currently handles text and flags binary extraction requirements. Imported sessions are user-selected; there is no automatic crawl of private logs. Cortex telemetry ingestion is a planned adapter: current activity comes from app-server notifications. Depot suggestions do not install skills or grant MCP permissions. Credentials, repository files, logs, and `data/` are not published with this repository.

## Architecture and validation

See [architecture](docs/architecture.md). Run:

```sh
mise exec -- mix precommit
mise exec -- mix assets.build
```

Tests cover LiveView editing/uploads/context isolation, durable state, app-server protocol handling and resume, blocked dispatch, ingestion receipts, reference validation, decision-model response validation, and incomplete Depot discovery. The protocol test uses an executable fixture; live-service checks are separate from these tests.

API references: [Codex app-server](https://developers.openai.com/codex/app-server), [Typesafe quickstart](https://docs.typesafe.ai/introduction/quickstart), [CLEF model](https://developers.cloudflare.com/workers-ai/models/clef/), [CLEF decision models](https://blog.cloudflare.com/clef-decision-models/).
