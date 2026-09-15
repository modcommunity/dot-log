This is the **logging** asset for TMC's **Dot** collection. Every other asset already calls `DotLog`; this one decides where those records actually go — a rotating file, a ring in memory, syslog, a database table, or a hosted collector — and does the gating, redaction and batching once, in front of all of them.

This collection of assets provides modular building blocks for creating games and applications within the TMC ecosystem, ensuring consistency and interoperability across all `dot-*` assets. This includes core functionality, networking, authentication, cloud integration, and more.

**These assets are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This asset, along with all the others, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** Every asset has its own headless test suite and those suites pass, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## The sink layer for DotLog

**dot-core's `DotLog` is the front door and stays exactly as it is.** Roughly four hundred and fifty files across the family call `DotLog.info(...)`, and none of them changes. dot-log attaches to it as a sink and takes over the other half of the question: what happens to a record after it has been emitted.

## Why

A dedicated server's log is an operational artefact. Admins grep it, moderation decisions are justified from it, and on a headless box it is the only interface there is. Once you are running more than one server, most of the useful questions stop being answerable from a file on one machine — "which of the four had the errors", "did this start with the new build", "show me the ten lines before that crash" — and the answer is to send the records somewhere that can answer them.

Everything that makes that safe rather than merely possible is the same for every destination, and is what this addon is:

- **A flood must not become an outage.** The log a server produces under attack is not the log it produces normally: one malformed packet in a loop turns a line a second into ten thousand, all identical. dot-log collapses them into one line and a count, rate-limits per channel, and says out loud how many it suppressed.
- **A queue must be bounded.** A collector goes away, the game keeps logging, and forty minutes later the server is killed for running out of memory — by its own logging. Every queue here has a bound in records and in bytes, a drop policy, and a record of what it dropped.
- **Secrets must not leave.** A file on a machine an admin owns can hold a session ticket; a hosted service with a web UI and ninety days of retention cannot, and neither can the bug report somebody pastes into a public tracker. Redaction happens once, in front of every target.
- **A dead collector must not cost frames.** One request in flight, a circuit that opens after repeated failures, and a batch that can never be accepted gets dropped rather than retried forever behind every record queued after it.

## Installing

Copy `addons/dot_log/` and [`dot-core`](https://github.com/modcommunity/dot-core)'s `addons/dot_core/` into your project and enable dot-log in *Project → Project Settings → Plugins*.

Nothing else is required. There is no autoload; you place a `DotLogRouter` where you want one.

## Five minutes

```gdscript
var router := DotLogRouter.new()
router.set_context({"service": "arena", "env": "prod", "host": "eu-1"})

router.targets.append(DotLogTargetFile.new("user://logs", "arena"))
router.targets.append(DotLogTargetMemory.new(512))       # the console, and bug reports

add_child(router)                                        # starts on _ready
```

That is a server with a rotating log file and the last five hundred lines in memory. To also ship them somewhere:

```gdscript
var loki := DotLogFormatLoki.new()
loki.token = token                                       # never from the environment

var remote := DotLogTargetHttp.new(loki, "https://logs.example.com")
remote.gate = DotLogGate.new()
remote.gate.min_level = DotLog.Level.INFO                # the file keeps DEBUG
await router.add_target(remote)
```

Or describe the whole thing as configuration, which is what a deployment wants:

```gdscript
var config := DotLogConfig.new()
var loaded := config.load_layered("user://logging.json")  # file < env < command line
config.apply_levels()
add_child(config.build_router())
```

```bash
# One run at debug, shipping to the collector, without editing anything:
./server --log-level debug --log-remote-enabled true
```

## Levels

Six, and they are the ones every log system converged on. A level is a promise to the person reading, not a volume knob — the value of `ERROR` is entirely in never having meant "a player typed an unknown command".

| Level | Means | Who is expected to act |
| --- | --- | --- |
| `TRACE` | Per-frame, per-packet, per-entity detail | Nobody. You are debugging right now. |
| `DEBUG` | A decision or a state transition | You, later, reading it back. |
| `INFO` | Something an admin would want kept | Nobody. It is the record. |
| `WARN` | Recoverable, and somebody should look eventually | Somebody, eventually. |
| `ERROR` | The operation failed | Somebody, today. |
| `FATAL` | The process cannot continue | Somebody, now. |

**`FATAL` is reserved.** It means a crash or a total breakage — boot failed, the listener could not open, the state the process needs is gone — and not "a very bad error". It is a promise that what follows is a shutdown, and the promise is worth something only because it is made rarely: there is exactly one `FATAL` in the whole fifty-nine-repository family. dot-log treats it as a promise too, and **flushes every target the moment one arrives**, because a record still sitting in a buffer when the process goes is a record nobody will ever read. `log test fatal` is refused for the same reason.

The level is in every line, in every format, always:

```
2026-09-14T04:59:08.051Z inf server   booting hostname="arena" port=27015 slots=16
2026-09-14T04:59:09.114Z WRN vote     could not open the vote yet reason=time
```

Three characters and a fixed width, so the message column lines up in a wall of them and the eye finds the upper-case ones without reading. `DotLog.level_style = DotLog.LevelStyle.NAME` spells them out instead (`INFO`, `WARN`), padded to five.

In the wire formats it goes wherever that collector expects it — `level` for ndjson and Loki, `status` for Datadog, `@l` for Seq, `severityNumber` for OTLP, the RFC 5424 priority byte for syslog. **In the database it is two columns**: `level` as an `INTEGER` to sort, filter and compare on, and `level_name` beside it to read. Both, because sorting on the name alone gives `ERROR < FATAL < INFO < WARN` — alphabetical, and almost exactly the wrong order. The index is `(channel, level)`, which is the query people actually run.

## Where records can go

| Target | For |
| --- | --- |
| `DotLogTargetFile` | The rotating file every dedicated server has. Human format or JSON lines. |
| `DotLogTargetMemory` | A ring buffer: the in-game console, `status` output, bug reports, and the breadcrumbs attached to a crash. |
| `DotLogTargetSyslog` | RFC 5424 over UDP or TCP. Already listening on every Linux host, and it needs no account. |
| `DotLogTargetSql` | A table, through any driver with `execute(sql, params)`. Batched inserts, a retention delete, and a tail query. |
| `DotLogTargetHttp` | Everything hosted, with a `DotLogFormat` deciding the bytes. |

## Wire formats

| Format | Notes |
| --- | --- |
| `DotLogFormatNdjson` | One JSON object per line. What every agent, pipeline and hand-written receiver accepts. Start here. |
| `DotLogFormatLoki` | Grafana Loki's push API, with labels kept deliberately low-cardinality. |
| `DotLogFormatElastic` | Elasticsearch and OpenSearch, through `_bulk` — and it checks the body, because that API answers 200 when it has rejected everything. |
| `DotLogFormatSplunk` | The HTTP Event Collector. |
| `DotLogFormatDatadog` | The v2 log intake. |
| `DotLogFormatSeq` | Seq, in CLEF. The one on this list a community can self-host in an afternoon. |
| `DotLogFormatGelf` | Graylog's GELF over HTTP. |
| `DotLogFormatOtlp` | OpenTelemetry logs over OTLP/HTTP. Point it at a collector and fan out from there. |
| `DotLogFormatSentry` | Error tracking, not log collection: only the serious records become events, and the ring buffer supplies the breadcrumbs. |

Adding another is one small file — build the body, name the path and the header, say what a successful response looks like. Nothing else changes.

## The `log` command

`DotLogCommands` is a console command with the shape dot-console's `DotConsoleBridge` duck-types, so it plugs into a client console or a server console without dot-log depending on either:

```gdscript
console.add_source(DotConsoleBridge.wrap(DotLogCommands.new(router), "log"))
```

On a **dedicated server**, dot-server's own console takes the same object directly — it duck-types the identical shape, so nothing here is named on either side:

```gdscript
server.console.add_source(DotLogCommands.new(router), DotAdminFlags.GENERIC)
```

```
log                      what the logger is doing
log tail [n]             the last n records, from the memory ring
log grep <text> [n]      the ones matching, message and fields
log level [name]         read or set the global level
log channel <c> <level>  turn one subsystem up without turning everything up
log targets              every destination, with its health and its backlog
log flush                write and send everything now
log test <level> <text>  put one record of that level through the whole pipeline
```

`log test` is the one that earns its place. Whether a collector is actually receiving anything cannot be read off anything else, and the usual way to find out is to wait for a real error and see whether it turns up — a test you run once, badly, at the worst possible moment.

## The browser

A web build has no UDP, no raw TCP, and nowhere useful to put a file. `DotLogTargetHttp` is the only target that works there, which is also the reason it exists: it is how a shipped browser client reports anything at all. The file target still runs and still writes, into `user://`, which is an IndexedDB mirror — every write is synced, and it is still not somewhere a person can read.

## Validating

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done
godot --headless --path . res://examples/log_selftest.tscn
```

The suite runs 445 checks against a fake collector and a fake database driver, and needs neither a network nor an extension installed.

## License

MIT. See [LICENSE](LICENSE).
