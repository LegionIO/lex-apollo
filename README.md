# lex-apollo

Shared durable knowledge store for the GAIA cognitive mesh. Agents publish confirmed knowledge via RabbitMQ; a dedicated Apollo service persists to PostgreSQL+pgvector or SQLite. Supports semantic search, concept graph traversal, and expertise tracking.

## Overview

`lex-apollo` operates in two modes:

- **Client mode**: Any agent loads this gem and calls runners. Runners publish to RabbitMQ — no direct database access required.
- **Service mode**: A dedicated Apollo process runs the actors, subscribes to queues, generates embeddings, and writes to PostgreSQL+pgvector or SQLite.

PostgreSQL uses native vector distance; SQLite stores JSON vectors and computes exact similarity over eligible rows, keeping bounded top-k results without limiting the candidate set before ranking. Both backends enforce the same ownership, filter, provenance, and traversal boundaries.

## Installation

Add to your Gemfile:

```ruby
gem 'lex-apollo'
```

## Usage

### Standalone Client

```ruby
require 'legion/extensions/apollo'

client = Legion::Extensions::Apollo::Client.new

# Build a store payload (published to RabbitMQ for the Apollo service to persist)
client.store_knowledge(
  content:      'BGP route reflectors reduce full-mesh IBGP complexity',
  content_type: :fact,
  source_agent: 'my-agent-001',
  tags:         ['bgp', 'routing', 'ibgp'],
  context:      { source: 'network_team_wiki' }
)

# Build a query payload
client.query_knowledge(
  query:          'BGP route reflector configuration',
  min_confidence: 0.6,
  limit:          10
)

# Get related entries (concept graph traversal)
client.related_entries(entry_id: 'entry-uuid', depth: 2)

# Deprecate a stale entry
client.deprecate_entry(entry_id: 'entry-uuid', reason: 'superseded by RFC 7938')
```

Content types: `:fact`, `:concept`, `:procedure`, `:association`, `:observation`

### Expertise Queries

```ruby
# Get proficiency scores for a domain
client.get_expertise(domain: 'networking', min_proficiency: 0.3)

# Find domains where coverage is thin (below min agent count)
client.domains_at_risk(min_agents: 2)

# Full agent knowledge profile
client.agent_profile(agent_id: 'my-agent-001')
```

### Maintenance

```ruby
# Multiply each non-archived entry's confidence by the supplied factor
client.force_decay(factor: 0.5)

# Archive non-archived entries untouched for N days
client.archive_stale(days: 90)

# Resolve a corroboration dispute
client.resolve_dispute(entry_id: 'entry-uuid', resolution: :accept)
```

With a loaded Entry model, these methods execute against the service database and return persisted outcomes. Without local data, Ruby callers retain the existing action envelopes; these envelopes do not claim a successful mutation.

- `deprecate_entry` archives the entry and preserves its other source metadata, storing the supplied reason as `source_context.deprecation_reason`. An identical repeat is a no-op.
- `force_decay` accepts a finite factor from 0 through 1 and changes confidence only; it does not implicitly archive entries.
- `archive_stale` accepts nonnegative days and uses `COALESCE(updated_at, created_at)` to determine staleness.
- `resolve_dispute` accepts `:accept` or `:keep` to confirm a disputed entry, or `:reject` to archive it. It records `source_context.dispute_resolution`, sets `confirmed_at` when confirming, and preserves confidence. Unknown resolutions and non-disputed entries fail without mutation.

The standalone deprecation endpoint returns HTTP 200 after success, 404 for a missing entry, 503 when local data is unavailable, and 500 when persistence fails. Lifecycle status and metadata changes commit together.

## Architecture

### Client Mode

Runners build structured payloads and publish to the `legion.apollo` exchange via RabbitMQ. No PostgreSQL or pgvector dependency is needed in the calling agent. Transport requires `Legion::Transport` to be loaded.

Startup explicitly binds the ingest, query, writeback-store, and writeback-vectorize queues to `legion.apollo`, using each queue's name as its routing key. The `legion.apollo.gas` queue binds separately to `llm.audit` with routing key `llm.audit.complete`. Repeated startup preserves these bindings.

Automatic writeback checks research tool calls in `Legion::LLM::Inference::Response#tools`, accepting typed tools and symbol/string-keyed hashes. Existing response `tool_calls` and enrichment-based tool history remain supported. Responses must meet the configured minimum content length; Apollo context alone does not qualify a response for capture.

### Service Request Contract

The canonical exchange is `legion.apollo`, routing key `legion.apollo.query`. Requests use `action: "query"`, `"retrieve"`, or `"traverse"`; query text is the `query` field. Omitted action defaults to `query`. `Runners::Request.query` and `.retrieve` accept Ruby `text:` and translate it to the wire field. This release does not bridge the core client's older `apollo` exchange or `text` payload.

RabbitMQ callers supply `reply_to` and `correlation_id` as AMQP properties (body fields are accepted when properties are absent). Replies contain the actual Knowledge result, use the default exchange and supplied queue, and retain correlation. Unsupported actions and invalid request fields receive structured errors. Reply publication uses mandatory routing and publisher confirms; failure reaches subscription retry handling, preserving reply metadata. Requests without `reply_to` remain fire-and-forget; `Request` returns dispatch status, not a synchronous remote result.

Search/retrieval accept `status`, `tags`, `domain`, `min_confidence`, `exclude_source_agents`, and `tag_match`. The default `tag_match: :any` means tag overlap. Use `tag_match: :all` with both `llm_conversation_history` and the conversation-specific tag to isolate one conversation. Filtering also applies to chronological browse fallback. Search uses embedding task `:query`; ingestion uses `:document`.

### Ownership Boundaries

HTTP reads and deprecation derive the database principal from authenticated `legion.auth` / `legion.principal` middleware state. JSON identity fields are not trusted. Anonymous or unmapped callers see only global entries; private/team ingestion requires a resolved owner. Authentication middleware must populate those environment values before mounting this standalone API. Statistics retain their existing global aggregate behavior.

Broker producers are trusted to supply database principal IDs. Missing or null request principals mean global-only visibility, and missing ingestion ownership stays null rather than becoming the receiving service's identity. Producer scope, identity, provenance, context, and supplied embeddings survive ingestion and writeback-store decoding. Direct internal Knowledge calls retain their existing nil-principal/process-identity semantics.

Traversal checks the seed and every hop: inaccessible and archived nodes cannot bridge into visible results. Mesh export includes only global confirmed entries. Migration 139 scopes active content-hash uniqueness to access scope and private/team owner; identical content may belong to different owners without rewriting its hash. Global entries share one global hash boundary. Archived copies are excluded from uniqueness.

### Embedding Compatibility and Migration

Deploy `legion-data >= 1.10.29` and `legion-llm >= 0.16.10`, then apply data migration 139 before starting this service version. Existing active/archive content, hashes, IDs, owners, and vectors are preserved. SQLite gains JSON-text vectors/provenance; PostgreSQL vectors become unconstrained in dimension. Legacy model provenance is deliberately left unknown, not inferred from the old column size. The migration is irreversible because restoring global uniqueness or one fixed dimension could destroy valid data.

Every usable vector carries `embedding_provenance`: routed provider/model, authoritative revision (or exact instance when no revision is known), actual dimensions, document/query prefix pair, normalization, task, and stable `space_id`. Search uses query vectors; stored vectors must be document vectors. Only compatible profiles participate in similarity, corroboration, or contradiction checks, even when two unrelated models return the same dimension. Invalid, zero, or unknown-profile vectors cannot silently enter comparisons.

`legion-llm` owns embedding routing; Apollo has no independent default model/provider. Supplied document vectors are reused only with valid provenance. Unknown legacy/precomputed vectors regenerate through the real router before successful ingestion. Source model/provider metadata remains separate from embedding provenance.

Backfill legacy rows in bounded batches:

```ruby
maintenance = Object.new.extend(Legion::Extensions::Apollo::Runners::Maintenance)
result = maintenance.reembed_entries(limit: 100, after_id: nil)
# Continue from result[:next_after_id]; inspect result[:failures] for retries.
```

The default selects active rows with unknown space IDs. To migrate a known space after a model, dimension, prefix, or revision change, pass `legacy_only: false, from_space_id: old_space_id` and optionally constrain the target with `provider:`, `model:`, `instance:`, and `dimensions:`. Each batch generates real embeddings and updates only vector/provenance fields; concurrent content changes are skipped. IDs, content, hashes, ownership, status, and timestamps remain unchanged. Queries in the new space exclude incompatible old rows until migration reaches them.

PostgreSQL migration removes incompatible direct-column ANN indexes but preserves dimension-constrained expression indexes and unrelated indexes. Native exact search remains available; large installations should plan compatible per-space/dimension indexes separately.

### Writeback Delivery

`WritebackVectorize` dispatches to the callable Writeback runner. Generation errors, explicit ingest failures, and failed broker publications raise into subscription retry handling. Forwarding strips the inbound exchange/routing key so generated vectors reach `legion.apollo.writeback.store`, not the vectorizer again. Producer ownership (including explicit null), context, source metadata, and embedding provenance survive delivery. Mandatory routing and bounded publisher confirms establish broker acceptance, not synchronous remote persistence.

Core-client legacy wire migration and synchronous retrieval deadlines/fan-out remain outside this server release.

### Service Mode

Service actors include:

| Actor | Type | Interval | Purpose |
|---|---|---|---|
| `Ingest` | Subscription | on-message | Receive knowledge, generate embeddings, persist to the configured backend |
| `QueryResponder` | Subscription | on-message | Handle semantic queries, return results via RPC |
| `Decay` | Interval | 3600s | Confidence decay cycle across all entries |
| `ExpertiseAggregator` | Interval | 1800s | Recalculate domain proficiency scores |
| `CorroborationChecker` | Interval | 900s | Scan pending entries for auto-confirm threshold |
| `GasSubscriber` | Subscription | on-message | Process `llm.audit.complete` events and persist accepted GAS outputs |
| `WritebackVectorize` | Subscription | on-message | Generate compatible document vectors and ingest or forward with retryable failures |
| `WritebackStore` | Subscription | on-message | Persist producer-owned writeback payloads |

### Atomic Ingestion

After text embedding is complete, an ingest commits its Entry change (including a corroboration boost), expertise bookkeeping, and ingest access log in one database transaction. Contradiction scanning is queued only after that transaction commits. Failed entry, expertise, access-log, or corroboration-side-effect writes leave no partial row, confidence boost, or queued contradiction work.

Content-hash uniqueness conflicts use a nested savepoint. If another transaction committed a winner in the same scope and owner boundary, Apollo records against that winner; if no permitted winner can be read after rollback, the ingest fails rather than reporting a nil, foreign, or partial success.

Apollo preflights Entry, Expertise, and AccessLog before ingestion writes anything; a missing required model rejects the request without a partial entry. Semantic queries require AccessLog before embedding, lookup, or confidence boosts so reads remain auditable. Traversal requires it only when a non-`unknown` agent causes an audit write. Relation remains optional for statistics, but corroboration does not promote a candidate unless it can persist the matching relation.

### GAS Persistence

GAS deposits facts and synthesis through normal Knowledge ingestion. New synthesis entries remain candidates and record their original source indices plus successfully stored source entry IDs in `source_context`; existing deduplicated entries retain their metadata.

The `process` result's top-level counts describe generated phase outputs. Its `deposited` object reports storage outcomes:

- `deposited`, `facts`, and `synthesis` count successful ingest results with entry IDs, including deduplication—not just newly inserted rows.
- `failed` counts rejected or failed entry writes.
- `relations`, `relations_failed`, and `relations_skipped` distinguish persisted edges, failed writes or missing endpoints, and intentionally skipped edges.

Relations must meet the configured confidence gate, use a supported type, and connect an unambiguous successful fact deposit to an existing target in the same access scope. Self-links and duplicate edges within the batch are skipped. Independent relation failures do not discard successful entry deposits or prevent later edges from being processed. Existing GAS types `supports_by` and `extends` are also accepted by graph traversal.

Relation deduplication is batch-local; repeated audit events are not an exactly-once delivery contract.

### GAIA Tick Integration

Apollo is wired into the GAIA tick cycle at the `knowledge_retrieval` phase (phase 4), which fires after `memory_retrieval` and before `working_memory_integration`. It activates only when local memory lacks high-confidence matches for the current tick context.

## Confidence Model

Entries have a confidence score between 0.0 and 1.0:

- New entries start at `INITIAL_CONFIDENCE` (0.5) with status `candidate`
- Ingestion corroborates confirmed evidence. The bounded periodic checker can bootstrap one confirmation from a pair of independently sourced candidates; it marks that confirmation as bootstrap-derived so its paired candidate does not confirm solely by seeing the new status on a later scan.
- Corroboration stays within the same knowledge domain, content type, and access scope. Equal known providers and equal source channels are not independent. Private evidence requires the same resolved owner; team evidence requires shared identity-group membership. Unresolved private/team ownership does not corroborate.
- Each retrieval adds a small boost (+0.02, capped at 1.0)
- Confidence decays hourly by factor 0.998; entries below 0.1 are archived
- The GAIA write gate (`meets_write_gate?`) requires confidence > 0.6 and novelty > 0.3 for the tick write-back path

See `helpers/confidence.rb` for all constants and math helpers.

## Requirements

### Client mode
- Ruby >= 3.4
- RabbitMQ (via `legion-transport >= 1.4.31`)

### Service mode
- PostgreSQL with pgvector (including `vector_norm`) or SQLite with JSON and window-function support
- RabbitMQ
- `legion-data >= 1.10.29`, with migration 139 applied
- `legion-llm >= 0.16.10`, with an available routed embedding provider

## Development

```bash
bundle install
bundle exec rspec
bundle exec rubocop
```

## License

MIT
