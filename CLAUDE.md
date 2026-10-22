# dot-log

Where a log record goes after `DotLog` emits it: rotating files, a ring in memory, RFC 5424 syslog, a SQL table through any driver, and batched HTTP shipping in the wire formats nine log services actually accept, with gating, redaction, batching and back pressure done once, in front of all of them. dot-core keeps the front door; this is the sink layer.

Read the family [CLAUDE.md](../../CLAUDE.md) first (its logging rules are the ones this addon makes operational); this file is only what is specific to dot-log.

**The distributable is `addons/dot_log/`.** It requires dot-core API level 16 or later (`DotAddonConfig.apply_file`) and nothing else (symlinked, `.gitignore`).

## Read before

| Read | Before |
| --- | --- |
| [docs/design.md](docs/design.md) | anything: the split with dot-core, the mirror threshold, levels, the pipeline, the reentrancy guard, the decisions in the targets and formats |
| [docs/wiring.md](docs/wiring.md) | how a server gets a destination, `DotLogCommands` and the consoles, what is still open |
| [docs/history.md](docs/history.md) | the bugs, and how each looked |

## Layout

| Path | What |
| --- | --- |
| `addons/dot_log/core/` | `DotLogEvent` (a record as a shippable event; static), `DotLogConfig` (`DOT_LOG_*` / `--log-*`, secrets refused), `DotLogGate` (level, channel, sampling, dedupe, rate), `DotLogRedactor` (by key and by shape), `DotLogBuffer` (bounded queue, drop accounting) |
| `addons/dot_log/sinks/` | `DotLogTarget` (the base) and the file, memory (ring), syslog (UDP immediate, TCP octet-counted), SQL (duck-typed driver) and HTTP (batching, one in flight, circuit breaker, retry policy) targets |
| `addons/dot_log/formats/` | one `DotLogFormat` per service: body, headers, path, `interpret()` |
| `addons/dot_log/runtime/` | `DotLogRouter` (the Node; attaches to `DotLog`; the reentrancy guard), `DotLogSqlSchema`, `DotLogCommands` (the `log` console command) |
| `examples/log_selftest.tscn` | the suite |

## Running and testing

- The family's two steps ([game-dev/CLAUDE.md](../../CLAUDE.md#validating-anything)), then `godot --headless --path . res://examples/log_selftest.tscn`.
- **Two engine errors in its output are on purpose** (`missing terminating ]`, `Parse JSON failed`): the checks that a bad redaction pattern and a non-JSON collector response are reported rather than thrown. The run exits 0.
- The collector is a `FakeHttp` extending the real `DotHttp` (the target's field is typed, and a fake that cannot be assigned proves nothing); the database is a recording `FakeDriver`.
- **The suite cannot see whether any service accepts what is built for it.** Every format is written to and read against its published specification; none is proven by having been sent.

## Rules that bite

- `DotLog` stays in dot-core and unchanged; this addon is one sink and everything downstream. No consumer changes to use it. [design](docs/design.md#the-split-with-dot-core-and-why-it-is-where-it-is)
- `mirror_min_level` defaults to `ERROR`: warnings print one line, without the engine's unsuppressible trace. [design](docs/design.md#the-stack-trace-problem-and-what-fixed-it)
- No seventh level. SQL keeps `level` as an integer beside `level_name`; FATAL starts a flush of every target (`flush_at_level`); `log test fatal` is refused; `DotLog.at` refuses `OFF`. [design](docs/design.md#levels-and-the-one-that-is-a-promise)
- **A target never logs from inside `write()`.** Internal notices are returned as synthetic events (`drain_drop_notice`, `drain_summaries`) and injected by the router outside `_dispatching`. [design](docs/design.md#the-reentrancy-guard-is-load-bearing)
- Timestamps are a boot offset plus the monotonic clock; `resync_clock()` is never automatic. [design](docs/design.md#decisions-worth-not-reversing)
- Format timestamps with a `T` (`get_datetime_string_from_unix_time`'s second argument is `use_space`) and check `is_valid()` on every compiled `RegEx`. [history](docs/history.md)
- No target mutates the event; values go through `DotLogEvent.json_value`. [design](docs/design.md#decisions-worth-not-reversing)
- The SQL driver is duck-typed (`execute(sql, params) -> DotResult`), shared with dot-sql's. [design](docs/design.md#decisions-worth-not-reversing)
- Loki labels and Sentry tags stay a fixed short list; 64-bit numbers are strings on the wire. [design](docs/design.md#decisions-worth-not-reversing)
- Every format implements `interpret()`: a 200 is not a delivery. A 4xx is permanent except 408 and 429 (`_worth_retrying`). [design](docs/design.md#decisions-worth-not-reversing)
- `DotLogCommands` stays duck-typed (`names`, `claims`, `execute`, `complete`, `help_for`); a completion candidate is a whole command line. Never name `DotConCommand`. [wiring](docs/wiring.md#log-on-a-dedicated-server)
- dot-server recognises a router by `describe_lines` and `flush_all`; keep both. [wiring](docs/wiring.md#what-wire-it-in-means)

## Open

Dead `CHANNEL` constants across the family, `is_healthy()` in a health check, and a router for the standalone client. [wiring](docs/wiring.md#open)
