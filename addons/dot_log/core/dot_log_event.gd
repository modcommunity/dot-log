class_name DotLogEvent
extends RefCounted

## One log record, on its way out of the process.
##
## [DotLog] hands every sink a [Dictionary]:
## [code]{level, level_name, channel, message, fields, ticks_ms}[/code]. That is the
## right shape for printing a line and the wrong shape for shipping one — a collector
## wants a wall-clock time, a stable ordering, and values a JSON encoder will not
## mangle. This class is that conversion, and it is static because there is one of these
## per log line and allocating an object per line is exactly the cost a logger is not
## allowed to have.
##
## [b]Nothing here mutates the record it was given.[/b] Sinks run in registration order
## over the same [Dictionary], so a target that "normalised" it in place would be
## changing what the next target receives — and the bug would present as one collector
## disagreeing with another about a line both of them got.

## Severity numbers the shippers want, none of which agree with each other.
##
## RFC 5424 (syslog, and therefore GELF): lower is worse.
const SYSLOG_SEVERITY: Array[int] = [
	7,  # TRACE -> debug
	7,  # DEBUG -> debug
	6,  # INFO  -> informational
	4,  # WARN  -> warning
	3,  # ERROR -> error
	2,  # FATAL -> critical
	7,  # OFF, never emitted
]

## OpenTelemetry severity numbers: higher is worse, in bands of four.
const OTLP_SEVERITY: Array[int] = [1, 5, 9, 13, 17, 21, 0]

## The lowercase names most JSON collectors index on. Deliberately not
## [member DotLog.LEVEL_NAMES], which is uppercase because it is a console column.
const SEVERITY_NAMES: Array[String] = [
	"trace", "debug", "info", "warning", "error", "fatal", "off",
]

## Wall clock at process start, minus the monotonic clock at the same instant.
##
## [b]Why an offset rather than [method Time.get_unix_time_from_system] per record.[/b]
## Two reasons, and the second is the one that matters. It is a system call per line on
## a server emitting hundreds a second — and it is not monotonic, so a clock correction
## mid-session (NTP stepping, a laptop waking) makes a batch of records go backwards,
## which some collectors reject outright and the rest render as an unreadable mess.
## [method Time.get_ticks_msec] is monotonic, so this ordering cannot invert.
##
## The trade is that a long-running server's absolute timestamps drift with the host
## clock instead of tracking it. Seconds per day, against ordering that is always right.
static var _epoch_offset_ms: int = 0
static var _epoch_ready: bool = false

## Monotonic per process, so two records inside one millisecond still have an order.
static var _seq: int = 0


static func _ensure_epoch() -> void:
	if _epoch_ready:
		return
	_epoch_offset_ms = (
		int(Time.get_unix_time_from_system() * 1000.0) - Time.get_ticks_msec()
	)
	_epoch_ready = true


## Re-reads the host clock, for a process that has been up long enough to care.
##
## Not called automatically: a resync moves every subsequent timestamp by the drift in
## one step, and doing that behind the caller's back is worse than the drift.
static func resync_clock() -> void:
	_epoch_ready = false
	_ensure_epoch()


## Turns a [DotLog] record into a shippable event.
##
## Adds [code]time_ms[/code] (Unix milliseconds), [code]seq[/code] and
## [code]severity[/code], and leaves everything else exactly as it arrived.
static func from_record(record: Dictionary) -> Dictionary:
	_ensure_epoch()
	_seq += 1

	var level: int = int(record.get("level", DotLog.Level.INFO))
	var ticks: int = int(record.get("ticks_ms", Time.get_ticks_msec()))

	return {
		"level": level,
		"level_name": String(record.get("level_name", DotLog.level_name(level))),
		"severity": severity_name(level),
		"channel": String(record.get("channel", "")),
		"message": String(record.get("message", "")),
		"fields": record.get("fields", {}),
		"ticks_ms": ticks,
		"time_ms": _epoch_offset_ms + ticks,
		"seq": _seq,
	}


## A synthetic event, for the records this addon generates about itself.
##
## Used for the "the same line, 412 more times" summaries and for drop notices, both of
## which must not go back through [DotLog]. See [DotLogRouter]'s reentrancy guard.
static func synthetic(
	level: int, channel: String, message: String, fields: Dictionary = {}
) -> Dictionary:
	return from_record({
		"level": level,
		"level_name": DotLog.level_name(level),
		"channel": channel,
		"message": message,
		"fields": fields,
		"ticks_ms": Time.get_ticks_msec(),
	})


static func severity_name(level: int) -> String:
	if level < 0 or level >= SEVERITY_NAMES.size():
		return "info"
	return SEVERITY_NAMES[level]


static func syslog_severity(level: int) -> int:
	if level < 0 or level >= SYSLOG_SEVERITY.size():
		return 6
	return SYSLOG_SEVERITY[level]


static func otlp_severity(level: int) -> int:
	if level < 0 or level >= OTLP_SEVERITY.size():
		return 9
	return OTLP_SEVERITY[level]


# --- Time ------------------------------------------------------------------

static func time_ms(event: Dictionary) -> int:
	return int(event.get("time_ms", 0))


## Unix nanoseconds, as a string.
##
## As a string, not an int: nanoseconds since 1970 is about 1.8e18, which fits a 64-bit
## int and does NOT fit a double — and JSON numbers are doubles to most parsers. Loki
## and OTLP both specify the field as a string for exactly this reason.
static func time_ns(event: Dictionary) -> String:
	return str(time_ms(event)) + "000000"


static func time_sec(event: Dictionary) -> float:
	return float(time_ms(event)) / 1000.0


## ISO 8601 in UTC with milliseconds, which is what every collector here accepts.
static func iso8601(event: Dictionary) -> String:
	var ms: int = time_ms(event)
	var whole: int = ms / 1000
	var frac: int = ms % 1000
	if frac < 0:
		# Integer division truncates toward zero, so a negative millisecond count
		# (a host clock set before 1970, which does happen on a board with no RTC)
		# would otherwise render a positive fraction on a smaller second.
		frac += 1000
		whole -= 1
	# The second argument is `use_space`, NOT `utc` — this function is always UTC. Passing
	# true here put a space where RFC 3339 requires a T, which Loki, OTLP and the bulk
	# APIs all reject or mis-parse, and which no assertion about the length would catch.
	var stamp: String = Time.get_datetime_string_from_unix_time(whole, false)
	return stamp.insert(19, ".%03d" % frac) + "Z"


# --- Values ----------------------------------------------------------------

## Coerces a value into something [method JSON.stringify] renders faithfully.
##
## [b]JSON.stringify does not fail on a Vector3 or an Object — it emits something.[/b]
## A [Vector3] comes out as an array, a [StringName] as a string, a [Node] as
## [code]null[/code] and a [Callable] as an empty object, so a field that was supposed
## to carry a position arrives at the collector as an unqueryable three-element list and
## nobody finds out until they try to search on it. Everything that is not a JSON scalar
## is rendered with [method str] here, on purpose: a string reading
## [code](1.0, 2.0, 3.0)[/code] is at least honest about having been a Godot value.
static func json_value(value: Variant) -> Variant:
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return value
		TYPE_STRING_NAME:
			return String(value)
		TYPE_ARRAY:
			var out: Array = []
			for v: Variant in (value as Array):
				out.append(json_value(v))
			return out
		TYPE_PACKED_STRING_ARRAY:
			# Not caught by the TYPE_ARRAY branch: the packed types are their own
			# Variant types and are not Arrays. See docs/gdscript-hazards.md.
			return Array(value as PackedStringArray)
		TYPE_DICTIONARY:
			return json_fields(value as Dictionary)
		_:
			return str(value)


## Every field, with keys as strings and values JSON-safe.
static func json_fields(fields: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k: Variant in fields:
		out[str(k)] = json_value(fields[k])
	return out


## The event as one flat [Dictionary], which is what a generic JSON collector wants.
##
## Context tags are written first so a field can never shadow one: a log line carrying
## its own [code]service[/code] would otherwise repoint that record at a different
## service in every dashboard built on that label.
static func flatten(
	event: Dictionary, context: Dictionary = {}, field_prefix: String = ""
) -> Dictionary:
	var out: Dictionary = {}

	for k: Variant in context:
		out[str(k)] = json_value(context[k])

	out["time"] = iso8601(event)
	out["level"] = String(event.get("severity", "info"))
	out["channel"] = String(event.get("channel", ""))
	out["message"] = String(event.get("message", ""))
	out["seq"] = int(event.get("seq", 0))

	var fields: Dictionary = event.get("fields", {})
	for k: Variant in fields:
		out[field_prefix + str(k)] = json_value(fields[k])

	return out


## [method flatten], encoded. The NDJSON line every generic collector understands.
static func flatten_json(
	event: Dictionary, context: Dictionary = {}, field_prefix: String = ""
) -> String:
	return JSON.stringify(flatten(event, context, field_prefix))


## The human line: what an admin reads over SSH, and what a file target writes.
static func text_line(event: Dictionary, with_time: bool = true) -> String:
	var parts: PackedStringArray = PackedStringArray()
	if with_time:
		parts.append(iso8601(event))
	parts.append(DotLog.LEVEL_TAGS[clampi(int(event.get("level", 2)), 0, 6)])

	var channel: String = String(event.get("channel", ""))
	if channel != "":
		parts.append("%-8s" % channel)

	parts.append(String(event.get("message", "")))

	var fields: Dictionary = event.get("fields", {})
	if not fields.is_empty():
		parts.append(DotLog.format_fields(fields))

	return " ".join(parts)


## A stable identity for "the same line again", for deduplication.
##
## The level, channel and message, never the fields: a line that repeats with a
## different player id every time is still the same line, and a key including the fields
## would suppress nothing at all in exactly the flood it exists to survive.
static func repeat_key(event: Dictionary) -> String:
	return "%d %s %s" % [
		int(event.get("level", 2)),
		String(event.get("channel", "")),
		String(event.get("message", "")),
	]
