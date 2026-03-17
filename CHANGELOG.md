# Changelog

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
