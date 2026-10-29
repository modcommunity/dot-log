extends "log_selftest_base.gd"

## The log format checks (NDJSON, Loki, Elastic, Splunk, Datadog, Seq, GELF, OTLP, Sentry).

func _test_format_ndjson() -> void:
	_section("format: ndjson")

	var format: DotLogFormatNdjson = DotLogFormatNdjson.new()
	format.token = "secret"
	var body: String = format.build(
		[_event(DotLog.Level.INFO, "net", "one"), _event(DotLog.Level.WARN, "net", "two")],
		{"service": "arena"}
	).get_string_from_utf8()

	var lines: PackedStringArray = body.split("\n", false)
	_check("one object per line", lines.size() == 2, null, body)
	_check("each parses", typeof(_parse(lines[0])) == TYPE_DICTIONARY)
	_check("the body ends with a newline", body.ends_with("\n"))
	_check("the context is on each line", str((_parse(lines[1]) as Dictionary)["service"]) == "arena")
	_check("the token goes in a bearer header", str(format.headers()["Authorization"]) == "Bearer secret")
	_check("the content type is ndjson", format.content_type() == "application/x-ndjson")

	format.as_array = true
	var array_body: Variant = _parse(format.build([_event()], {}).get_string_from_utf8())
	_check("as_array sends a JSON array", typeof(array_body) == TYPE_ARRAY)
	_check("and changes the content type", format.content_type() == "application/json")

	_line("")
	_done()


func _test_format_loki() -> void:
	_section("format: loki")

	var format: DotLogFormatLoki = DotLogFormatLoki.new()
	format.token = "t"
	format.tenant = "tmc"

	var body: Variant = _parse(format.build([
		_event(DotLog.Level.INFO, "player.roster", "joined", {"peer": 4}),
		_event(DotLog.Level.INFO, "player.roster", "left"),
		_event(DotLog.Level.ERROR, "net", "dropped"),
	], {"service": "arena", "env": "prod"}).get_string_from_utf8())

	_check("the payload has streams", typeof(body) == TYPE_DICTIONARY and (body as Dictionary).has("streams"))
	var streams: Array = (body as Dictionary)["streams"]
	_check("records with the same labels share a stream", streams.size() == 2, null, str(streams.size()))

	var first: Dictionary = streams[0]
	_check("the stream carries the labels", (first["stream"] as Dictionary).has("service") and (first["stream"] as Dictionary).has("level"))
	_check("a dot in a channel is replaced, because Loki rejects one", str((first["stream"] as Dictionary)["channel"]) == "player_roster", null, str((first["stream"] as Dictionary)["channel"]))
	_check("two records are in the one stream", (first["values"] as Array).size() == 2)

	var entry: Array = (first["values"] as Array)[0]
	_check("the timestamp is a nanosecond string", typeof(entry[0]) == TYPE_STRING and str(entry[0]).ends_with("000000"))
	_check("the line is JSON with the message", str(entry[1]).contains("\"message\":\"joined\""), null, str(entry[1]))
	_check("and the fields", str(entry[1]).contains("peer"))

	_check("the tenant is a header", str(format.headers()["X-Scope-OrgID"]) == "tmc")
	_check("the path is the push API", format.default_path() == "/loki/api/v1/push")

	format.username = "12345"
	_check("a username makes it basic auth", str(format.headers()["Authorization"]).begins_with("Basic "))

	_check("a 204 is success", format.interpret({"status": 204}).ok)
	var bad: DotResult = format.interpret({"status": 400, "body_text": "entry out of order"})
	_check("a 400 is invalid, not retryable", not bad.ok and bad.code() == DotError.CODE_INVALID and not bad.is_retryable())
	_check("a 503 is retryable", format.interpret({"status": 503, "body_text": ""}).is_retryable())

	_line("")
	_done()


func _test_format_elastic() -> void:
	_section("format: elasticsearch")

	var format: DotLogFormatElastic = DotLogFormatElastic.new()
	format.index = "dot-logs-%Y.%m.%d"
	format.token = "k"

	var body: String = format.build([_event(DotLog.Level.WARN, "net", "one", {"peer": 4})], {"service": "arena"}).get_string_from_utf8()
	var lines: PackedStringArray = body.split("\n", false)
	_check("an action line and a document line", lines.size() == 2, null, body)

	var action: Dictionary = _parse(lines[0])
	_check("the action is index by default", action.has("index"))
	_check("naming the resolved index", str((action["index"] as Dictionary)["_index"]).begins_with("dot-logs-2"), null, str((action["index"] as Dictionary)["_index"]))
	_check("the date pattern is expanded", not str((action["index"] as Dictionary)["_index"]).contains("%"))

	var doc: Dictionary = _parse(lines[1])
	_check("the document uses the common schema", doc.has("@timestamp") and (doc["log"] as Dictionary).has("level"))
	_check("with the context", str(doc["service"]) == "arena")
	_check("and fields prefixed against a mapping conflict", doc.has("f_peer"))
	_check("the body ends with a newline", body.ends_with("\n"))
	_check("the content type is ndjson", format.content_type() == "application/x-ndjson")
	_check("the API key header is used", str(format.headers()["Authorization"]) == "ApiKey k")

	format.data_stream = true
	var create: Dictionary = _parse(format.build([_event()], {}).get_string_from_utf8().split("\n", false)[0])
	_check("a data stream uses create, which is all it accepts", create.has("create"))

	_check("a 200 with no errors is success", format.interpret({"status": 200, "body_text": "{\"errors\":false,\"took\":4}"}).ok)

	var rejected: DotResult = format.interpret({
		"status": 200,
		"body_text": "{\"errors\":true,\"items\":[{\"index\":{\"status\":400,\"error\":{\"type\":\"mapper_parsing_exception\",\"reason\":\"failed to parse\"}}}]}",
	})
	_check("a 200 that rejected everything is a FAILURE", not rejected.ok)
	_check("naming how many", rejected.error.message.contains("1 of 1"))
	_check("and why", rejected.error.detail.contains("mapper_parsing_exception"))
	_check("and it is not retryable", not rejected.is_retryable())

	_check("a 200 that is not the bulk response is a failure", not format.interpret({"status": 200, "body_text": "<html>login</html>"}).ok)

	_line("")
	_done()


func _test_format_splunk() -> void:
	_section("format: splunk")

	var format: DotLogFormatSplunk = DotLogFormatSplunk.new()
	format.token = "hec-token"
	format.splunk_index = "games"

	var body: String = format.build([_event(DotLog.Level.INFO, "net", "one", {"peer": 4})], {"service": "arena", "host": "eu-1"}).get_string_from_utf8()
	var doc: Dictionary = _parse(body.split("\n", false)[0])

	_check("the time is seconds, not milliseconds", float(doc["time"]) < 100000000000.0, null, str(doc["time"]))
	_check("the index is named", str(doc["index"]) == "games")
	_check("the host is in the envelope", str(doc["host"]) == "eu-1")
	_check("the payload is under event", (doc["event"] as Dictionary).has("message"))
	_check("with the fields", int((doc["event"] as Dictionary)["peer"]) == 4)
	_check("and the context, minus the host", (doc["event"] as Dictionary).has("service") and not (doc["event"] as Dictionary).has("host"))
	_check("the sourcetype makes Splunk parse it", str(doc["sourcetype"]) == "_json")

	_check("the auth scheme is Splunk, not Bearer", str(format.headers()["Authorization"]) == "Splunk hec-token")
	_check("the path is the event collector", format.default_path() == "/services/collector/event")

	_check("a 200 with code 0 is success", format.interpret({"status": 200, "body_text": "{\"text\":\"Success\",\"code\":0}"}).ok)
	_check("a 200 with a non-zero code is not", not format.interpret({"status": 200, "body_text": "{\"text\":\"No data\",\"code\":5}"}).ok)
	var auth: DotResult = format.interpret({"status": 403, "body_text": ""})
	_check("a 403 says the token was refused", not auth.ok and auth.code() == DotError.CODE_AUTH)

	_line("")
	_done()


func _test_format_datadog() -> void:
	_section("format: datadog")

	var format: DotLogFormatDatadog = DotLogFormatDatadog.new()
	format.token = "dd"
	format.tags = {"region": "eu"}

	var rows: Variant = _parse(format.build([
		_event(DotLog.Level.WARN, "net", "one", {"peer": 4})
	], {"service": "arena", "env": "prod", "host": "eu-1"}).get_string_from_utf8())

	_check("the payload is an array", typeof(rows) == TYPE_ARRAY)
	var row: Dictionary = (rows as Array)[0]
	_check("the level is a name Datadog knows", str(row["status"]) == "warning")
	_check("the service comes from the context", str(row["service"]) == "arena")
	_check("the host is its own field", str(row["hostname"]) == "eu-1")
	_check("ddtags is a comma-separated string, not an object", typeof(row["ddtags"]) == TYPE_STRING and str(row["ddtags"]).contains("region:eu"))
	_check("with the context tags", str(row["ddtags"]).contains("env:prod"))
	_check("but not the reserved ones", not str(row["ddtags"]).contains("service:"))
	_check("the fields are flat on the row", int(row["peer"]) == 4)
	_check("ddsource is not an integration name", str(row["ddsource"]) == "dot")

	_check("the key goes in DD-API-KEY", str(format.headers()["DD-API-KEY"]) == "dd")
	_check("a fatal record is critical", str(((_parse(format.build([_event(DotLog.Level.FATAL)], {}).get_string_from_utf8()) as Array)[0] as Dictionary)["status"]) == "critical")
	var forbidden: DotResult = format.interpret({"status": 403, "body_text": ""})
	_check("a 403 mentions the region", not forbidden.ok and forbidden.error.detail.contains("region"))

	_line("")
	_done()


func _test_format_seq() -> void:
	_section("format: seq")

	var format: DotLogFormatSeq = DotLogFormatSeq.new()
	format.token = "seq-key"

	var body: String = format.build([
		_event(DotLog.Level.WARN, "net", "player connected", {"peer": 4, "@t": "sneaky"})
	], {"service": "arena"}).get_string_from_utf8()
	var doc: Dictionary = _parse(body.split("\n", false)[0])

	_check("the timestamp is @t", doc.has("@t") and str(doc["@t"]).ends_with("Z"))
	_check("and is not overwritten by a field called @t", str(doc["@t"]) != "sneaky")
	_check("the level is Seq's own name", str(doc["@l"]) == "Warning")
	_check("the message is a template", doc.has("@mt") and str(doc["@mt"]).contains("player connected"))
	_check("with a hole per field", str(doc["@mt"]).contains("{peer}"), null, str(doc["@mt"]))
	_check("the field is a property", int(doc["peer"]) == 4)
	_check("the context is too", str(doc["service"]) == "arena")
	_check("the channel is a property", str(doc["Channel"]) == "net")

	var info: Dictionary = _parse(format.build([_event(DotLog.Level.INFO)], {}).get_string_from_utf8().split("\n", false)[0])
	_check("an info record sends no level, which is the CLEF default", not info.has("@l"))

	format.use_template = false
	var rendered: Dictionary = _parse(format.build([_event(DotLog.Level.INFO, "net", "x", {"a": 1})], {}).get_string_from_utf8().split("\n", false)[0])
	_check("templates can be turned off", rendered.has("@m") and not rendered.has("@mt"))

	_check("the key header is Seq's", str(format.headers()["X-Seq-ApiKey"]) == "seq-key")
	_check("the content type is CLEF", format.content_type() == "application/vnd.serilog.clef")
	_check("a 400 is invalid", format.interpret({"status": 400, "body_text": "bad"}).code() == DotError.CODE_INVALID)

	_line("")
	_done()


func _test_format_gelf() -> void:
	_section("format: gelf")

	var format: DotLogFormatGelf = DotLogFormatGelf.new()
	var doc: Dictionary = format.message_for(
		_event(DotLog.Level.ERROR, "net", "dropped", {"peer": 4, "id": "x", "_already": 1}),
		{"service": "arena", "host": "eu-1"}
	)

	_check("the version is 1.1", str(doc["version"]) == "1.1")
	_check("the host comes from the context", str(doc["host"]) == "eu-1")
	_check("short_message is the message", str(doc["short_message"]) == "dropped")
	_check("the level is the syslog severity", int(doc["level"]) == 3)
	_check("the timestamp is fractional seconds", float(doc["timestamp"]) > 1000000.0)
	_check("a custom field is underscore-prefixed", doc.has("_peer"))
	_check("a field called id is renamed, because _id is forbidden", doc.has("_field_id") and not doc.has("_id"))
	_check("an already-prefixed field is not doubled", doc.has("_already"))
	_check("the context is a field", str(doc["_service"]) == "arena")

	var empty: Dictionary = format.message_for(_event(DotLog.Level.INFO, "net", ""), {})
	_check("an empty message gets a placeholder, because empty is rejected", str(empty["short_message"]) != "")

	var body: String = format.build([_event(), _event()], {}).get_string_from_utf8()
	_check("bulk sends one object per line", body.split("\n", false).size() == 2)

	format.bulk = false
	_check("and the batch drops to one when it is off", format.max_batch() == 1)

	_check("a 400 mentions the usual cause", format.interpret({"status": 400, "body_text": ""}).error.detail.contains("short_message"))

	_line("")
	_done()


func _test_format_otlp() -> void:
	_section("format: otlp")

	var format: DotLogFormatOtlp = DotLogFormatOtlp.new()
	var body: Variant = _parse(format.build([
		_event(DotLog.Level.ERROR, "net", "dropped", {"peer": 4, "ratio": 0.5, "ok": true})
	], {"service": "arena", "env": "prod", "version": "1.2.3"}).get_string_from_utf8())

	_check("the payload is resourceLogs", typeof(body) == TYPE_DICTIONARY and (body as Dictionary).has("resourceLogs"))

	var resource_logs: Dictionary = ((body as Dictionary)["resourceLogs"] as Array)[0]
	var attributes: Array = (resource_logs["resource"] as Dictionary)["attributes"]
	var names: PackedStringArray = PackedStringArray()
	for a: Variant in attributes:
		names.append(str((a as Dictionary)["key"]))
	_check("the context becomes resource attributes", names.has("service.name") and names.has("deployment.environment.name"), null, ",".join(names))
	_check("with the semantic names, not ours", names.has("service.version"))

	var record: Dictionary = (((resource_logs["scopeLogs"] as Array)[0] as Dictionary)["logRecords"] as Array)[0]
	_check("the time is a nanosecond STRING", typeof(record["timeUnixNano"]) == TYPE_STRING)
	_check("observed time is set too", record.has("observedTimeUnixNano"))
	_check("the severity number is banded", int(record["severityNumber"]) == 17)
	_check("the body is a tagged value", (record["body"] as Dictionary).has("stringValue"))

	var by_key: Dictionary = {}
	for a: Variant in (record["attributes"] as Array):
		by_key[str((a as Dictionary)["key"])] = (a as Dictionary)["value"]
	_check("an int attribute is a string, because it is 64-bit", str((by_key["peer"] as Dictionary)["intValue"]) == "4")
	_check("a float is a double", (by_key["ratio"] as Dictionary).has("doubleValue"))
	_check("a bool is a bool", (by_key["ok"] as Dictionary)["boolValue"] == true)
	_check("the channel is an attribute", by_key.has("log.channel"))

	_check("the path is the logs endpoint", format.default_path() == "/v1/logs")

	var partial: DotResult = format.interpret({
		"status": 200,
		"body_text": "{\"partialSuccess\":{\"rejectedLogRecords\":2,\"errorMessage\":\"too old\"}}",
	})
	_check("a partial success is reported as a failure", not partial.ok and partial.error.message.contains("2"))
	_check("a plain 200 is success", format.interpret({"status": 200, "body_text": "{}"}).ok)

	_line("")
	_done()


func _test_format_sentry() -> void:
	_section("format: sentry")

	var format: DotLogFormatSentry = DotLogFormatSentry.new()
	format.dsn = "https://abc123@o1.ingest.example.com/4505"
	format.release = "1.2.3"

	_check("it is an error tracker, not a log collector", format.is_error_tracker())
	_check("the endpoint comes from the DSN", format.endpoint_override() == "https://o1.ingest.example.com/api/4505/envelope/", null, format.endpoint_override())
	_check("the auth header carries the public key", str(format.headers()["X-Sentry-Auth"]).contains("sentry_key=abc123"))
	_check("and names the client", str(format.headers()["X-Sentry-Auth"]).contains("dot-log"))

	var memory: DotLogTargetMemory = DotLogTargetMemory.new(8)
	memory.open()
	memory.write(_event(DotLog.Level.INFO, "net", "before the error"))
	format.breadcrumb_source = memory

	var body: String = format.build([
		_event(DotLog.Level.ERROR, "net", "it broke", {"peer": 4})
	], {"service": "arena", "env": "prod", "host": "eu-1"}).get_string_from_utf8()

	var lines: PackedStringArray = body.split("\n", false)
	_check("an envelope is a header, an item header and a payload", lines.size() == 3, null, str(lines.size()))

	var envelope: Dictionary = _parse(lines[0])
	_check("the envelope header has an event id", str(envelope["event_id"]).length() == 32)
	_check("and the DSN", str(envelope["dsn"]) == format.dsn)

	var item: Dictionary = _parse(lines[1])
	_check("the item header says event", str(item["type"]) == "event")
	_check("and its length is in BYTES", int(item["length"]) == lines[2].to_utf8_buffer().size(), null, "%d vs %d" % [int(item["length"]), lines[2].to_utf8_buffer().size()])

	var payload: Dictionary = _parse(lines[2])
	_check("the level is Sentry's", str(payload["level"]) == "error")
	_check("the channel is the logger", str(payload["logger"]) == "net")
	_check("the fields are extra", int((payload["extra"] as Dictionary)["peer"]) == 4)
	_check("the environment is its own field", str(payload["environment"]) == "prod")
	_check("the host is the server name", str(payload["server_name"]) == "eu-1")
	_check("the release is set", str(payload["release"]) == "1.2.3")
	_check("the breadcrumbs are attached", (payload["breadcrumbs"] as Dictionary).has("values") and ((payload["breadcrumbs"] as Dictionary)["values"] as Array).size() == 1)
	_check("the tags do not repeat the first-class fields", not (payload["tags"] as Dictionary).has("env"))

	var unicode_body: String = format.build([_event(DotLog.Level.ERROR, "chat", "ünïcödé broke")], {}).get_string_from_utf8()
	var unicode_lines: PackedStringArray = unicode_body.split("\n", false)
	_check("a non-ASCII payload still has a byte-correct length", int((_parse(unicode_lines[1]) as Dictionary)["length"]) == unicode_lines[2].to_utf8_buffer().size())

	var limited: DotResult = format.interpret({"status": 429, "headers": {"Retry-After": "30"}, "body_text": ""})
	_check("a 429 is a rate limit", limited.code() == DotError.CODE_RATE_LIMITED)
	_check("and carries the wait", limited.error.retry_after == 30.0)
	_check("a 413 explains itself", format.interpret({"status": 413, "body_text": ""}).error.detail.contains("breadcrumbs"))

	var no_dsn: DotLogFormatSentry = DotLogFormatSentry.new()
	_check("without a DSN there is no endpoint", no_dsn.endpoint_override() == "")

	_line("")
	_done()


# --- Router -----------------------------------------------------------------
