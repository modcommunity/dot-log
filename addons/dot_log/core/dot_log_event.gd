class_name DotLogEvent
extends RefCounted

## One log record, on its way out of the process.
## Converts [DotLog]'s record into a shippable event (wall-clock time, stable order, JSON-safe values).
## Static, and nothing here mutates the record: sinks share one [Dictionary].

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
## An offset rather than a clock read per record: monotonic ordering cannot invert when NTP steps the clock. Absolute time drifts with the host instead.
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
## Never automatic: a resync moves every later timestamp by the drift in one step.
static func resync_clock() -> void:
	_epoch_ready = false
	_ensure_epoch()


## Turns a [DotLog] record into a shippable event.
## Adds [code]time_ms[/code], [code]seq[/code] and [code]severity[/code]; everything else arrives unchanged.
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
## Used for repeat summaries and drop notices, which must not go back through [DotLog].
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


static func time_ms(event: Dictionary) -> int:
	return int(event.get("time_ms", 0))


## Unix nanoseconds, as a string.
## A string because 1.8e18 fits an int64 but not the double most JSON parsers use; Loki and OTLP specify a string.
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


## Coerces a value into something [method JSON.stringify] renders faithfully.
## JSON.stringify silently mangles a Vector3, Node or Callable, so anything that is not a JSON scalar is rendered with [method str].
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
## Context tags are written first so a field can never shadow one (a field named [code]service[/code] would repoint the record).
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
	# level_column, not LEVEL_TAGS: the level is always printed, and how wide it is
	# printed is DotLog's decision so that every line in a process matches.
	parts.append(DotLog.level_column(clampi(int(event.get("level", 2)), 0, 6)))

	var channel: String = String(event.get("channel", ""))
	if channel != "":
		parts.append("%-8s" % channel)

	parts.append(String(event.get("message", "")))

	var fields: Dictionary = event.get("fields", {})
	if not fields.is_empty():
		parts.append(DotLog.format_fields(fields))

	return " ".join(parts)


## A stable identity for "the same line again", for deduplication.
## Level, channel and message, never the fields: a varying player id would otherwise defeat dedupe in the flood it exists for.
static func repeat_key(event: Dictionary) -> String:
	return "%d %s %s" % [
		int(event.get("level", 2)),
		String(event.get("channel", "")),
		String(event.get("message", "")),
	]
