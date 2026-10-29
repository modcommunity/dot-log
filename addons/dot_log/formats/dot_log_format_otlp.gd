@tool
class_name DotLogFormatOtlp
extends DotLogFormat

## OpenTelemetry logs over OTLP/HTTP with a JSON body (Godot has no protobuf).
## Point at an OpenTelemetry Collector to fan out. Spec rules: 64-bit numbers are strings, and every attribute value is a tagged union such as [code]{"stringValue": "x"}[/code].
## Resource attributes carry the router context, once per batch.

## The [code]service.name[/code] resource attribute. Overridden by the router context.
## A collector with no service name groups everything under [code]unknown_service[/code].
@export var service_name: String = "dot-server"

## The instrumentation scope name, which is how a backend tells our records from the ones
## an agent on the same host produced.
@export var scope_name: String = "dot-log"

## Send [member token] as a bearer credential. Some collectors want a different header;
## put it in [member extra_headers] instead.
@export var bearer: bool = true


func format_name() -> String:
	return "otlp"


func default_path() -> String:
	return "/v1/logs"


func headers() -> Dictionary:
	var out: Dictionary = super()
	if bearer and token != "":
		out["Authorization"] = "Bearer " + token
	return out


func build(events: Array, context: Dictionary) -> PackedByteArray:
	var records: Array = []
	for event: Dictionary in events:
		records.append(_record(event))

	return JSON.stringify({
		"resourceLogs": [{
			"resource": {"attributes": _resource_attributes(context)},
			"scopeLogs": [{
				"scope": {"name": scope_name, "version": "0.1.0"},
				"logRecords": records,
			}],
		}],
	}).to_utf8_buffer()


func _record(event: Dictionary) -> Dictionary:
	var level: int = int(event.get("level", DotLog.Level.INFO))
	var nanos: String = DotLogEvent.time_ns(event)

	var attributes: Array = []

	var channel: String = String(event.get("channel", ""))
	if channel != "":
		# The conventional attribute for "which logger emitted this".
		attributes.append(attribute("log.channel", channel))

	var fields: Dictionary = event.get("fields", {})
	for k: Variant in fields:
		attributes.append(attribute(str(k), fields[k]))

	return {
		"timeUnixNano": nanos,
		# Set to the same value: we observe a record at the instant it is emitted, and
		# a collector that sees no observedTimeUnixNano stamps its own arrival time,
		# which for a batched shipper is up to a flush interval wrong.
		"observedTimeUnixNano": nanos,
		"severityNumber": DotLogEvent.otlp_severity(level),
		"severityText": String(event.get("level_name", "INFO")),
		"body": {"stringValue": String(event.get("message", ""))},
		"attributes": attributes,
	}


func _resource_attributes(context: Dictionary) -> Array:
	var out: Array = []
	var named: bool = false

	for k: Variant in context:
		var key: String = str(k)
		match key:
			"service":
				out.append(attribute("service.name", context[k]))
				named = true
			"env":
				out.append(attribute("deployment.environment.name", context[k]))
			"host":
				out.append(attribute("host.name", context[k]))
			"instance":
				out.append(attribute("service.instance.id", context[k]))
			"version":
				out.append(attribute("service.version", context[k]))
			_:
				out.append(attribute(key, context[k]))

	if not named:
		out.append(attribute("service.name", service_name))

	return out


## One attribute, as OTLP's tagged union.
static func attribute(key: String, value: Variant) -> Dictionary:
	return {"key": key, "value": any_value(value)}


## OTLP's AnyValue. Integers are strings, because they are 64-bit on the wire.
static func any_value(value: Variant) -> Dictionary:
	match typeof(value):
		TYPE_BOOL:
			return {"boolValue": value}
		TYPE_INT:
			return {"intValue": str(value)}
		TYPE_FLOAT:
			return {"doubleValue": value}
		TYPE_ARRAY:
			var items: Array = []
			for v: Variant in (value as Array):
				items.append(any_value(v))
			return {"arrayValue": {"values": items}}
		TYPE_DICTIONARY:
			var pairs: Array = []
			for k: Variant in (value as Dictionary):
				pairs.append(attribute(str(k), (value as Dictionary)[k]))
			return {"kvlistValue": {"values": pairs}}
		_:
			return {"stringValue": str(value)}


func max_batch() -> int:
	return 512


func max_bytes() -> int:
	# The collector's default receiver limit is 4 MiB for the HTTP receiver.
	return 4 * 1024 * 1024


func interpret(response: Dictionary) -> DotResult:
	var status: int = int(response.get("status", 0))

	if status >= 200 and status < 300:
		# A partial success is a 200 with a body naming how many records were rejected.
		# Reported, not retried: the same bytes would be rejected again.
		var parsed: Variant = JSON.parse_string(String(response.get("body_text", "")))
		if typeof(parsed) == TYPE_DICTIONARY:
			var partial: Variant = (parsed as Dictionary).get("partialSuccess", null)
			if typeof(partial) == TYPE_DICTIONARY:
				var rejected: int = int((partial as Dictionary).get(
					"rejectedLogRecords", 0
				))
				if rejected > 0:
					return DotResult.fail(
						DotError.CODE_INVALID,
						"The collector rejected %d records." % rejected,
						str((partial as Dictionary).get("errorMessage", ""))
					)
		return DotResult.success(null)

	return DotResult.failure(
		DotError.from_http(status, String(response.get("body_text", "")))
	)
