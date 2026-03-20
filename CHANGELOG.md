# Changelog

## [0.3.2] - 2026-03-20

### Changed
- Replace exponential confidence decay (`confidence * 0.998`) with power-law decay
  (`confidence / (1 + alpha)` per tick, where `alpha` defaults to 0.1)
- Configurable via `apollo.power_law_alpha` setting (default: 0.1)
- Source diversity enforcement in corroboration: same-source corroboration (matching
  `source_provider`) receives 50% boost weight instead of full weight
- `check_corroboration` skips auto-promotion when both candidate and match have
  the same known `source_provider` (correlated error prevention)
- `apply_corroboration_boost` accepts optional `weight:` kwarg (default: 1.0)

### Added
- `source_provider` field populated on ingest via explicit kwarg or agent name inference
- `handle_ingest` accepts `source_provider:` kwarg; derives provider from agent name
  convention when not explicitly provided

## [0.3.1] - 2026-03-17

### Added
- `Apollo::Transport` module now extends `Legion::Extensions::Transport` to provide the `build` method expected by LegionIO's `build_transport` call

## [0.3.0] - 2026-03-17

### Added
- Contradiction detection: LLM-based conflict analysis during knowledge ingest via structured output
- `detect_contradictions`: finds similar entries and checks for semantic conflicts, creates `contradicts` relations
- `run_decay_cycle`: hourly confidence reduction with configurable rate (0.998 default) and archival threshold (0.1)
- `GaiaIntegration.publish_insight`: auto-publish high-confidence insights from cognitive reflection phase
- `GaiaIntegration.handle_mesh_departure`: knowledge vulnerability detection when agents leave the mesh

## [0.2.0] - 2026-03-16

### Added
- `Helpers::Embedding` — embedding generation wrapper with legion-llm + zero-vector fallback
- `Knowledge.handle_ingest` — server-side ingest: embedding, corroboration check, entry creation, expertise upsert
- `Knowledge.handle_query` — server-side query: semantic search via pgvector, retrieval boost, access logging
- `Knowledge.retrieve_relevant` — GAIA tick phase handler for knowledge_retrieval (phase 4)
- `Maintenance.check_corroboration` — periodic scan promoting candidates to confirmed via similarity threshold
- `Expertise.aggregate` — periodic proficiency recalculation using log2-weighted average confidence

## [0.1.0] - 2026-03-15

### Added
- Initial scaffold with helpers, runners, actors, transport, and standalone client
- Confidence helper with decay, boost, and write gate logic
- Similarity helper with cosine distance and corroboration classification
- Graph query builder for recursive CTE traversal and pgvector semantic search
- Knowledge, Expertise, and Maintenance runners (client-side RMQ payloads)
- Ingest, QueryResponder, Decay, ExpertiseAggregator, CorroborationChecker actors
- Transport layer: apollo exchange, ingest/query queues, ingest/query messages
- Standalone Client with agent_id injection
- GAIA tick integration: knowledge_retrieval phase (phase 4)
- legion-data migration 012 with PostgreSQL+pgvector tables (guarded)
