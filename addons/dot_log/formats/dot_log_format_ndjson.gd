@tool
class_name DotLogFormatNdjson
extends DotLogFormat

## One JSON object per line: the format everything that is not a hosted service accepts.
##
## This is the one to reach for first. A log shipper running beside the server, a
## collector agent, an HTTP input on a log pipeline, a webhook into a chat room, a
## handler somebody wrote in an afternoon — all of them take newline-delimited JSON, and
## none of them need a vendor's envelope. It is also the format to test against, because
## a failure is readable with [code]tail[/code] rather than with a decoder.
##
## The authentication is whatever the receiver wants: set [member bearer] for
## [code]Authorization: Bearer[/code], or put the header in [member extra_headers].

## Send a JSON array instead of newline-delimited objects.
##
## Some receivers want one; most want the lines. Both are one flag apart and getting it
## wrong produces a 400 with no explanation, which is a slow thing to diagnose.
@export var as_array: bool = false

## Whether to send [member token] as a bearer credential.
@export var bearer: bool = true

## Prefix for field names, so a field cannot collide with an envelope key.
@export var field_prefix: String = ""


func format_name() -> String:
	return "ndjson"


func content_type() -> String:
	return "application/json" if as_array else "application/x-ndjson"


func headers() -> Dictionary:
	var out: Dictionary = super()
	if bearer and token != "":
		out["Authorization"] = "Bearer " + token
	return out


func build(events: Array, context: Dictionary) -> PackedByteArray:
	if as_array:
		var rows: Array = []
		for event: Dictionary in events:
			rows.append(DotLogEvent.flatten(event, context, field_prefix))
		return JSON.stringify(rows).to_utf8_buffer()

	var lines: PackedStringArray = PackedStringArray()
	for event: Dictionary in events:
		lines.append(DotLogEvent.flatten_json(event, context, field_prefix))

	# A trailing newline, not a separator: a receiver reading line by line needs the
	# last record terminated, and one that splits on newlines ignores the empty tail.
	return ("\n".join(lines) + "\n").to_utf8_buffer()


func max_batch() -> int:
	return 1000
