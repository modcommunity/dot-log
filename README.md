[![Log - GameSpice addon](docs/banner.png)](https://moddingcommunity.com/a/59-gs-log)

Where your game's log lines go. Every [**GameSpice**](https://gamespice.net) addon already writes through `DotLog` (from [dot-core](https://github.com/gamespice-platform/core)); dot-log decides what happens to those records next: a rotating file, a memory ring, syslog, a database table or a hosted log service. It also filters, hides secrets, collapses floods and batches, once, in front of every destination. Part of TMC's open source **GameSpice** collection (MIT licence).

> Built with Claude Code. Every addon has a headless test suite and the suites pass, but little of this has met real players yet. Please report rough edges.

`DotLog` stays the front door and your calls do not change. dot-log plugs in behind it.

## Install

Copy `addons/dot_log/` and dot-core's `addons/dot_core/` into your project and enable dot-log under **Project > Project Settings > Plugins**. There is no autoload: you create a `DotLogRouter` where you want one.

## Quick start

```gdscript
var router := DotLogRouter.new()
router.set_context({"service": "playlot", "env": "prod", "host": "eu-1"})

router.targets.append(DotLogTargetFile.new("user://logs", "playlot"))
router.targets.append(DotLogTargetMemory.new(512))       # the console, and bug reports

add_child(router)                                        # starts on _ready
```

That gives a rotating log file and the last 512 lines in memory. To also ship records to a collector:

```gdscript
var loki := DotLogFormatLoki.new()
loki.token = token                                       # never from the environment

var remote := DotLogTargetHttp.new(loki, "https://logs.example.com")
remote.gate = DotLogGate.new()
remote.gate.min_level = DotLog.Level.INFO                # the file keeps DEBUG
await router.add_target(remote)
```

Or describe it all as configuration, which is what a deployment wants:

```gdscript
var config := DotLogConfig.new()
var loaded := config.load_layered("user://logging.json")  # file, then env, then command line
config.apply_levels()
add_child(config.build_router())
```

```bash
# One run at debug, shipping to the collector, without editing anything:
./server --log-level debug --log-remote-enabled true
```

## What it protects you from

| Problem | What dot-log does |
| --- | --- |
| A flood becomes an outage (one bad packet in a loop writes thousands of identical lines). | Collapses identical lines into one line and a count, rate-limits per channel and reports how many it suppressed. |
| A collector goes away and the queue eats all memory. | Every queue is bounded in records and in bytes (defaults 4096 records and 8 MiB), has a drop policy and counts what it dropped. |
| A secret leaves the machine. | Redaction runs once, before every target. |
| A dead collector costs frames. | One request in flight, a circuit that opens after repeated failures, and a batch that can never be accepted is dropped rather than retried forever. |

## Levels

| Level | Means | Who acts |
| --- | --- | --- |
| `TRACE` | Per-frame, per-packet, per-entity detail | Nobody. You are debugging now. |
| `DEBUG` | A decision or a state change | You, later. |
| `INFO` | Something an admin would want kept | Nobody. It is the record. |
| `WARN` | Recoverable, someone should look eventually | Someone, eventually. |
| `ERROR` | The operation failed | Someone, today. |
| `FATAL` | The process cannot continue | Someone, now. |

`FATAL` is for a crash or total breakage (boot failed, the listener could not open). dot-log flushes every target the moment one arrives, because a buffered record is lost when the process dies. `log test fatal` is refused for that reason.

Every line carries its level in a fixed width, so messages line up:

```
2026-09-14T04:59:08.051Z inf server   booting hostname="playlot" port=27015 slots=16
2026-09-14T04:59:09.114Z WRN vote     could not open the vote yet reason=time
```

`DotLog.level_style = DotLog.LevelStyle.NAME` spells levels out (`INFO`, `WARN`). Wire formats use the field their collector expects. In a database the level is two columns: `level` (an integer, for sorting and filtering) and `level_name` (to read). The index is `(channel, level)`.

## Targets

| Target | For |
| --- | --- |
| `DotLogTargetFile` | A rotating file. Human text or JSON lines. |
| `DotLogTargetMemory` | A ring buffer for an in-game console, `status` output, bug reports and crash breadcrumbs. |
| `DotLogTargetSyslog` | RFC 5424 over UDP or TCP. |
| `DotLogTargetSql` | A table through any driver with `execute(sql, params)`: batched inserts, a retention delete and a tail query. |
| `DotLogTargetHttp` | Hosted services; a `DotLogFormat` decides the bytes. |

## Wire formats

| Format | Sends to |
| --- | --- |
| `DotLogFormatNdjson` | One JSON object per line. Accepted by most agents and pipelines. Start here. |
| `DotLogFormatLoki` | Grafana Loki, with low-cardinality labels. |
| `DotLogFormatElastic` | Elasticsearch and OpenSearch through `_bulk`. It checks the body, because that API answers 200 even when it rejected everything. |
| `DotLogFormatSplunk` | Splunk HTTP Event Collector. |
| `DotLogFormatDatadog` | Datadog v2 log intake. |
| `DotLogFormatSeq` | Seq (CLEF), which is easy to self-host. |
| `DotLogFormatGelf` | Graylog GELF over HTTP. |
| `DotLogFormatOtlp` | OpenTelemetry logs over OTLP/HTTP. |
| `DotLogFormatSentry` | Error tracking: only serious records become events, and the memory ring supplies breadcrumbs. |

A new format is one small file: build the body, name the path and header, say what success looks like.

## Settings

`DotLogConfig` is layered like every GameSpice config: defaults, JSON file, `DOT_LOG_*` environment, `--log-*` command line. `remote_token` and `sentry_dsn` are accepted from the file only, never from the environment or command line.

| Setting | Default | What it does |
| --- | --- | --- |
| `level` | `info` | Global level. |
| `channel_levels` | none | Per-channel overrides, as `channel=level`. |
| `mirror_min_level` | `error` | Lowest level also sent to the engine's own error output. |
| `stdout` | true | Print to standard output. |
| `flush_interval_sec` | 2.0 | How often buffers are flushed. |
| `service`, `env`, `host`, `instance`, `version` | empty | Context attached to every record. |
| `file_enabled` | true | Write a file. |
| `file_directory`, `file_basename` | `user://logs`, `server` | Where. |
| `file_json` | false | JSON lines instead of text. |
| `file_level` | `debug` | Lowest level written to the file. |
| `file_max_bytes`, `file_max_files` | 16 MiB, 10 | Rotation size and how many files to keep. |
| `file_daily` | false | Also start a new file each day. |
| `memory_enabled`, `memory_capacity` | true, 512 | The memory ring and its size in records. |
| `syslog_enabled` | false | Send to syslog. |
| `syslog_host`, `syslog_port`, `syslog_tcp` | `127.0.0.1`, 514, false | Where, and TCP instead of UDP. |
| `syslog_app`, `syslog_level` | `dot-server`, `info` | App name and lowest level. |
| `remote_enabled` | false | Ship to a collector. |
| `remote_format`, `remote_url` | `ndjson`, empty | Which format, and where. |
| `remote_token`, `sentry_dsn` | empty | Credentials (file only). |
| `remote_level`, `remote_batch` | `info`, 100 | Lowest level and records per request. |
| `remote_tags` | none | Extra labels. |
| `sql_enabled` | false | Write to a database. |
| `sql_table`, `sql_dialect` | `dot_log`, `sqlite` | Table and SQL flavour. |
| `sql_level`, `sql_retention_days` | `info`, 30 | Lowest level and how long rows are kept. |
| `redact_enabled` | true | Hide secrets. |
| `redact_ips`, `redact_emails` | false, true | Also hide IP addresses and email addresses. |
| `redact_drop_keys` | none | Field names to remove entirely. |
| `dedupe_window_sec` | 0 | Seconds an identical line is collapsed for. 0 = off. |
| `per_channel_rate` | 0 | Records per second per channel before throttling. 0 = off. |

## The `log` command

`DotLogCommands` is a console command that works with a client or server console without dot-log depending on either:

```gdscript
console.add_source(DotConsoleBridge.wrap(DotLogCommands.new(router), "log"))      # dot-console
server.console.add_source(DotLogCommands.new(router), DotAdminFlags.GENERIC)       # dot-server
```

| Command | Does |
| --- | --- |
| `log` | Shows what the logger is doing. |
| `log tail [n]` | The last n records from the memory ring. |
| `log grep <text> [n]` | Records matching in message or fields. |
| `log level [name]` | Reads or sets the global level. |
| `log channel <c> <level>` | Turns one subsystem up without turning everything up. |
| `log targets` | Every destination with its health and backlog. |
| `log flush` | Writes and sends everything now. |
| `log test <level> <text>` | Sends one record through the whole pipeline, to check a collector really receives. |

## Browser builds

A web build has no UDP, raw TCP or readable files. `DotLogTargetHttp` is the only target that is useful there. The file target still writes, into `user://` (a browser storage mirror a person cannot read directly).

## More

[docs/design.md](docs/design.md) explains the choices, [docs/wiring.md](docs/wiring.md) how to hook it into a game, [docs/history.md](docs/history.md) the decisions over time.

## Testing

```bash
godot --headless --path . --import
godot --headless --path . res://examples/log_selftest.tscn
```

The suite uses a fake collector and a fake database driver, so it needs no network.

## Licence

MIT. See [LICENSE](LICENSE).
