# Changelog

## [0.4.2] - 2026-03-24

### Fixed
- fix `undefined method 'scan_and_ingest' for module EntityExtractor` in EntityWatchdog actor — self-contained actors must override `runner_class` to return `self.class` so the framework dispatches to the actor instance, not the runner module

## [0.4.1] - 2026-03-23

### Changed
- route llm calls through pipeline when available, add caller identity for attribution

## [0.4.0] - 2026-03-23

### Added
- `Runners::Gas`: 6-phase GAS (Generation-Augmented Storage) pipeline
  - Phase 1 (Comprehend): LLM-based fact extraction via GaiaCaller, mechanical fallback
  - Phase 2 (Extract): delegates to existing `EntityExtractor` runner
  - Phase 3 (Relate): queries Apollo for similar entries, classifies 8 relationship types via LLM, confidence > 0.7 gate
  - Phase 4 (Synthesize): generates derivative knowledge with geometric mean confidence, capped at 0.7
  - Phase 5 (Deposit): atomic write of facts to Apollo via `Knowledge.handle_ingest`
  - Phase 6 (Anticipate): generates follow-up questions, promotes to TBI PatternStore when available
- `Actor::GasSubscriber`: subscription actor binding to `llm.audit.complete` routing key
- `Transport::Queues::Gas`: durable queue for GAS audit event processing

## [0.3.9] - 2026-03-23

### Fixed
- Guard `log.info` call in `redistribute_knowledge` with `Legion::Logging` check to prevent `NoMethodError` when `Helpers::Lex` is not loaded

## [0.3.8] - 2026-03-23

### Changed
- `Helpers::Embedding.generate` now accepts any non-empty embedding vector and auto-detects dimension
- Added `dimension` and `zero_vector` module methods for dynamic dimension support
- Removed hardcoded 1536-dimension requirement (supports any embedding model dimension)

## [0.3.7] - 2026-03-22

### Changed
- Add legion-cache, legion-crypt, legion-data, legion-json, legion-logging, legion-settings, and legion-transport as runtime dependencies
- Replace direct Legion::Logging calls with injected log helper in runners and actors
- Update spec_helper with real sub-gem helper stubs (Legion::Logging stub removed)

## [0.3.6] - 2026-03-21

### Added
- Time-aware power-law decay in batch cycle (alpha=0.5 per Murre & Dros 2015)
- Source channel diversity enforcement in corroboration paths
- Right-to-erasure propagation via handle_erasure_request
- Knowledge domain namespaces with query filtering
- Domain-aware mesh propagation filtering (prepare_mesh_export)

### Changed
- POWER_LAW_ALPHA updated from 0.1 to 0.5
- run_decay_cycle uses time-aware SQL instead of flat multiplier

## [0.3.4] - 2026-03-20

### Added
- `Helpers::EntityWatchdog`: regex-based entity detection for persons, services, repos, and configurable concepts
- GAIA `post_tick_reflection` handler for passive entity detection (enabled via `apollo.entity_watchdog.enabled`)
- Deduplication by type+value, configurable type filtering, and `link_or_create` for Apollo integration

## [0.3.3] - 2026-03-20

### Added
- `Runners::EntityExtractor`: LLM-backed structured extraction of people, services, repositories, and concepts from arbitrary text
- `Actors::EntityWatchdog`: interval actor (120s) that reads recent task logs, extracts entities, deduplicates against Apollo, and publishes ingest messages for net-new entities
- Settings support: `apollo.entity_watchdog.types`, `apollo.entity_watchdog.min_confidence`, `apollo.entity_watchdog.dedup_threshold`
- Fallback behavior when `Legion::LLM` is unavailable (returns empty entity list, no error)

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
