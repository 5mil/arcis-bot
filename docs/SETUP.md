# Arcis Bot — Comprehensive Setup Guide

This guide turns the Arcis engine into a long-lived local bot on a PC while preserving every part of the Arcis philosophy.

## Prerequisites

- Zig 0.14+ 
- A local clone of the parent engine: `https://github.com/5mil/arcis`
- An openly licensed GGUF model (e.g. DeepSeek-R1-Distill-Qwen-1.5B Q4)
- A directory that will serve as the hearth (persistent state)

## 1. Persistent local hearth

1. Clone both repositories side-by-side:
   ```sh
   git clone https://github.com/5mil/arcis
   git clone https://github.com/5mil/arcis-bot
   ```
2. Build the engine:
   ```sh
   cd arcis
   zig build
   ```
3. Create a hearth directory (e.g. `~/arcis-hearth`) and point the daemon at it.
4. Run as a daemon (use the existing `deploy/systemd` unit or a simple supervisor):
   ```sh
   ./zig-out/bin/arcis --tier visio --port 9090 \
     --model models/gguf/DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf
   ```
5. On start, the session loads Catalog, NameStore, ConceptStore, and agent memory from the hearth. On clean shutdown it flushes them.

## 2. Name and ontology place

On first start the bot:

- Generates its own name via the naming system (tradition + rank).
- Stores the name in NameStore under a stable Entity URN.
- Proposes a small set of core terms ("hearth", "duty", "routine", "local-tool") through TerminologyDirectory.
- A human (or higher-rank process) validates them.

Example (Zig API sketch that lives on top of ArcisSession):

```zig
const name_id = try session.names.generateAndStore(.greek, .adept, seed);
const concept = try session.terms.propose("hearth", "the local durable place of the bot", "arcis-bot");
_ = session.terms.validate(concept);
```

## 3. Long-lived agent loop

- Register an AgentRole whose `allowed_tools` is an explicit list.
- Use the existing Orchestrator to keep one persistent Agent instance.
- Add a resume path that reloads the last thought/observation from the hearth.
- Expose a minimal inbox (HTTP endpoint already present on the daemon, or a watched file) so the user can post tasks.

## 4. Routines as workflows

Every recurring duty is a named workflow stored with the session:

- Time-based or event-based triggers via the existing scheduler.
- On completion, write a short observation into the library or agent memory.
- The bot’s name/URN is recorded as owner.

Starter example lives in `examples/daily-status.workflow.json`.

## 5. Constrained local tools

Register tools in ToolRegistry that stay inside the philosophy:

- Read/write only under a declared directory.
- File-system watch.
- Allow-listed shell commands.
- No unrestricted system access.

Implementations stay in Zig or thin controlled wrappers.

## 6. Observation

Extend the existing dashboard views (or add a tiny CLI) to show:

- Current name and rank
- Active routines
- Recent observations
- Proposed / validated terms

## Order of work

1. Hearth + durable session  
2. Name + ontology place  
3. Persistent agent + inbox  
4. First workflows  
5. Local tools  
6. Views  

All steps reuse `src/agents`, `src/workflow`, `src/naming`, `src/ontology`, and the session layer already present in the parent engine. No new runtime is introduced.

## House-box sequence

See the parent engine’s `docs/INSTRUCTIONS.md` for the full desk + Moodle + library sequence. This bot simply adds the persistent agent layer on top of that running daemon.
