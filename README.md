# lex-apollo

Shared durable knowledge store for the GAIA cognitive mesh. Agents publish confirmed knowledge via RabbitMQ; a dedicated Apollo service persists to PostgreSQL+pgvector. Supports semantic search, concept graph traversal, and expertise tracking.

## Overview

`lex-apollo` operates in two modes:

- **Client mode**: Any agent loads this gem and calls runners. Runners publish to RabbitMQ — no direct database access required.
- **Service mode**: A dedicated Apollo process runs the actors, subscribes to queues, generates embeddings, and writes to PostgreSQL+pgvector.

The backing store is Azure Database for PostgreSQL Flexible Server with the pgvector extension.

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
# Force confidence decay cycle (factor multiplied against each entry's confidence)
client.force_decay(factor: 0.5)

# Archive entries older than N days
client.archive_stale(days: 90)

# Resolve a corroboration dispute
client.resolve_dispute(entry_id: 'entry-uuid', resolution: :accept)
```

## Architecture

### Client Mode

Runners build structured payloads and publish to the `legion.apollo` exchange via RabbitMQ. No PostgreSQL or pgvector dependency is needed in the calling agent. Transport requires `Legion::Transport` to be loaded.

Startup explicitly binds the ingest, query, writeback-store, and writeback-vectorize queues to `legion.apollo`, using each queue's name as its routing key. The `legion.apollo.gas` queue binds separately to `llm.audit` with routing key `llm.audit.complete`. Repeated startup preserves these bindings.

Automatic writeback checks research tool calls in `Legion::LLM::Inference::Response#tools`, accepting typed tools and symbol/string-keyed hashes. Existing response `tool_calls` and enrichment-based tool history remain supported. Responses must meet the configured minimum content length; Apollo context alone does not qualify a response for capture.

### Service Mode

Five actors run in the dedicated Apollo service process:

| Actor | Type | Interval | Purpose |
|---|---|---|---|
| `Ingest` | Subscription | on-message | Receive knowledge, generate embeddings, persist to PostgreSQL |
| `QueryResponder` | Subscription | on-message | Handle semantic queries, return results via RPC |
| `Decay` | Interval | 3600s | Confidence decay cycle across all entries |
| `ExpertiseAggregator` | Interval | 1800s | Recalculate domain proficiency scores |
| `CorroborationChecker` | Interval | 900s | Scan pending entries for auto-confirm threshold |

### GAIA Tick Integration

Apollo is wired into the GAIA tick cycle at the `knowledge_retrieval` phase (phase 4), which fires after `memory_retrieval` and before `working_memory_integration`. It activates only when local memory lacks high-confidence matches for the current tick context.

## Confidence Model

Entries have a confidence score between 0.0 and 1.0:

- New entries start at `INITIAL_CONFIDENCE` (0.5) with status `candidate`
- Eligible semantically similar evidence (cosine >= 0.9) boosts confidence by up to 0.3; the periodic corroboration checker promotes candidates supported by independent evidence to `confirmed`.
- Corroboration stays within the same knowledge domain, content type, and access scope, and only uses `candidate` or `confirmed` evidence. Private evidence requires the same resolved owner; team evidence requires shared identity-group membership. Unresolved private/team ownership does not corroborate.
- Each retrieval adds a small boost (+0.02, capped at 1.0)
- Confidence decays hourly by factor 0.998; entries below 0.1 are archived
- The GAIA write gate (`meets_write_gate?`) requires confidence > 0.6 and novelty > 0.3 for the tick write-back path

See `helpers/confidence.rb` for all constants and math helpers.

## Requirements

### Client mode
- Ruby >= 3.4
- RabbitMQ (via `legion-transport`)

### Service mode
- PostgreSQL with pgvector extension
- RabbitMQ
- `legion-data` for database connection management

## Development

```bash
bundle install
bundle exec rspec
bundle exec rubocop
```

## License

MIT
