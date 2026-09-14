@tool
class_name DotLogFormatSentry
extends DotLogFormat

## Sentry, as envelopes of events.
##
## [b]This one is not a log collector and must not be configured like one.[/b] An error
## tracker groups events into issues, counts how often each happens, and tells somebody.
## Send it a hundred thousand INFO lines and you have paid for a search engine that is
## much worse at searching than the others here — and buried the eleven crashes it exists
## to show you. So [method is_error_tracker] is true, and [DotLogTargetHttp] sends it only
## the records at or above its gate's level, with everything below becoming breadcrumbs
## rather than events.
##
## The trail is the reason to have both: an error tracker with the twenty lines that
## preceded the error answers "why" in one screen, and those twenty lines come from a
## [DotLogTargetMemory] this format is given. Without them a game crash report is a stack
## and a shrug.
##
## [b]The DSN contains a public key and is not a secret[/b] — it is compiled into every
## shipping client by design, because that is how a client reports its own crashes. It is
## still refused from the environment and the command line by [DotLogConfig], for the
## ordinary reason: a value that selects where crash reports go should be deployed, not
## ambient.

## The DSN from the project's settings, [code]https://<key>@<host>/<project>[/code].
@export var dsn: String = ""

## Where breadcrumbs come from. Optional, and the report is much thinner without one.
var breadcrumb_source: DotLogTargetMemory = null

## How many breadcrumbs to attach. Sentry's own limit is 100.
@export_range(0, 100, 1) var max_breadcrumbs: int = 30

## Fixed tags. Sentry groups and filters on these, so keep them low-cardinality — the
## same rule as Loki's labels, for the same reason.
@export var tags: Dictionary = {}

## The release, for "this started in build 412". Overridden by a context `version`.
@export var release: String = ""

var _rng := RandomNumberGenerator.new()
var _parsed: Dictionary = {}


func _init() -> void:
	_rng.randomize()


func format_name() -> String:
	return "sentry"


func content_type() -> String:
	return "application/x-sentry-envelope"


func is_error_tracker() -> bool:
	return true


## The ingestion URL, derived from the DSN.
##
## Overrides whatever base URL the target was given: a DSN already names the host and the
## project, and a deployment that had to configure both would get them out of step.
func endpoint_override() -> String:
	var parts: Dictionary = _dsn_parts()
	if parts.is_empty():
		return ""
	return "%s://%s/api/%s/envelope/" % [
		parts["scheme"], parts["host"], parts["project"]
	]


func headers() -> Dictionary:
	var out: Dictionary = super()
	var parts: Dictionary = _dsn_parts()
	if parts.is_empty():
		return out

	# The auth header's form is fixed by the protocol. sentry_client is not decoration:
	# it is what appears in the SDK column, and an unrecognised one is how you find out
	# these events came from the game rather than from a web front end.
	out["X-Sentry-Auth"] = (
		"Sentry sentry_version=7, sentry_client=dot-log/0.1.0, sentry_key=%s"
		% parts["key"]
	)
	return out


func build(events: Array, context: Dictionary) -> PackedByteArray:
	var lines: PackedStringArray = PackedStringArray()

	# One envelope, several items. The envelope header's own event_id is the first
	# event's, which is what a receiver uses when an item has none of its own.
	var first_id: String = _event_id()
	lines.append(JSON.stringify({
		"event_id": first_id,
		"sent_at": Time.get_datetime_string_from_system(true, false) + "Z",
		"dsn": dsn,
	}))

	var crumbs: Array = []
	if breadcrumb_source != null and max_breadcrumbs > 0:
		crumbs = breadcrumb_source.breadcrumbs(max_breadcrumbs)

	var n: int = 0
	for event: Dictionary in events:
		var payload: String = JSON.stringify(
			_event_body(event, context, first_id if n == 0 else _event_id(), crumbs)
		)
		# The item header's `length` is in BYTES, not characters. A message with any
		# non-ASCII in it — a player name, nearly always — makes the two differ, and the
		# receiver reads `length` bytes and then fails to parse what follows.
		lines.append(JSON.stringify({
			"type": "event",
			"length": payload.to_utf8_buffer().size(),
			"content_type": "application/json",
		}))
		lines.append(payload)
		n += 1

	return ("\n".join(lines) + "\n").to_utf8_buffer()


func _event_body(
	event: Dictionary, context: Dictionary, event_id: String, crumbs: Array
) -> Dictionary:
	var body: Dictionary = {
		"event_id": event_id,
		"timestamp": DotLogEvent.time_sec(event),
		# `other` rather than a language name: the platform field selects how Sentry
		# tries to symbolicate and render a stack, and claiming one we do not produce
		# gets a worse result than claiming none.
		"platform": "other",
		"level": _sentry_level(int(event.get("level", DotLog.Level.ERROR))),
		"logger": String(event.get("channel", "")),
		"message": {"formatted": String(event.get("message", ""))},
		"extra": DotLogEvent.json_fields(event.get("fields", {})),
		"tags": _tags_for(event, context),
	}

	if context.has("host"):
		body["server_name"] = str(context["host"])
	if context.has("env"):
		body["environment"] = str(context["env"])

	var version: String = str(context.get("version", release))
	if version != "":
		body["release"] = version

	if not crumbs.is_empty():
		body["breadcrumbs"] = {"values": crumbs}

	return body


func _tags_for(event: Dictionary, context: Dictionary) -> Dictionary:
	var out: Dictionary = {}

	for k: Variant in tags:
		out[str(k)] = str(tags[k])

	for k: Variant in context:
		# env and host are first-class fields above; repeating them as tags splits the
		# same fact across two filters in the UI.
		if str(k) == "env" or str(k) == "host" or str(k) == "version":
			continue
		out[str(k)] = str(context[k])

	var channel: String = String(event.get("channel", ""))
	if channel != "":
		out["channel"] = channel

	return out


static func _sentry_level(level: int) -> String:
	match level:
		DotLog.Level.TRACE, DotLog.Level.DEBUG:
			return "debug"
		DotLog.Level.INFO:
			return "info"
		DotLog.Level.WARN:
			return "warning"
		DotLog.Level.FATAL:
			return "fatal"
		_:
			return "error"


## A 32-character lowercase hex id, which is the only form accepted.
func _event_id() -> String:
	var out: String = ""
	for i: int in range(8):
		out += "%08x" % (_rng.randi() & 0xFFFFFFFF)
	return out.substr(0, 32)


## Splits the DSN once and remembers it.
func _dsn_parts() -> Dictionary:
	if not _parsed.is_empty():
		return _parsed
	if dsn == "":
		return {}

	var scheme: String = "https"
	var rest: String = dsn
	var split: int = rest.find("://")
	if split >= 0:
		scheme = rest.substr(0, split)
		rest = rest.substr(split + 3)

	var at: int = rest.rfind("@")
	if at < 0:
		return {}
	var key: String = rest.substr(0, at)
	rest = rest.substr(at + 1)

	# A DSN may carry a secret half as `key:secret`, which has been deprecated for
	# years. Dropped rather than sent: the modern protocol has no field for it.
	var colon: int = key.find(":")
	if colon >= 0:
		key = key.substr(0, colon)

	var slash: int = rest.rfind("/")
	if slash < 0:
		return {}

	_parsed = {
		"scheme": scheme,
		"host": rest.substr(0, slash),
		"project": rest.substr(slash + 1),
		"key": key,
	}
	return _parsed


func max_batch() -> int:
	# Events, not lines. A batch this size already means something is very wrong.
	return 20


func max_bytes() -> int:
	# Sentry's compressed envelope limit is 20 MB; uncompressed items are capped lower.
	return 1024 * 1024


func interpret(response: Dictionary) -> DotResult:
	var status: int = int(response.get("status", 0))

	if status >= 200 and status < 300:
		return DotResult.success(null)

	if status == 429:
		# Sentry rate-limits per project and says for how long. Honoured rather than
		# retried, because retrying through a rate limit extends it.
		var error: DotError = DotError.from_http(status, "")
		error.code = DotError.CODE_RATE_LIMITED
		var headers: Dictionary = response.get("headers", {})
		for k: Variant in headers:
			if str(k).to_lower() == "retry-after":
				error.retry_after = str(headers[k]).to_float()
		return DotResult.failure(error)

	if status == 413:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"The envelope was too large.",
			"lower max_breadcrumbs, or the size of the fields being logged"
		)

	return DotResult.failure(
		DotError.from_http(status, String(response.get("body_text", "")))
	)
