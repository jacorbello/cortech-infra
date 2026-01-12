# ADR 001: Jarvis Architecture

**Status**: Accepted
**Date**: 2026-01-09
**Deciders**: Infrastructure team

## Context

We want to deploy a LAN-only AI assistant ("Jarvis") with:
- Web-based chat interface
- Multi-user support
- Autonomous agent capabilities (web browsing, tool execution)
- Safe, allowlisted local actions
- Document ingestion and retrieval (RAG)
- Optional WhatsApp integration

## Decision

### Deployment Model: LXC + Docker Compose

**Chosen**: Single LXC container (PCT 121) running Docker Compose stack

**Alternatives considered**:
1. **Kubernetes (k3s)** - More complex, better orchestration, but overkill for single application stack
2. **Multiple LXCs** - One per service, matches existing pattern but harder to manage as a unit
3. **Direct VM** - More isolation but heavier resource usage

**Rationale**:
- Matches existing LXC service pattern
- Docker Compose provides service orchestration within container
- Simpler to backup/restore as single unit
- Can migrate to K8s later if needed
- Reuses existing postgres/redis infrastructure

### Frontend: LibreChat

**Chosen**: LibreChat as user-facing interface

**Alternatives considered**:
1. **AGiXT UI only** - Simpler but weak multi-user support
2. **Dify** - Good all-in-one but less flexible for custom agents
3. **Custom UI** - Maximum flexibility but significant development effort

**Rationale**:
- Strong multi-user support (auth, sessions, history)
- MCP integration for tool connectivity
- Active development and community
- Clean separation from agent execution

### Agent Engine: AGiXT

**Chosen**: AGiXT as backend agent executor

**Alternatives considered**:
1. **LangChain/LangGraph** - Popular but requires more custom code
2. **AutoGPT** - Less mature plugin system
3. **Custom agent** - Maximum control but significant effort

**Rationale**:
- Mature extension/plugin system
- Supports multiple LLM providers
- Web browsing built-in
- Can disable dangerous extensions
- Designed for autonomous operation

### Integration Pattern: Custom Endpoint

**Chosen**: AGiXT as custom endpoint in LibreChat (Pattern 2 from blueprint)

**Alternatives considered**:
1. **MCP Server** - Tighter integration but AGiXT loses control of agent loop

**Rationale**:
- AGiXT maintains full control of agent execution
- LibreChat handles user experience
- Cleaner separation of concerns
- Easier to debug and monitor

### Database: Existing Postgres (PCT 114)

**Chosen**: Add pgvector to existing postgres instance

**Alternatives considered**:
1. **New Qdrant container** - Purpose-built for vectors but another service to manage
2. **New postgres in Docker** - Isolated but duplicates existing infrastructure
3. **SQLite + FAISS** - Simpler but less scalable

**Rationale**:
- Postgres already running and maintained
- pgvector is production-ready
- Single database for both app data and vectors
- Reduces operational complexity

### Safety Model: Tools Gateway

**Chosen**: Dedicated HTTP service with allowlisted actions only

**Alternatives considered**:
1. **AGiXT native extensions** - Simpler but less control
2. **No local actions** - Safest but limits usefulness

**Rationale**:
- Clear security boundary
- Strict input validation
- Audit logging
- Can add actions incrementally
- Independent of agent implementation

## Consequences

### Positive
- Simple deployment and operations
- Clear security boundaries
- Reuses existing infrastructure
- Can evolve incrementally

### Negative
- No auto-healing (Docker Compose vs K8s)
- Single point of failure (one LXC)
- Manual scaling if needed

### Risks
- AGiXT/LibreChat integration may require custom work
- pgvector performance at scale unknown
- WhatsApp requires public endpoint exposure

## References

- [Jarvis Blueprint](/root/repos/infrastructure/plans/jarvis/README.md)
- [LibreChat Docs](https://docs.librechat.ai/)
- [AGiXT Docs](https://agixt.com/)
