@tool
class_name DotLogFormatLoki
extends DotLogFormat

## Grafana Loki's push API.
##
## Loki indexes labels and not content, which makes it cheap to run and makes exactly one
## thing your problem: [b]label cardinality[/b]. Every distinct combination of label
## values is a separate stream with its own index entry and its own set of chunks, so a
## label carrying a player id, a match id or a position turns one stream into a hundred
## thousand and takes the ingester down. This is not a tuning detail — it is the way
## people break Loki, and it is why the labels here are a fixed, short list and every
## other field goes into the line.
##
## So: service, environment, host, level and channel are labels. Everything else is in
## the JSON of the line, where Loki's query language can still filter on it with
## [code]| json | key="value"[/code] — a little slower to query, and incapable of taking
## the cluster down.

## Labels taken from the router context, if present. Kept short on purpose.
const CONTEXT_LABELS: Array[String] = ["service", "env", "host", "instance"]

## Send the channel as a label.
##
## On: a channel is bounded by the number of subsystems, which is about fifty, and
## filtering by subsystem is the query people actually run.
@export var label_channel: bool = true

## Send the level as a label. On, for the same reason: six values, constantly filtered.
@export var label_level: bool = true

## Extra fixed labels, for a deployment that sorts its servers by region or by game.
@export var static_labels: Dictionary = {}

## The tenant, sent as [code]X-Scope-OrgID[/code]. Empty for a single-tenant Loki.
@export var tenant: String = ""

## Basic-auth user. Grafana Cloud uses the numeric instance id here and an access token
## as the password, which is [member token].
@export var username: String = ""


func format_name() -> String:
	return "loki"


func default_path() -> String:
	return "/loki/api/v1/push"


func headers() -> Dictionary:
	var out: Dictionary = super()
	if tenant != "":
		out["X-Scope-OrgID"] = tenant
	if token != "":
		if username != "":
			out["Authorization"] = "Basic " + Marshalls.utf8_to_base64(
				username + ":" + token
			)
		else:
			out["Authorization"] = "Bearer " + token
	return out


func build(events: Array, context: Dictionary) -> PackedByteArray:
	# Grouped by label set, because one stream per record is precisely the cardinality
	# mistake described above — and because Loki requires the entries within a stream to
	# be in timestamp order, which is only cheap if they were grouped in order.
	var streams: Dictionary = {}

	for event: Dictionary in events:
		var labels: Dictionary = _labels_for(event, context)
		var key: String = JSON.stringify(labels)

		if not streams.has(key):
			streams[key] = {"stream": labels, "values": []}

		var entry: Array = [
			DotLogEvent.time_ns(event),
			_line_for(event),
		]
		(streams[key]["values"] as Array).append(entry)

	var payload: Array = []
	for key: Variant in streams:
		payload.append(streams[key])

	return JSON.stringify({"streams": payload}).to_utf8_buffer()


func _labels_for(event: Dictionary, context: Dictionary) -> Dictionary:
	var labels: Dictionary = {}

	for name: String in CONTEXT_LABELS:
		if context.has(name):
			labels[name] = str(context[name])

	for k: Variant in static_labels:
		labels[_label_name(str(k))] = str(static_labels[k])

	if label_level:
		labels["level"] = String(event.get("severity", "info"))

	if label_channel:
		var channel: String = String(event.get("channel", ""))
		if channel != "":
			labels["channel"] = _label_name(channel)

	return labels


## A Loki label name must be a Prometheus identifier: letters, digits and underscores,
## not starting with a digit. A channel called `player.roster` is legal here and not
## there, and Loki rejects the whole push rather than the one label.
static func _label_name(name: String) -> String:
	var out: String = ""
	for i: int in range(name.length()):
		var c: String = name[i]
		if c.is_valid_identifier() or (c >= "0" and c <= "9"):
			out += c
		else:
			out += "_"
	if out == "" or (out[0] >= "0" and out[0] <= "9"):
		out = "_" + out
	return out


func _line_for(event: Dictionary) -> String:
	# The message first and the fields after it, as JSON: readable in the log panel
	# without expanding anything, and still parseable by `| json`.
	var body: Dictionary = {"message": String(event.get("message", ""))}
	var fields: Dictionary = event.get("fields", {})
	for k: Variant in fields:
		body[str(k)] = DotLogEvent.json_value(fields[k])
	return JSON.stringify(body)


func max_batch() -> int:
	return 1000


func max_bytes() -> int:
	# Loki's default server limit on a push body. Larger is a 413, which is not
	# retryable and would otherwise loop forever.
	return 4 * 1024 * 1024


func interpret(response: Dictionary) -> DotResult:
	var status: int = int(response.get("status", 0))
	if status == 204 or (status >= 200 and status < 300):
		return DotResult.success(null)

	if status == 400:
		# Loki's 400s are structural — a bad label, entries out of order, a stream too
		# far in the past. Retrying an identical body cannot fix any of them, so this
		# is reported as invalid rather than as a network problem, and the target drops
		# the batch instead of blocking the queue behind it forever.
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Loki refused the batch.",
			String(response.get("body_text", "")).substr(0, 512)
		)

	return DotResult.failure(
		DotError.from_http(status, String(response.get("body_text", "")))
	)
