@tool
class_name DotLogFormatSeq
extends DotLogFormat

## Seq, in the compact log event format (CLEF).
##
## Worth knowing about specifically because [b]it is the one on this list a community can
## self-host in an afternoon[/b]: one container, a web UI that is actually pleasant, and
## no account. For a game with a handful of servers it is very often the right answer,
## and it is the one to reach for before signing up to anything.
##
## CLEF is newline-delimited JSON with reserved keys that begin with [code]@[/code]:
##
## - [code]@t[/code] the timestamp, ISO 8601.
## - [code]@l[/code] the level, by name. Absent means Information, which is why an
##   info-level record here does not send the key at all.
## - [code]@m[/code] a rendered message, or [code]@mt[/code] a message [i]template[/i]
##   with [code]{named}[/code] holes.
## - [code]@x[/code] an exception or stack trace.
##
## [b]The template is the interesting part, and this format uses it deliberately.[/b] Seq
## groups events by their template, so "player connected" arriving four thousand times is
## one group with four thousand members rather than four thousand unrelated lines — and
## every field stays individually queryable. Which is exactly the shape [DotLog] records
## already have: a constant message and a dictionary of fields. The two designs agree,
## so nothing has to be reconstructed by parsing.

## Seq's level names, which are its own.
const SEQ_LEVELS: Array[String] = [
	"Verbose", "Debug", "Information", "Warning", "Error", "Fatal", "Information",
]

## Send the message as a template with the fields appended as named holes.
##
## On, for the grouping described above. Off sends a rendered message, which is right
## if the messages are already unique per event.
@export var use_template: bool = true


func format_name() -> String:
	return "seq"


func content_type() -> String:
	return "application/vnd.serilog.clef"


func default_path() -> String:
	return "/ingest/clef"


func headers() -> Dictionary:
	var out: Dictionary = super()
	if token != "":
		out["X-Seq-ApiKey"] = token
	return out


func build(events: Array, context: Dictionary) -> PackedByteArray:
	var lines: PackedStringArray = PackedStringArray()

	for event: Dictionary in events:
		var row: Dictionary = {"@t": DotLogEvent.iso8601(event)}

		var level: int = int(event.get("level", DotLog.Level.INFO))
		if level != DotLog.Level.INFO:
			# Information is CLEF's default and sending it is redundant. Not a
			# micro-optimisation: it is how the format is specified, and a reader that
			# treats an explicit level differently from an absent one does exist.
			row["@l"] = SEQ_LEVELS[clampi(level, 0, SEQ_LEVELS.size() - 1)]

		var fields: Dictionary = event.get("fields", {})

		if use_template and not fields.is_empty():
			row["@mt"] = _template_for(String(event.get("message", "")), fields)
		else:
			row["@m"] = String(event.get("message", ""))

		row["Channel"] = String(event.get("channel", ""))

		for k: Variant in context:
			row[_property_name(str(k))] = DotLogEvent.json_value(context[k])

		for k: Variant in fields:
			row[_property_name(str(k))] = DotLogEvent.json_value(fields[k])

		lines.append(JSON.stringify(row))

	return ("\n".join(lines) + "\n").to_utf8_buffer()


## The message with one [code]{Field}[/code] hole appended per field.
##
## Appended rather than substituted: a [DotLog] message is prose written for a console
## and does not contain holes, so the only honest way to make it a template is to state
## the fields after it. The result renders as
## [code]player connected (Peer: 4, Name: "Ada")[/code] and groups on the prose.
func _template_for(message: String, fields: Dictionary) -> String:
	var holes: PackedStringArray = PackedStringArray()
	for k: Variant in fields:
		var name: String = _property_name(str(k))
		holes.append("%s: {%s}" % [name, name])
	if holes.is_empty():
		return message
	return "%s (%s)" % [message, ", ".join(holes)]


## A CLEF property name may not begin with [code]@[/code] — that prefix is reserved for
## the format's own keys, and a field called [code]@t[/code] would overwrite the
## timestamp of the record carrying it.
static func _property_name(name: String) -> String:
	var out: String = name
	while out.begins_with("@"):
		out = out.substr(1)
	out = out.replace("{", "").replace("}", "").replace(" ", "_")
	return out if out != "" else "field"


func max_batch() -> int:
	return 1000


func max_bytes() -> int:
	# Seq's default ingestion payload limit is 10 MB, and its default single-event
	# limit is 256 KB.
	return 8 * 1024 * 1024


func interpret(response: Dictionary) -> DotResult:
	var status: int = int(response.get("status", 0))
	if status >= 200 and status < 300:
		return DotResult.success(null)

	if status == 400:
		# Seq answers 400 with the offending line's index, which is worth keeping: it
		# is nearly always one record with a field the ingestion rules reject.
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Seq refused the batch.",
			String(response.get("body_text", "")).substr(0, 512)
		)

	return DotResult.failure(
		DotError.from_http(status, String(response.get("body_text", "")))
	)
