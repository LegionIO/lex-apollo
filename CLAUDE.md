# lex-apollo: Shared Knowledge Store

**Parent**: `/Users/miverso2/rubymine/legion/extensions-agentic/CLAUDE.md`
**Cognitive Concept**: Apollo (all human knowledge)
**Version**: 0.1.0

## What This Does

Shared durable knowledge store for the GAIA cognitive mesh. Agents write confirmed knowledge to Apollo via RabbitMQ; a dedicated Apollo service persists to PostgreSQL+pgvector. Supports semantic search (vector similarity), concept graph traversal, and expertise tracking.

## Architecture

- **Client mode**: Runners publish to RMQ, no direct DB. Any agent can use this.
- **Service mode**: Actors subscribe to RMQ, write to PostgreSQL+pgvector. Dedicated process.
- **Backing store**: Azure Database for PostgreSQL Flexible Server + pgvector extension.

## Key Files

| File | Purpose |
|---|---|
| `helpers/confidence.rb` | Constants, decay math, boost logic, write gates |
| `helpers/similarity.rb` | Cosine similarity, corroboration threshold, match classification |
| `helpers/graph_query.rb` | SQL builders for recursive CTE traversal and vector search |
| `runners/knowledge.rb` | store_knowledge, query_knowledge, related_entries, deprecate_entry |
| `runners/expertise.rb` | get_expertise, domains_at_risk, agent_profile |
| `runners/maintenance.rb` | force_decay, archive_stale, resolve_dispute |
| `actors/ingest.rb` | Subscription: receives knowledge, generates embeddings, persists |
| `actors/query_responder.rb` | Subscription: handles queries, returns results via RPC |
| `actors/decay.rb` | Interval (hourly): confidence decay cycle |
| `actors/expertise_aggregator.rb` | Interval (30min): recalculate proficiency scores |
| `actors/corroboration_checker.rb` | Interval (15min): scan candidates for auto-confirm |
| `client.rb` | Standalone client with all runners included |

## GAIA Tick Phase

`knowledge_retrieval` — phase 4 (after memory_retrieval, before working_memory_integration).
Fires only when local memory lacks high-confidence matches.

## Design Doc

`docs/plans/2026-03-15-apollo-shared-knowledge-design.md`
