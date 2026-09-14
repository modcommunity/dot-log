@tool
class_name DotLogFormatGelf
extends DotLogFormat

## GELF, the Graylog Extended Log Format, over HTTP.
##
## GELF exists because plain syslog truncates at 1 KB and has nowhere to put structured
## data that a receiver will reliably parse. It keeps syslog's severity numbers and adds
## arbitrary typed fields, which makes it the natural step up for a deployment that
## already forwards syslog and has outgrown it.
##
## Four rules the spec is strict about, each of which fails quietly:
##
## - [b]Every custom field must begin with an underscore.[/b] One that does not is
##   dropped by the receiver, not rejected — so the record arrives looking fine with the
##   field missing.
## - [b][code]_id[/code] is forbidden[/b], because Graylog uses it internally. A message
##   carrying one is rejected outright.
## - [b][code]short_message[/code] is required[/b] and may not be empty.
## - [b][code]timestamp[/code] is seconds with a fractional part[/b], not milliseconds.
##
## Over HTTP the transport is one JSON object per request, or newline-delimited objects
## for a bulk endpoint. UDP GELF with its own chunking is deliberately not implemented:
## chunked UDP reassembly is where GELF's implementation bugs live, and a deployment that
## wants datagrams is better served by [DotLogTargetSyslog].

## Send newline-delimited objects instead of one object per request.
##
## Graylog's HTTP input accepts a batch this way. A receiver that does not will answer
## 400 on the second line, which is the tell.
@export var bulk: bool = true

## The [code]host[/code] field, which GELF requires. Empty takes it from the router
## context, and failing that from the environment.
@export var source_host: String = ""

## Include the full message as well as the short one.
##
## [code]full_message[/code] is where a stack trace goes. Off unless a record has
## something long to say, because duplicating every line into both is pure storage cost.
@export var include_full_message: bool = false


func format_name() -> String:
	return "gelf"


func content_type() -> String:
	return "application/json"


func default_path() -> String:
	return "/gelf"


func headers() -> Dictionary:
	var out: Dictionary = super()
	if token != "":
		out["Authorization"] = "Bearer " + token
	return out


func build(events: Array, context: Dictionary) -> PackedByteArray:
	var lines: PackedStringArray = PackedStringArray()

	for event: Dictionary in events:
		lines.append(JSON.stringify(message_for(event, context)))

	if bulk:
		return ("\n".join(lines) + "\n").to_utf8_buffer()

	# Not a batch: only the first is sent, and the target's max_batch keeps it to one.
	return (lines[0] if not lines.is_empty() else "").to_utf8_buffer()


## One GELF message.
func message_for(event: Dictionary, context: Dictionary) -> Dictionary:
	var message: String = String(event.get("message", ""))
	if message == "":
		# short_message may not be empty, and a receiver that rejects the message tells
		# you far less than a placeholder does.
		message = "(no message)"

	var out: Dictionary = {
		"version": "1.1",
		"host": _host_for(context),
		"short_message": message,
		"timestamp": DotLogEvent.time_sec(event),
		"level": DotLogEvent.syslog_severity(int(event.get("level", DotLog.Level.INFO))),
		"_channel": String(event.get("channel", "")),
		"_level_name": String(event.get("severity", "info")),
	}

	if include_full_message:
		out["full_message"] = DotLogEvent.text_line(event)

	for k: Variant in context:
		if str(k) == "host":
			continue
		out[_field_name(str(k))] = DotLogEvent.json_value(context[k])

	var fields: Dictionary = event.get("fields", {})
	for k: Variant in fields:
		out[_field_name(str(k))] = DotLogEvent.json_value(fields[k])

	return out


func _host_for(context: Dictionary) -> String:
	if source_host != "":
		return source_host
	if context.has("host"):
		return str(context["host"])
	var env_host: String = OS.get_environment("HOSTNAME")
	return env_host if env_host != "" else "unknown"


## An underscore prefix, and never [code]_id[/code].
static func _field_name(name: String) -> String:
	var clean: String = name
	while clean.begins_with("_"):
		clean = clean.substr(1)
	if clean == "" or clean == "id":
		# `_id` is reserved and rejects the whole message; renaming it is better than
		# dropping the field and far better than dropping the record.
		clean = "field_id" if clean == "id" else "field"
	return "_" + clean


func max_batch() -> int:
	return 500 if bulk else 1


func max_bytes() -> int:
	return 4 * 1024 * 1024


func interpret(response: Dictionary) -> DotResult:
	var status: int = int(response.get("status", 0))
	if status >= 200 and status < 300:
		return DotResult.success(null)

	if status == 400:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"The GELF input refused the message.",
			"a missing short_message or a reserved field name will do this: "
			+ String(response.get("body_text", "")).substr(0, 256)
		)

	return DotResult.failure(
		DotError.from_http(status, String(response.get("body_text", "")))
	)
