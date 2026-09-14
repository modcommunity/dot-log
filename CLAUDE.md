# dot-log

Where a log record goes after `DotLog` emits it. Rotating files, a ring in memory, RFC 5424 syslog, a SQL table through any driver, and batched HTTP shipping in the wire formats the log services actually accept — with gating, redaction, batching and back pressure done once, in front of all of them.

**The distributable is `addons/dot_log/`.** It requires [dot-core](../dot-core), a separate repository, and nothing else.

```bash
# Local development setup — the symlink is gitignored on purpose.
ln -s ../../dot-core/addons/dot_core addons/dot_core
```

## The split with dot-core, and why it is where it is

`DotLog` — the class about four hundred and fifty files in this family call — **stays in dot-core and does not change**. It is a static class with a level, a per-channel level, a console format and a list of `Callable` sinks. That is the front door and it must keep working in a project that has dot-core and nothing else.

dot-log is the back half: it registers one sink and owns everything downstream of it. Which means **no consumer has to change to gain any of this**, and a project that does not want it is not carrying it.

Two things do live in dot-core and look like duplication:

- **`DotLogSink`** is a small rotating file sink. It stays. A project with no dependency but dot-core needs a log file, and `DotLogTargetFile` is not available to it. dot-log's file target is a superset — per-target gate, JSON lines, daily rotation, the router's context — and it participates in the pipeline. Deliberate duplication, per the family rule.
- **`DotLog.mirror_min_level`** was added to dot-core as part of this work. See below.

## The stack-trace problem, and what fixed it

`DotLog` mirrors serious records through `push_warning` / `push_error` so they reach the editor's Errors dock and crash reports. In a debug build the engine appends an `at:` line naming a file inside its own source, followed by a full GDScript backtrace — **and there is no way to suppress that per call**. `Engine.print_error_messages = false` is the only switch and it silences real runtime errors too, so it is not one you leave off in a server.

The consequence, which is what prompted this addon: a recoverable and entirely expected warning — an optional profile lookup that was refused, a vote that cannot open yet — cost eight lines of stderr and read, to an admin scanning a log, exactly like a crash. The `WRN` line `DotLog` prints itself already carried the same message, so the mirror was contributing a stack trace and nothing else.

`DotLog.mirror_to_engine` is now gated by `DotLog.mirror_min_level`, which defaults to `ERROR`. Warnings print as one line; errors keep the trace, because there the stack is the information and there are few enough of them to be worth the noise. `DotLogRouter.mirror_min_level` sets it from configuration, and setting it to `WARN` brings the traces back for an afternoon of hunting one specific warning.

## Levels, and the one that is a promise

Six, in dot-core, and dot-log adds no seventh. What this addon adds is that they now mean something operationally:

- **The level is in every line and every payload**, at a fixed width in the console (`DotLog.level_column`, which honours `DotLog.level_style` so a process is consistent) and under whatever name each collector uses — `level`, `status`, `@l`, `severityNumber`, the RFC 5424 priority byte.
- **In SQL it is two columns.** `level INTEGER` to sort and filter on, `level_name TEXT` to read, indexed as `(channel, level)`. Both, because `ORDER BY level_name` gives `ERROR < FATAL < INFO < WARN` — alphabetical and almost exactly the wrong order — and because a dashboard that has to `CASE WHEN` a string into a severity is a dashboard nobody writes twice. `DotLog.format_json` gained a numeric `severity` beside its `level` name for the same reason.
- **FATAL flushes everything, synchronously where it can.** `DotLogRouter.flush_at_level` defaults to FATAL and starts a flush of every target from inside the dispatch. That is the operational content of the level: FATAL promises that a shutdown follows, so anything still buffered when one arrives is a record nobody will read — and the last few records before a process dies are the ones that explain why. The flush is *started*, not awaited, because this runs inside a log call inside gameplay; `shutdown()` is the path that waits.
- **`log test fatal` is refused.** A console command that made the promise falsely would teach every reader of the log to stop believing the level, and the level is worth exactly what it is believed to be worth.

`DotLog.at(level, …)` was added to dot-core for the cases where the level is genuinely data — a console test record, a config-driven severity, a bridge replaying records that arrived with their own level. The six named calls remain what code should use: a level written into the call is a level somebody can grep for. `Level.OFF` is refused there rather than silently dropped, because it is a threshold and not a severity.

## The one idea: the destination is not the interesting part

Every hosted log service takes a batch of records over HTTP POST. Not one of them agrees with another about the envelope, the timestamp units, where the credential goes, or what a successful response looks like — and none of those differences is hard. What is hard is the same for all of them, and is the reason this is an addon rather than nine scripts:

| Problem | Where it is solved | What happens without it |
| --- | --- | --- |
| A flood of identical lines | `DotLogGate` | The incident is buried, and a hosted collector's bill is not. |
| An unbounded queue | `DotLogBuffer` | The collector goes away and the server is killed for running out of memory, by logging. |
| Secrets in records | `DotLogRedactor` | A session ticket is in a search index with ninety days of retention, and in a pasted bug report. |
| A dead collector | `DotLogTargetHttp`'s circuit | Every flush costs a socket, a DNS lookup and a frame, for the length of the outage. |
| A batch that can never land | `_worth_retrying` | Every record queued behind it waits forever. |
| A target that logs | `DotLogRouter`'s reentrancy guard | Stack overflow, and the process dies of its own diagnostics. |

## The reentrancy guard is load-bearing

A target that calls `DotLog` from inside `write()` re-enters the sink it is being called from, which calls the target, which logs again. That is unbounded recursion ending in a dead process — **caused by the logger**, in a process that was otherwise fine.

It is not hypothetical: the natural way to report that a log file could not be opened is to log it. So `DotLogRouter._dispatching` is checked before anything else, and a record produced while dispatching is counted (`describe()["reentrant_dropped"]`) and dropped. Every internal notice — a repeat summary, a dropped-record notice — is therefore *returned* as a synthetic event rather than logged, and injected by the router from outside the guard. `DotLogBuffer.drain_drop_notice` and `DotLogGate.drain_summaries` are that shape for that reason, and it is the first thing to preserve when editing either.

The suite has a `LoudTarget` that does the forbidden thing on purpose. If that check ever fails, it fails by killing the test process.

## Bugs this found by running rather than reading

Both were invisible to `--check-only`, and one was invisible to an assertion about the value's length.

- **`Time.get_datetime_string_from_unix_time(t, true)` puts a space where RFC 3339 requires a `T`.** The second argument is `use_space`, not `utc` — the function is always UTC. The timestamp was the right length, the right value, and rejected or mis-parsed by Loki, OTLP and the bulk APIs. Found by a check asserting `stamp[10] == "T"` rather than `stamp.length() == 24`.
- **`RegEx.create_from_string` does not return null for a pattern it cannot compile.** It returns a `RegEx` whose `is_valid()` is false, and one of those matches nothing at all, silently, for the life of the process — so a typo in a redaction pattern would have looked exactly like a redactor that was working.

And one design mistake the suite caught: dot-core maps every unrecognised non-2xx onto `DotError.CODE_HTTP`, which is **retryable**. That is right for an API call and wrong for a shipper — a 400 from a collector would have been retried forever with every subsequent record stuck behind it. `DotLogTargetHttp._worth_retrying` overrides it on the status code: a 4xx is permanent except 408 and 429.

## What each file is for

```
core/
  dot_log_event.gd      A DotLog record -> a shippable event. Static: one per log line.
  dot_log_config.gd     The deployment document. DOT_LOG_* / --log-*, secrets refused.
  dot_log_gate.gd       Level, channel, sampling, deduplication, rate limit.
  dot_log_redactor.gd   By key and by shape. Both, because secrets arrive both ways.
  dot_log_buffer.gd     Bounded queue, drop policy, drop accounting.
sinks/
  dot_log_target.gd     The base. Four rules, each a failure somebody has had.
  dot_log_target_file.gd    Rotating file, buffered, size and daily.
  dot_log_target_memory.gd  The ring: console, status, bug reports, breadcrumbs.
  dot_log_target_syslog.gd  RFC 5424. UDP immediate, TCP buffered and octet-counted.
  dot_log_target_sql.gd     Batched inserts through a duck-typed driver.
  dot_log_target_http.gd    Batching, one in flight, circuit breaker, retry policy.
formats/                One file per service. Body, headers, path, interpret.
runtime/
  dot_log_router.gd     The Node. Attaches to DotLog; the reentrancy guard lives here.
  dot_log_sql_schema.gd DDL and parameterised statements, testable without a database.
```

## Decisions worth not reversing

**Timestamps come from a boot offset plus the monotonic clock, not from `Time.get_unix_time_from_system()` per record.** A system call per line is the smaller reason. The real one is that the wall clock is not monotonic: an NTP step or a laptop waking makes a batch of records go backwards, which some collectors reject outright and the rest render unreadably. The cost is drift of seconds per day in the absolute value, against an ordering that cannot invert. `DotLogEvent.resync_clock()` exists and is never called automatically, because a resync moves every subsequent timestamp in one step.

**Nothing mutates the event.** Sinks run in order over the same `Dictionary`. A target that normalised it in place would change what the next target receives, and the symptom would be two collectors disagreeing about a line both of them got.

**Values are coerced with `DotLogEvent.json_value`, and anything exotic becomes a string.** `JSON.stringify` does not fail on a `Vector3` — it emits an array; a `Node` becomes `null`; a `Callable` becomes `{}`. A position field silently arriving as an unqueryable three-element list is found months later by somebody trying to search on it.

**`DotLogTargetSql`'s driver is duck-typed, not a class of ours.** Anything with `execute(sql, params) -> DotResult` works, which is deliberately the shape dot-moderation's `DotSqlDriver` already has. An operator who set up a database for bans should not set up a second one for logs, and the two addons must not have to know about each other to share it.

**Loki's labels are a fixed short list.** Label cardinality is how people break Loki: one label carrying a player id turns one stream into a hundred thousand index entries. Everything else goes in the line, where `| json` can still filter on it and cannot take the cluster down. Sentry's tags are limited for the same reason.

**A 64-bit number is a string on the wire.** Nanosecond timestamps do not survive a double, and JSON numbers are doubles to most parsers. Loki and OTLP both specify their timestamp fields as strings; OTLP specifies `intValue` that way too. This is the single most common OTLP JSON bug.

**A `DotLogFormat` is where a service's quirks go, and `interpret()` is not optional.** A 200 is not a delivery: the bulk API answers 200 with a body saying every document was rejected, and the event collector answers 200 with a non-zero code. A shipper that trusts the status code drops those records and reports itself healthy while it does.

## Testing

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done
godot --headless --path . res://examples/log_selftest.tscn     # 445 checks
```

**Two engine errors in that output are produced on purpose** — `missing terminating ]` and `Parse JSON failed` — by the checks that a bad redaction pattern and a non-JSON collector response are *reported* rather than thrown. The suite says so in its own header. Neither is a failure, and the run exits 0.

The collector is a `FakeHttp` extending the real `DotHttp` (not duck-typed — the target's field is typed, and a fake that cannot be assigned proves nothing), and the database is a `FakeDriver` recording statements. Both fake the seam that exists precisely because the real thing cannot be installed here.

**What the suite cannot see:** whether any of these services actually accepts what is built for it. Every format is written to its published specification and read against it, which is not the same as having been sent. The shapes, the units, the escaping and the error handling are tested; the receiving end is not. Said out loud rather than left to be discovered.

## Wiring, and what "wire it in" does not mean

**Every addon in the family already logs through `DotLog`** — 465 files across the tree call it, and not one of them needed a line changed for any of this. That is the whole point of attaching as a sink rather than as an API.

What was actually missing was a *destination*: nothing in the family placed a sink, so on a stock server every one of those records went to stdout and nowhere else, and stdout is gone the moment a supervisor rotates or restarts. So the wiring is at the process level, and it is three things:

- **dot-server creates a log destination by default.** `log_sink_ref` used to resolve a node if the host had placed one and do nothing otherwise. It now applies the configured levels before the first line of the boot, resolves a host-placed node if there is one, and otherwise makes its own `DotLogSink` from `DotServerConfig.log_file_enabled`. A router placed there is recognised by duck typing — `describe_lines` and `flush_all`, never a name, because only dot-core may be a hard dependency — and gets the server's hostname and port as context tags. `status` reports where the log is going and at what level; `shutdown()` flushes it last, after the final state change.
- **dot-server-deploy has a `log.yml`.** Level, per-channel levels, the engine-mirror threshold, and the file settings, mapped through `TmcConfig.BOOT_KEYS` onto the config properties. The level in particular cannot be a cvar: it has to apply *before* the console exists, because the boot it is being raised to diagnose is the one that happens first.
- **`DotLogCommands` is the console half**, in the duck-typed shape both consoles already accept.

The remaining gap is real and is not this: **108 files across the family declare a `const CHANNEL` and never log through it.** They intended to say something and do not, so an operator watching those subsystems sees nothing at all. That is a per-file judgement about what deserves a line and at what level — noise at the wrong level is worse than silence — rather than a mechanical pass, and [docs/detectors.md](../../docs/detectors.md) now has the grep that finds them. dot-inventory and dot-lighting were the first two done.

## Where this is going

- **The 108 dead channels**, a few addons at a time, starting with the ones where silence costs an operator something: the stores, the reporters and the clients, where a failure is currently invisible.
- **`is_healthy()` into a health check.** dot-server reports where its log goes; what it does not report is whether the shipper is still working, and a server whose collector has been refusing it for an hour is a server nobody is watching.
- **The games**: each of the five places a `DotLogRouter` of its own for the standalone client case, where there is no dot-server in the process to make one.
