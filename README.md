# Arcis Bot

Local long-lived agent that runs on a PC, grounded in the Arcis philosophy.

**Parent engine:** [5mil/arcis](https://github.com/5mil/arcis) — the core Zig-native AI engine (inference, RAG, agents, media, workflow, ontology, naming system, ancient text library, and dashboard).

Arcis Bot reuses that engine as a persistent daemon and adds durable identity, memory, routines, and constrained local tools so a named agent continues working while the user is away.

## Philosophy (kept intact)

- Single binary, zero external runtimes for the core.
- Local-first / sovereign: the hearth lives on the machine.
- Governed knowledge: terminology lifecycle (propose → validate → deprecate/fork).
- Cultural naming system with rank hierarchy.
- Existing agents (ReAct + ToolRegistry + Orchestrator) and workflows (DAG + scheduler + triggers).
- Openly licensed artifacts only for weights and library.

## Quick start

See [docs/SETUP.md](docs/SETUP.md) for the full guide.

```sh
# Clone this bot repo alongside the engine
git clone https://github.com/5mil/arcis-bot
cd arcis-bot

# Follow the setup guide to run the Arcis daemon and start the persistent bot
```

## Layout

- `docs/` — setup, philosophy alignment, and extension notes
- `examples/` — starter workflows and agent role definitions
- `src/` — thin Zig extensions that sit on top of the parent Arcis sources (when the engine is available)
- `tools/` — helper scripts for the house box

## Status

Initial scaffolding. The bot reuses Arcis subsystems; concrete Zig patches are documented so they can be applied inside a local checkout of the engine.
