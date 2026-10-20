# Philosophy Alignment

Arcis Bot does not invent a new philosophy. It expresses the existing Arcis model as a long-lived local agent.

| Arcis principle | How the bot keeps it |
|-----------------|----------------------|
| Single Zig binary, zero external runtimes | Daemon is the Arcis binary; bot logic is thin extensions or configuration on top of existing subsystems |
| Local sovereignty | All state lives in the hearth directory on the PC; no cloud dependency for the core loop |
| Governed terminology | Every new concept the bot uses goes through propose → validate; forks are explicit |
| Cultural naming + rank | The bot receives a generated name and rank; higher ranks can validate terms or approve new tools |
| Agents + workflows already exist | ReAct planner, ToolRegistry, Orchestrator, DAG runner, scheduler, and triggers are reused unchanged |
| Ancient / classical library | Routines can ingest, tag, and query the library; observations are written back as library entries when appropriate |
| Openly licensed artifacts only | Weights, books, and task sets follow the parent engine’s ingestion rules |

The bot is simply the named, persistent, duty-bearing inhabitant of the Arcis hearth.
