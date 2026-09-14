@tool
class_name DotLogFormatSplunk
extends DotLogFormat

## Splunk's HTTP Event Collector.
##
## Two details that are easy to get wrong and fail unhelpfully:
##
## - [b]The credential is not a bearer token.[/b] The header is
##   [code]Authorization: Splunk <token>[/code], and sending [code]Bearer[/code] gets a
##   401 whose body says "Token is required" — which reads as a missing token rather
##   than a misspelled scheme.
## - [b]The body is concatenated JSON objects, not an array and not NDJSON.[/b] One
##   object after another, with nothing between them. An array is rejected outright;
##   newlines are tolerated, which is why the newlines here are for human legibility
##   and nothing else.
##
## The event time is seconds with a fractional part, not milliseconds. Sending
## milliseconds is accepted and indexes every record in the year 56000, which is a
## memorable way to find out.

## The index to write to. Empty uses whatever the token's default is.
@export var splunk_index: String = ""

## The [code]source[/code] field, conventionally the thing that produced the record.
@export var source: String = "dot-server"

## The [code]sourcetype[/code], which is what Splunk's field extraction keys off.
##
## [code]_json[/code] is the built-in that parses the event object's fields without any
## configuration at the Splunk end, which is what makes this work unattended.
@export var sourcetype: String = "_json"


func format_name() -> String:
	return "splunk"


func default_path() -> String:
	return "/services/collector/event"


func headers() -> Dictionary:
	var out: Dictionary = super()
	if token != "":
		out["Authorization"] = "Splunk " + token
	return out


func build(events: Array, context: Dictionary) -> PackedByteArray:
	var chunks: PackedStringArray = PackedStringArray()

	for event: Dictionary in events:
		var envelope: Dictionary = {
			"time": DotLogEvent.time_sec(event),
			"source": source,
			"sourcetype": sourcetype,
			"event": _event_body(event, context),
		}

		if splunk_index != "":
			envelope["index"] = splunk_index
		if context.has("host"):
			envelope["host"] = str(context["host"])

		chunks.append(JSON.stringify(envelope))

	return "\n".join(chunks).to_utf8_buffer()


func _event_body(event: Dictionary, context: Dictionary) -> Dictionary:
	var body: Dictionary = {
		"level": String(event.get("severity", "info")),
		"channel": String(event.get("channel", "")),
		"message": String(event.get("message", "")),
	}

	for k: Variant in context:
		if str(k) == "host":
			continue  # already in the envelope, where Splunk indexes it
		body[str(k)] = DotLogEvent.json_value(context[k])

	var fields: Dictionary = event.get("fields", {})
	for k: Variant in fields:
		body[str(k)] = DotLogEvent.json_value(fields[k])

	return body


func max_batch() -> int:
	return 500


func max_bytes() -> int:
	# HEC's default max_content_length is 800 MB, but the useful limit is the one that
	# keeps a retry cheap on a game server's uplink.
	return 4 * 1024 * 1024


func interpret(response: Dictionary) -> DotResult:
	var status: int = int(response.get("status", 0))
	var text: String = String(response.get("body_text", ""))

	if status >= 200 and status < 300:
		# HEC answers {"text":"Success","code":0}. A non-zero code with a 200 happens
		# when only some events were parsed, and it is worth surfacing rather than
		# counting as delivery.
		var parsed: Variant = JSON.parse_string(text)
		if typeof(parsed) == TYPE_DICTIONARY:
			var code: int = int((parsed as Dictionary).get("code", 0))
			if code != 0:
				return DotResult.fail(
					DotError.CODE_INVALID,
					"The event collector reported code %d." % code,
					str((parsed as Dictionary).get("text", ""))
				)
		return DotResult.success(null)

	if status == 403 or status == 401:
		return DotResult.fail(
			DotError.CODE_AUTH,
			"The event collector refused the token.",
			"check the token and that `Authorization: Splunk` is the scheme in use"
		)

	return DotResult.failure(DotError.from_http(status, text))
