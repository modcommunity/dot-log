@tool
class_name DotLogFormatDatadog
extends DotLogFormat

## Datadog's log intake.
## A JSON array, the key in [code]DD-API-KEY[/code], and reserved attributes [code]ddsource[/code], [code]service[/code], [code]ddtags[/code] (a comma string) and [code]status[/code] (a name it knows).
## The region is part of the endpoint, so the base URL is configuration with no default.

## The [code]ddsource[/code] attribute. Deliberately not a known integration name.
@export var ddsource: String = "dot"

## The [code]service[/code] attribute. Overridden by a `service` in the router context.
@export var service: String = "dot-server"

## Fixed tags, as [code]key: value[/code]. Joined into ddtags with the context.
@export var tags: Dictionary = {}


func format_name() -> String:
	return "datadog"


func default_path() -> String:
	return "/api/v2/logs"


func headers() -> Dictionary:
	var out: Dictionary = super()
	if token != "":
		out["DD-API-KEY"] = token
	return out


func build(events: Array, context: Dictionary) -> PackedByteArray:
	var rows: Array = []

	for event: Dictionary in events:
		var row: Dictionary = {
			"ddsource": ddsource,
			"service": str(context.get("service", service)),
			"ddtags": _tags_for(event, context),
			"status": _status_for(int(event.get("level", DotLog.Level.INFO))),
			"message": String(event.get("message", "")),
			"channel": String(event.get("channel", "")),
			"timestamp": DotLogEvent.time_ms(event),
		}

		if context.has("host"):
			row["hostname"] = str(context["host"])

		var fields: Dictionary = event.get("fields", {})
		for k: Variant in fields:
			row[str(k)] = DotLogEvent.json_value(fields[k])

		rows.append(row)

	return JSON.stringify(rows).to_utf8_buffer()


func _tags_for(event: Dictionary, context: Dictionary) -> String:
	var parts: PackedStringArray = PackedStringArray()

	for k: Variant in tags:
		parts.append("%s:%s" % [str(k), str(tags[k])])

	for k: Variant in context:
		if str(k) == "service" or str(k) == "host":
			continue  # both are reserved attributes above, and duplicating them is noise
		parts.append("%s:%s" % [str(k), str(context[k])])

	var channel: String = String(event.get("channel", ""))
	if channel != "":
		parts.append("channel:" + channel)

	return ",".join(parts)


## Datadog's own level names. Anything else is read as `info`, silently.
static func _status_for(level: int) -> String:
	match level:
		DotLog.Level.TRACE, DotLog.Level.DEBUG:
			return "debug"
		DotLog.Level.WARN:
			return "warning"
		DotLog.Level.ERROR:
			return "error"
		DotLog.Level.FATAL:
			return "critical"
		_:
			return "info"


func max_batch() -> int:
	# The documented limit is 1000 logs per request.
	return 1000


func max_bytes() -> int:
	# 5 MB uncompressed per request, and 1 MB per individual log. The per-record limit
	# is not enforced here: a single log line over a megabyte is a bug upstream, and
	# truncating it would hide that bug rather than report it.
	return 5 * 1024 * 1024


func interpret(response: Dictionary) -> DotResult:
	var status: int = int(response.get("status", 0))
	if status >= 200 and status < 300:
		return DotResult.success(null)

	if status == 403:
		return DotResult.fail(
			DotError.CODE_AUTH,
			"The log intake refused the API key.",
			"a key from another region's account gets this, too"
		)

	return DotResult.failure(
		DotError.from_http(status, String(response.get("body_text", "")))
	)
