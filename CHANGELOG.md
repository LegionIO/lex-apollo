# Changelog

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
