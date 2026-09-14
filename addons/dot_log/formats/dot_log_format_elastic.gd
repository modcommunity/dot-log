@tool
class_name DotLogFormatElastic
extends DotLogFormat

## Elasticsearch and OpenSearch, through the bulk API.
##
## [b]The reason this format has a real [method interpret]: the bulk API answers 200 when
## it has rejected everything.[/b] The status code reports that the request was
## understood, not that the documents were indexed; the per-document outcomes are in the
## body, behind an [code]errors[/code] flag. A shipper that checks the status code and
## moves on will drop every record from the moment a mapping conflict appears — one field
## that arrived as a string where the index expects a number is enough — and will keep
## reporting itself healthy while it does. That is the failure this file exists to notice.
##
## Field names are prefixed by default for the same reason. Elasticsearch infers a type
## per field on first sight and enforces it afterwards, so an addon that logs
## [code]count[/code] as an int and another that logs it as "many" put the index into a
## state where one of them is silently unindexable. A prefix does not fix it; it contains
## it, and it makes the fields obviously ours.

## Index to write to. A date pattern is expanded: [code]%Y[/code], [code]%m[/code],
## [code]%d[/code] — so [code]dot-logs-%Y.%m.%d[/code] gives a daily index, which is how
## retention is done here (drop the old index; deleting rows is far more expensive).
@export var index: String = "dot-logs-%Y.%m.%d"

## Use a data stream instead of an index.
##
## A data stream only accepts [code]create[/code], never [code]index[/code], and rejects
## the whole request otherwise. It is also the modern default for append-only data,
## which a log is.
@export var data_stream: bool = false

## Basic-auth user. Leave empty and set [member token] to use an API key instead.
@export var username: String = ""

## Prefix for field names. See the note above about mapping conflicts.
@export var field_prefix: String = "f_"


func format_name() -> String:
	return "elasticsearch"


func content_type() -> String:
	# Not application/json: the bulk endpoint refuses anything else, and the error it
	# gives says "Content-Type header [application/json] is not supported", which at
	# least is one of the clearer ones.
	return "application/x-ndjson"


func default_path() -> String:
	return "/_bulk"


func headers() -> Dictionary:
	var out: Dictionary = super()
	if token != "":
		if username != "":
			out["Authorization"] = "Basic " + Marshalls.utf8_to_base64(
				username + ":" + token
			)
		else:
			out["Authorization"] = "ApiKey " + token
	return out


func build(events: Array, context: Dictionary) -> PackedByteArray:
	var target: String = resolved_index()
	var action: String = "create" if data_stream else "index"

	var lines: PackedStringArray = PackedStringArray()
	for event: Dictionary in events:
		lines.append(JSON.stringify({action: {"_index": target}}))
		lines.append(JSON.stringify(_document(event, context)))

	# The trailing newline is required, not cosmetic: without it the last document is
	# not seen and the request succeeds having indexed one fewer than it was given.
	return ("\n".join(lines) + "\n").to_utf8_buffer()


func _document(event: Dictionary, context: Dictionary) -> Dictionary:
	var doc: Dictionary = {
		# The Elastic Common Schema names, so the stock dashboards work unmodified.
		"@timestamp": DotLogEvent.iso8601(event),
		"log": {"level": String(event.get("severity", "info"))},
		"message": String(event.get("message", "")),
		"event": {"dataset": String(event.get("channel", ""))},
	}

	for k: Variant in context:
		doc[str(k)] = DotLogEvent.json_value(context[k])

	var fields: Dictionary = event.get("fields", {})
	for k: Variant in fields:
		doc[field_prefix + str(k)] = DotLogEvent.json_value(fields[k])

	return doc


## The index name with any date pattern expanded, in UTC.
func resolved_index() -> String:
	if not index.contains("%"):
		return index

	var now: Dictionary = Time.get_datetime_dict_from_system(true)
	return (
		index
		.replace("%Y", "%04d" % int(now["year"]))
		.replace("%m", "%02d" % int(now["month"]))
		.replace("%d", "%02d" % int(now["day"]))
	)


func max_batch() -> int:
	return 500


func max_bytes() -> int:
	# Elasticsearch's default http.max_content_length is 100 MB, but a bulk request is
	# recommended to stay a few megabytes; past that the coordinating node buffers the
	# whole thing and the request times out rather than failing cleanly.
	return 5 * 1024 * 1024


func interpret(response: Dictionary) -> DotResult:
	var status: int = int(response.get("status", 0))
	if status < 200 or status >= 300:
		return DotResult.failure(
			DotError.from_http(status, String(response.get("body_text", "")))
		)

	var body: Variant = response.get("body_text", "")
	var parsed: Variant = JSON.parse_string(String(body))
	if typeof(parsed) != TYPE_DICTIONARY:
		# A 200 whose body is not the bulk response means something in front of
		# Elasticsearch answered — a proxy, a login page. Treated as a failure, because
		# nothing was indexed.
		return DotResult.fail(
			DotError.CODE_PARSE,
			"The bulk response was not JSON.",
			String(body).substr(0, 256)
		)

	var doc: Dictionary = parsed as Dictionary
	if not bool(doc.get("errors", false)):
		return DotResult.success(int(doc.get("took", 0)))

	# At least one document was rejected. The first reason is worth more than the count:
	# they are nearly always all the same mapping conflict.
	var first_reason: String = ""
	var rejected: int = 0
	var items: Array = doc.get("items", [])
	for item: Variant in items:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		for op: Variant in (item as Dictionary):
			var outcome: Dictionary = (item as Dictionary)[op]
			if int(outcome.get("status", 200)) < 300:
				continue
			rejected += 1
			if first_reason == "":
				var err: Dictionary = outcome.get("error", {})
				first_reason = "%s: %s" % [
					str(err.get("type", "?")), str(err.get("reason", "?"))
				]

	return DotResult.fail(
		DotError.CODE_INVALID,
		"Elasticsearch rejected %d of %d documents." % [rejected, items.size()],
		first_reason
	)
