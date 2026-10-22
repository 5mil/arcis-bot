# Arcis Bot

Local long-lived agent that runs on a PC **or a VPS**, grounded in the Arcis philosophy.

**Parent engine:** [5mil/arcis](https://github.com/5mil/arcis) — the core Zig-native AI engine (inference, RAG, agents, media, workflow, ontology, naming system, ancient text library, and dashboard).

Arcis Bot reuses that engine as a persistent daemon and adds durable identity, memory, routines, and constrained local tools so a named agent continues working while the user is away.

## Philosophy (kept intact)

- Single binary, zero external runtimes for the core.
- Local-first / sovereign: the hearth lives on the machine (PC or VPS).
- Governed knowledge: terminology lifecycle (propose → validate → deprecate/fork).
- Cultural naming system with rank hierarchy.
- Existing agents (ReAct + ToolRegistry + Orchestrator) and workflows (DAG + scheduler + triggers).
- Openly licensed artifacts only for weights and library.

## Quick start

- **Local PC / house box:** [docs/SETUP.md](docs/SETUP.md)
- **VPS:** [docs/VPS.md](docs/VPS.md)

```sh
git clone https://github.com/5mil/arcis-bot
cd arcis-bot
# Then follow the guide that matches your host
```

## Layout

- `docs/` — setup (PC + VPS), philosophy alignment, and extension notes
- `deploy/systemd/` — unit file for the bot daemon
- `examples/` — starter workflows and agent role definitions
- `src/` — thin Zig extensions that sit on top of the parent Arcis sources (includes `src/arcis-dgb/`, the DGB paper-trading engine)
- `tools/` — helper scripts

## Roadmap
- [Phase 1 status](docs/PHASE1.md) — paper desk wrapper + feed skeleton + routine


- [DGB desk roadmap](docs/ROADMAP.md) — paper bot → protected live auto-trade


## Status

Scaffolding ready for both local and VPS hosts. The bot reuses Arcis subsystems; concrete Zig patches are documented so they can be applied inside a local checkout of the engine.
