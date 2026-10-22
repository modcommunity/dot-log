# Wiring

How a process gets a destination for its logs and an operator gets the `log` command. dot-log itself attaches as a `DotLog` sink, so no addon in the family needed a line changed to use it.

## What "wire it in" means

**Every addon in the family already logs through `DotLog`.** What was missing was a *destination*: nothing in the family placed a sink, so on a stock server every record went to stdout and nowhere else, and stdout is gone the moment a supervisor rotates or restarts. So the wiring is at the process level, and it is three things:

- **dot-server creates a log destination by default.** `log_sink_ref` applies the configured levels before the first line of the boot, resolves a host-placed node if there is one, and otherwise makes its own `DotLogSink` from `DotServerConfig.log_file_enabled`. A router placed there is recognised by duck typing (`describe_lines` and `flush_all`, never a name, because only dot-core may be a hard dependency) and gets the server's hostname and port as context tags. `status` reports where the log is going and at what level; `shutdown()` flushes it last, after the final state change.
- **dot-server-deploy has a `log.yml`** (`cfg/addons/dot_log/log.yml`, with the game's `cfg/game/<game>/dot_log/`, the operator's `cfg/server/addons/dot_log/` and `cfg/server/game/<game>/dot_log/` over it, in that order; the old flat `cfg/log.yml` is read with one WARN until 2026-12-31, and `DotLogConfig.load_cfg` reads the same layout). Level, per-channel levels, the engine-mirror threshold, and the file settings, mapped through `TmcConfig.BOOT_KEYS` onto the config properties. The level in particular cannot be a cvar: it has to apply *before* the console exists, because the boot it is being raised to diagnose is the one that happens first. dot-server-deploy builds a `DotLogRouter` for every server it runs.
- **`DotLogCommands` is the console half**, below.

## `log` on a dedicated server

`DotLogCommands` has `names`, `claims`, `execute`, `complete` and `help_for`: exactly the shape dot-console's `DotConsoleBridge` duck-types. dot-server's `DotConsole` reaches it through `add_source(source, permission, chat)`, which wraps every name a duck-typed source claims in a real `DotConCommand`, so it gets the permission check, the RCON gate, the chat gate, the audit line, `cmdlist`, `help`, aliases and completion, and there is still exactly one place a command runs. Naming `DotConCommand` from this addon would make dot-server a hard dependency of a project whose only dependency is dot-core.

```gdscript
# in the host, with dot-server present:
server.console.add_source(DotLogCommands.new(router), DotAdminFlags.GENERIC)
```

dot-server-deploy does exactly that for every server it runs, and its `./server check` fails if `log` is missing from a server that booted with a router: an absent command is invisible until an admin types it during an incident.

**Completion: a candidate is a whole command line**, because the box is replaced with whatever is picked. That is the contract both consoles share with `complete` here: the subcommand names, and the six level names for `log level` and `log test`, which is the completion that actually saves typing because nobody remembers whether a logger spells it `warn` or `warning`.

## Open

- **Dead channels.** Many files across the family declare a `const CHANNEL` and never log through it: they intended to say something and do not, so an operator watching those subsystems sees nothing. Each is a per-file judgement about what deserves a line and at what level (noise at the wrong level is worse than silence), not a mechanical pass. The grep is in [detectors.md](../../../docs/detectors.md). Start where silence costs an operator something: the stores, the reporters and the clients.
- **`is_healthy()` into a health check.** dot-server reports where its log goes, not whether the shipper is still working; a server whose collector has been refusing it for an hour is a server nobody is watching.
- **The standalone client.** No game places a `DotLogRouter` of its own for the case with no dot-server in the process. The dedicated-server case is done through dot-server-deploy.
