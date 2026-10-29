# Design

What dot-log is in relation to dot-core's `DotLog`, what the levels mean operationally, and the decisions in the pipeline worth not reversing. How it reaches a server and its console is [wiring.md](wiring.md); the bugs are [history.md](history.md).

## The split with dot-core, and why it is where it is

`DotLog`, the class nearly every file in this family calls, **stays in dot-core and does not change**. It is a static class with a level, a per-channel level, a console format and a list of `Callable` sinks. That is the front door and it must keep working in a project that has dot-core and nothing else.

dot-log is the back half: it registers one sink and owns everything downstream of it. Which means **no consumer has to change to gain any of this**, and a project that does not want it is not carrying it.

Two things do live in dot-core and look like duplication:

- **`DotLogSink`** is a small rotating file sink. It stays. A project with no dependency but dot-core needs a log file, and `DotLogTargetFile` is not available to it. dot-log's file target is a superset (per-target gate, JSON lines, daily rotation, the router's context) and it participates in the pipeline. Deliberate duplication, per the family rule.
- **`DotLog.mirror_min_level`**, below.

## The stack-trace problem, and what fixed it

`DotLog` mirrors serious records through `push_warning` / `push_error` so they reach the editor's Errors dock and crash reports. In a debug build the engine appends an `at:` line naming a file inside its own source, followed by a full GDScript backtrace, **and there is no way to suppress that per call**. `Engine.print_error_messages = false` is the only switch and it silences real runtime errors too, so it is not one you leave off in a server.

The consequence, which is what prompted this addon: a recoverable and entirely expected warning (an optional profile lookup that was refused, a vote that cannot open yet) cost eight lines of stderr and read, to an admin scanning a log, exactly like a crash. The `WRN` line `DotLog` prints itself already carried the same message, so the mirror was contributing a stack trace and nothing else.

`DotLog.mirror_to_engine` is gated by `DotLog.mirror_min_level`, which defaults to `ERROR`. Warnings print as one line; errors keep the trace, because there the stack is the information and there are few enough of them to be worth the noise. `DotLogRouter.mirror_min_level` sets it from configuration, and setting it to `WARN` brings the traces back for an afternoon of hunting one specific warning.

## Levels, and the one that is a promise

Six, in dot-core, and dot-log adds no seventh. What this addon adds is that they mean something operationally:

- **The level is in every line and every payload**, at a fixed width in the console (`DotLog.level_column`, which honours `DotLog.level_style` so a process is consistent) and under whatever name each collector uses: `level`, `status`, `@l`, `severityNumber`, the RFC 5424 priority byte.
- **In SQL it is two columns.** `level INTEGER` to sort and filter on, `level_name TEXT` to read, indexed as `(channel, level)`. Both, because `ORDER BY level_name` gives `ERROR < FATAL < INFO < WARN` (alphabetical and almost exactly the wrong order), and because a dashboard that has to `CASE WHEN` a string into a severity is a dashboard nobody writes twice. `DotLog.format_json` carries a numeric `severity` beside its `level` name for the same reason.
- **FATAL flushes everything, synchronously where it can.** `DotLogRouter.flush_at_level` defaults to FATAL and starts a flush of every target from inside the dispatch. FATAL promises that a shutdown follows, so anything still buffered when one arrives is a record nobody will read, and the last few records before a process dies are the ones that explain why. The flush is *started*, not awaited, because this runs inside a log call inside gameplay; `shutdown()` is the path that waits.
- **`log test fatal` is refused.** A console command that made the promise falsely would teach every reader of the log to stop believing the level, and the level is worth exactly what it is believed to be worth.

`DotLog.at(level, …)` is for the cases where the level is genuinely data: a console test record, a config-driven severity, a bridge replaying records that arrived with their own level. The six named calls remain what code should use: a level written into the call is a level somebody can grep for. `Level.OFF` is refused there rather than silently dropped, because it is a threshold and not a severity.

## The destination is not the interesting part

Every hosted log service takes a batch of records over HTTP POST. Not one of them agrees with another about the envelope, the timestamp units, where the credential goes, or what a successful response looks like, and none of those differences is hard. What is hard is the same for all of them, and is the reason this is an addon rather than nine scripts:

| Problem | Where it is solved | What happens without it |
| --- | --- | --- |
| A flood of identical lines | `DotLogGate` | The incident is buried, and a hosted collector's bill is not. |
| An unbounded queue | `DotLogBuffer` | The collector goes away and the server is killed for running out of memory, by logging. |
| Secrets in records | `DotLogRedactor` | A session ticket is in a search index with ninety days of retention, and in a pasted bug report. |
| A dead collector | `DotLogTargetHttp`'s circuit | Every flush costs a socket, a DNS lookup and a frame, for the length of the outage. |
| A batch that can never land | `_worth_retrying` | Every record queued behind it waits forever. |
| A target that logs | `DotLogRouter`'s reentrancy guard | Stack overflow, and the process dies of its own diagnostics. |

## The reentrancy guard is load-bearing

A target that calls `DotLog` from inside `write()` re-enters the sink it is being called from, which calls the target, which logs again. That is unbounded recursion ending in a dead process, **caused by the logger**, in a process that was otherwise fine.

It is not hypothetical: the natural way to report that a log file could not be opened is to log it. So `DotLogRouter._dispatching` is checked before anything else, and a record produced while dispatching is counted (`describe()["reentrant_dropped"]`) and dropped. Every internal notice (a repeat summary, a dropped-record notice) is therefore *returned* as a synthetic event rather than logged, and injected by the router from outside the guard. `DotLogBuffer.drain_drop_notice` and `DotLogGate.drain_summaries` are that shape for that reason, and it is the first thing to preserve when editing either.

The suite has a `LoudTarget` that does the forbidden thing on purpose. If that check ever fails, it fails by killing the test process.

## Decisions worth not reversing

**Timestamps come from a boot offset plus the monotonic clock, not from `Time.get_unix_time_from_system()` per record.** A system call per line is the smaller reason. The real one is that the wall clock is not monotonic: an NTP step or a laptop waking makes a batch of records go backwards, which some collectors reject outright and the rest render unreadably. The cost is drift of seconds per day in the absolute value, against an ordering that cannot invert. `DotLogEvent.resync_clock()` exists and is never called automatically, because a resync moves every subsequent timestamp in one step.

**Nothing mutates the event.** Sinks run in order over the same `Dictionary`. A target that normalised it in place would change what the next target receives, and the symptom would be two collectors disagreeing about a line both of them got.

**Values are coerced with `DotLogEvent.json_value`, and anything exotic becomes a string.** `JSON.stringify` does not fail on a `Vector3`: it emits an array; a `Node` becomes `null`; a `Callable` becomes `{}`. A position field silently arriving as an unqueryable three-element list is found months later by somebody trying to search on it.

**`DotLogTargetSql`'s driver is duck-typed, not a class of ours.** Anything with `execute(sql, params) -> DotResult` works, which is deliberately the shape dot-sql's drivers have. An operator who set up a database for bans should not set up a second one for logs, and the two addons must not have to know about each other to share it. `DotLogSqlSchema` holds the DDL and parameterised statements so they are testable without a database.

**Loki's labels are a fixed short list.** Label cardinality is how people break Loki: one label carrying a player id turns one stream into a hundred thousand index entries. Everything else goes in the line, where `| json` can still filter on it and cannot take the cluster down. Sentry's tags are limited for the same reason.

**A 64-bit number is a string on the wire.** Nanosecond timestamps do not survive a double, and JSON numbers are doubles to most parsers. Loki and OTLP both specify their timestamp fields as strings; OTLP specifies `intValue` that way too. This is the single most common OTLP JSON bug.

**A `DotLogFormat` is where a service's quirks go, and `interpret()` is not optional.** A 200 is not a delivery: the bulk API answers 200 with a body saying every document was rejected, and the event collector answers 200 with a non-zero code. A shipper that trusts the status code drops those records and reports itself healthy while it does.

**A 4xx from a collector is permanent** except 408 and 429. dot-core maps every unrecognised non-2xx onto the retryable `DotError.CODE_HTTP`, which is right for an API call and wrong for a shipper; `DotLogTargetHttp._worth_retrying` overrides it on the status code.

## Reasoning moved out of the source comments

**The router's reentrancy guard.** A target that calls `DotLog` from inside `DotLogTarget.write` re-enters the sink it is called from, which calls the target, which logs again: a stack overflow from a diagnostic. The natural way to report that a log file could not be opened is to log it, so `_dispatching` is checked first and a record produced while dispatching is counted and dropped. The router's usage is `router.set_context({...})`, `router.add_target(DotLogTargetFile.new("user://logs", "arena"))`, `add_child(router)` (it starts on `_ready`).

**The pipeline is flat, not a list of targets.** A configuration format expressive enough for any arrangement of targets is a small programming language, and every deployment needed the same four things: a file, a ring in memory, somewhere to forward to, and a table. A deployment with two collectors adds the second target in code. A server started with `--log-level debug --log-remote-enabled true` ships debug records for one run without a file edited. `remote_token` and `sentry_dsn` are refused from the environment and command line like every secret here: other processes can read both, and a token in a pasted bug report has to be rotated.

**The buffer is bounded in records and bytes** because an unbounded queue turns a collector outage into an out-of-memory kill, a server dying of its logging, and one large field makes a short queue heavy. `DROP_OLDEST` suits a live incident (the lines nearest the failure); `DROP_NEWEST` suits root-cause work (the first error explains the next thousand). Drops are counted into a record of their own, since a silent hole is worse than a short log.

**The clock is an offset, not a call per record.** `Time.get_unix_time_from_system` is a system call per line and not monotonic, so an NTP step or a laptop waking makes a batch go backwards, which some collectors reject. The cost is that absolute timestamps drift with the host, by seconds a day.

**The gate has four stages**, cheapest first: level and channel (per target, since a file wants DEBUG and a hosted collector WARN), per-level sampling (TRACE and DEBUG only), deduplication over a window (the first copy goes through, the rest become a count), and a per-channel rate limit as the floor. Under attack one line becomes ten thousand identical ones, which costs money, buries the record that explains the incident and makes the logger part of the outage.

**The redactor works two ways**, by key (reliable, extend it per field) and by shape (best-effort, since a redactor promising to catch every secret in free text is lying). The rule it cannot enforce: put values in fields, not in the message. IPv4 masking is off by default because an admin correlates cheat reports and justifies bans with addresses; turn it on for a client shipping to a hosted collector. A `RegEx` that fails to compile is not null, it is a RegEx whose `is_valid()` is false and which matches nothing for the life of the process.

**A target must not block, must not log, must not mutate the event, and must fail visibly.** A network round trip in `write` moves the collector's latency into the frame. A target that discards the log because its disk is full has made the incident harder to investigate.

**`DotLogTargetHttp` behaviours.** One request at a time, because two concurrent requests from one queue arrive out of order and every collector orders by the timestamp carried. The circuit opens after `failures_before_open` failures for `open_circuit_sec`: a collector that is down stays down for minutes, and retrying every two seconds turns one outage into a second one. A rejected batch is dropped and a failed one kept (see `_worth_retrying`). HTTP is the only transport a browser has.

**Buffered files and rotation.** A flush per line is a system call per line and an IndexedDB transaction per line on web, so lines go out on the router's flush and `flush_on_error` narrows the loss for the lines that matter. Rotation opens a new file rather than renaming an open one (Windows refuses, and behaviour differs on each target); the sortable name keeps a directory listing chronological. dot-core's `DotLogSink` is the smaller version for a project with no dependency but dot-core.

**Syslog.** It is already there on every Linux box: no agent, key or account. UDP cannot block the game and cannot tell you the collector is gone, so it is sent as the record arrives. TCP is octet-counted (RFC 6587), ordered and reports a dead collector, at the cost of a connection, so it is buffered and sent on flush.

**SQL.** Godot ships no database driver, so everything that can be GDScript is (DDL, parameterised multi-row insert, batching, retention) and the native step is handed to whatever is installed. A log table beats a file for several servers writing one place, a web panel that queries, retention in rows, and joins against bans and players; on a single box a file costs nothing and survives the database being down. The schema is six indexed columns and one JSON blob, because every addon invents its own fields and a column per field is a migration per addon. Every statement is parameterised because a log message is the most attacker-influenced string in the process.

**Per-service formats.** Datadog: `ddsource` set to an unknown name gets the generic parser, `ddtags` is a comma string, `status` must be a name it knows, and an EU account sending to the US intake gets a 403, so the region lives in the base URL. Elasticsearch: the bulk API answers 200 while rejecting everything and infers a type per field on first sight, hence the field prefix. GELF: custom fields start with an underscore or are dropped, `_id` is forbidden, `short_message` is required and non-empty, `timestamp` is seconds with a fraction; chunked UDP reassembly is where GELF implementations break, so it is not implemented. Loki: every label combination is a stream, so labels are a fixed short list and everything else is in the line; a 400 is structural and is dropped. OTLP: JSON rather than protobuf, 64-bit numbers as strings, tagged-union attribute values, resource attributes once per batch. Sentry: an error tracker groups events into issues, so sending it INFO lines buries the crashes; the trail comes from a `DotLogTargetMemory`, and the DSN holds a public key but is still deployed, not ambient. Seq: it groups by message template, which matches a constant message plus fields. Splunk: the scheme is `Splunk`, not `Bearer`; the body is concatenated objects; milliseconds index at year 56000.

**The `log test` command** exists because "is the collector receiving anything" is otherwise answered by waiting for a real error, once, badly, at the worst moment.
