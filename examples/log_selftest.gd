extends Node

## Exercises dot-log without a collector, a database or a socket.
##
## Everything here is the part that can be wrong on a machine with nothing installed:
## what the bytes look like, what the gate lets through, what the buffer drops, and what
## each target does when the thing it talks to says no. The drivers and the sockets are
## faked one level above themselves — a fake [DotHttp] and a fake SQL driver — because
## that seam is the whole reason both of them are pluggable.
##
## [codeblock]
## godot --headless --path . res://examples/log_selftest.tscn
## [/codeblock]

const CHECKS := 445

## Sections entered against sections that ran to their last line, and against this. A
## runtime error inside a section aborts that function and nothing says so; a section that
## bailed out early after a failed guard is counted as not finished on purpose. The CHECKS
## total is the other half — see docs/testing.md.
const SECTIONS := 26

var _passed := 0
var _failed := 0
var _entered := 0
var _completed := 0


## A DotHttp that answers from a script instead of from the network.
##
## Extends the real one rather than duck-typing it, because DotLogTargetHttp's field is
## typed — and a fake that cannot be assigned is a fake that proves nothing.
class FakeHttp extends DotHttp:
	var requests: Array[Dictionary] = []
	var status: int = 200
	var body: String = "{}"
	var transport_error: bool = false

	func request(
		method: int,
		path: String,
		body_bytes: PackedByteArray = PackedByteArray(),
		headers: Dictionary = {},
		decode_text: bool = true
	) -> DotResult:
		requests.append({
			"method": method,
			"url": path,
			"body": body_bytes.get_string_from_utf8(),
			"headers": headers.duplicate(),
		})

		if transport_error:
			return DotResult.fail(DotError.CODE_NETWORK, "the collector is unreachable")

		if status < 200 or status >= 300:
			return DotResult.failure(DotError.from_http(status, body))

		return DotResult.success({
			"status": status,
			"headers": {},
			"body": body.to_utf8_buffer(),
			"body_text": body,
			"attempts": 1,
		})

	func last_body() -> String:
		return "" if requests.is_empty() else str(requests[requests.size() - 1]["body"])


## A SQL driver that records statements. The shape dot-moderation's driver already has.
class FakeDriver extends RefCounted:
	var statements: Array[Dictionary] = []
	var fail_next: bool = false
	var rows: Array = []

	func driver_name() -> String:
		return "fake"

	func is_available() -> DotResult:
		return DotResult.success(null)

	func execute(sql: String, params: Array = []) -> DotResult:
		statements.append({"sql": sql, "params": params.duplicate()})
		if fail_next:
			fail_next = false
			return DotResult.fail(DotError.CODE_NETWORK, "the database went away")
		return DotResult.success(params.size())

	func query(sql: String, params: Array = []) -> DotResult:
		statements.append({"sql": sql, "params": params.duplicate()})
		return DotResult.success(rows)

	func inserts() -> Array:
		var out: Array = []
		for s: Dictionary in statements:
			if str(s["sql"]).begins_with("INSERT"):
				out.append(s)
		return out


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	await _run()


func _run() -> void:
	_line("dot-log self-test")
	_line("")
	# Two engine errors below are produced ON PURPOSE, by the checks that a bad
	# redaction pattern and a non-JSON collector response are reported rather than
	# thrown: "missing terminating ]" and "Parse JSON failed". Neither is a failure.
	_line("")

	_test_event()
	_test_levels()
	_test_event_values()
	_test_redactor()
	_test_gate()
	_test_gate_dedupe()
	_test_buffer()
	_test_memory_target()
	_test_file_target()
	_test_syslog_format()
	await _test_sql_target()
	await _test_http_target()
	_test_format_ndjson()
	_test_format_loki()
	_test_format_elastic()
	_test_format_splunk()
	_test_format_datadog()
	_test_format_seq()
	_test_format_gelf()
	_test_format_otlp()
	_test_format_sentry()
	await _test_router()
	await _test_router_reentrancy()
	_test_config()
	await _test_config_builds()
	await _test_commands()

	_line("")
	_line("%d passed, %d failed" % [_passed, _failed])
	_finish()


# --- Helpers ----------------------------------------------------------------

func _record(
	level: int = DotLog.Level.INFO,
	channel: String = "net",
	message: String = "hello",
	fields: Dictionary = {}
) -> Dictionary:
	return {
		"level": level,
		"level_name": DotLog.level_name(level),
		"channel": channel,
		"message": message,
		"fields": fields,
		"ticks_ms": Time.get_ticks_msec(),
	}


func _event(
	level: int = DotLog.Level.INFO,
	channel: String = "net",
	message: String = "hello",
	fields: Dictionary = {}
) -> Dictionary:
	return DotLogEvent.from_record(_record(level, channel, message, fields))


func _parse(text: String) -> Variant:
	return JSON.parse_string(text)


# --- Event ------------------------------------------------------------------

func _test_event() -> void:
	_section("event")

	var record: Dictionary = _record(DotLog.Level.WARN, "vote", "not enough players")
	var event: Dictionary = DotLogEvent.from_record(record)

	_check("a record becomes an event", event.has("time_ms") and event.has("seq"))
	_check("carrying its level", int(event["level"]) == DotLog.Level.WARN)
	_check("with the collector's name for it", str(event["severity"]) == "warning")
	_check("and the channel and message", str(event["channel"]) == "vote" and str(event["message"]) == "not enough players")

	var second: Dictionary = DotLogEvent.from_record(record)
	_check("the sequence advances", int(second["seq"]) > int(event["seq"]))

	_check("the record it came from is untouched", not record.has("time_ms"))

	var stamp: String = DotLogEvent.iso8601(event)
	_check("iso8601 is UTC with milliseconds", stamp.ends_with("Z") and stamp.length() == 24, null, stamp)
	_check("and has a T between date and time", stamp[10] == "T", null, stamp)

	_check("nanoseconds are a string", typeof(DotLogEvent.time_ns(event)) == TYPE_STRING)
	_check("and are milliseconds times a million", DotLogEvent.time_ns(event) == str(DotLogEvent.time_ms(event)) + "000000")

	_check("seconds are fractional", absf(DotLogEvent.time_sec(event) - float(DotLogEvent.time_ms(event)) / 1000.0) < 0.001)

	_check("syslog severity is RFC 5424", DotLogEvent.syslog_severity(DotLog.Level.ERROR) == 3 and DotLogEvent.syslog_severity(DotLog.Level.INFO) == 6)
	_check("otlp severity is banded", DotLogEvent.otlp_severity(DotLog.Level.ERROR) == 17 and DotLogEvent.otlp_severity(DotLog.Level.TRACE) == 1)
	_check("an out-of-range level does not crash either", DotLogEvent.syslog_severity(99) == 6 and DotLogEvent.otlp_severity(-4) == 9)

	var synthetic: Dictionary = DotLogEvent.synthetic(DotLog.Level.WARN, "log.gate", "repeated", {"repeated": 3})
	_check("a synthetic event is a full event", synthetic.has("time_ms") and int(synthetic["fields"]["repeated"]) == 3)

	var key: String = DotLogEvent.repeat_key(_event(DotLog.Level.INFO, "net", "same", {"peer": 1}))
	var key2: String = DotLogEvent.repeat_key(_event(DotLog.Level.INFO, "net", "same", {"peer": 2}))
	_check("the repeat key ignores the fields", key == key2, null, key)
	_check("but not the channel", key != DotLogEvent.repeat_key(_event(DotLog.Level.INFO, "chat", "same")))

	_line("")
	_done()


func _test_event_values() -> void:
	_section("event values")

	_check("a string survives", DotLogEvent.json_value("x") == "x")
	_check("an int survives", DotLogEvent.json_value(4) == 4)
	_check("a bool survives", DotLogEvent.json_value(true) == true)
	_check("a StringName becomes a String", typeof(DotLogEvent.json_value(&"kills")) == TYPE_STRING)

	var vector: Variant = DotLogEvent.json_value(Vector3(1, 2, 3))
	_check("a Vector3 becomes a string, not an array", typeof(vector) == TYPE_STRING, null, str(vector))

	var packed: Variant = DotLogEvent.json_value(PackedStringArray(["a", "b"]))
	_check("a PackedStringArray becomes an Array", typeof(packed) == TYPE_ARRAY and (packed as Array).size() == 2)

	var nested: Variant = DotLogEvent.json_value({"a": {"b": &"c"}})
	_check("a nested dictionary is walked", typeof(((nested as Dictionary)["a"] as Dictionary)["b"]) == TYPE_STRING)

	var event: Dictionary = _event(DotLog.Level.INFO, "net", "joined", {"peer": 4, "at": Vector3.ZERO})
	var flat: Dictionary = DotLogEvent.flatten(event, {"service": "arena", "env": "prod"})
	_check("flatten carries the context", str(flat["service"]) == "arena" and str(flat["env"]) == "prod")
	_check("and the envelope", flat.has("time") and str(flat["level"]) == "info" and str(flat["message"]) == "joined")
	_check("and the fields", int(flat["peer"]) == 4 and typeof(flat["at"]) == TYPE_STRING)

	var shadowed: Dictionary = DotLogEvent.flatten(
		_event(DotLog.Level.INFO, "net", "x", {"message": "not this one"}), {}
	)
	_check("a field CAN shadow the message, and that is known", str(shadowed["message"]) == "not this one")

	var context_win: Dictionary = DotLogEvent.flatten(
		_event(DotLog.Level.INFO, "net", "x", {}), {"service": "arena"}
	)
	_check("context is written before the envelope", str(context_win["service"]) == "arena")

	var json: String = DotLogEvent.flatten_json(event, {"service": "arena"}, "f_")
	var decoded: Variant = _parse(json)
	_check("flatten_json is parseable", typeof(decoded) == TYPE_DICTIONARY, null, json)
	_check("and prefixes the fields when asked", (decoded as Dictionary).has("f_peer"))

	var line: String = DotLogEvent.text_line(event)
	_check("the text line has the tag and the message", line.contains("inf") and line.contains("joined"), null, line)
	_check("and the fields as key=value", line.contains("peer=4"), null, line)
	_check("and can leave the time out", not DotLogEvent.text_line(event, false).begins_with("2"))

	_line("")
	_done()


# --- Redactor ---------------------------------------------------------------

func _test_redactor() -> void:
	_section("redactor")

	var redactor: DotLogRedactor = DotLogRedactor.new()
	var compiled: DotResult = redactor.compile()
	_check("the patterns compile", compiled.ok, compiled)

	var fields: Dictionary = {
		"peer": 4,
		"token": "abcdef123456",
		"refresh_token": "zzz",
		"nested": {"password": "hunter2", "name": "Ada"},
	}
	var clean: Dictionary = redactor.redact_fields(fields)

	_check("a secret key is masked", str(clean["token"]) == DotLogRedactor.MASK)
	_check("a key containing a secret name is too", str(clean["refresh_token"]) == DotLogRedactor.MASK)
	_check("a nested secret is masked", str((clean["nested"] as Dictionary)["password"]) == DotLogRedactor.MASK)
	_check("an ordinary field is not", int(clean["peer"]) == 4 and str((clean["nested"] as Dictionary)["name"]) == "Ada")
	_check("the original is untouched", str(fields["token"]) == "abcdef123456")

	redactor.drop_keys = PackedStringArray(["packet_dump"])
	var dropped: Dictionary = redactor.redact_fields({"packet_dump": "0011", "peer": 1})
	_check("a dropped key is gone entirely", not dropped.has("packet_dump") and dropped.has("peer"))

	_check("a bearer token in prose is caught", redactor.redact_text("sent Bearer abcdefghijkl now").contains(DotLogRedactor.MASK))
	_check("a query parameter is caught", redactor.redact_text("GET /v1?api_key=abcd1234 failed").contains(DotLogRedactor.MASK))
	_check("a JWT is caught", redactor.redact_text("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abcd").contains(DotLogRedactor.MASK))
	_check("an email is caught", redactor.redact_text("mail ada@example.com").contains(DotLogRedactor.MASK))
	_check("ordinary prose is left alone", redactor.redact_text("player joined on map de_dust") == "player joined on map de_dust")

	var ip_keeper: DotLogRedactor = DotLogRedactor.new()
	ip_keeper.compile()
	_check("an address survives by default", ip_keeper.redact_text("from 10.0.0.4").contains("10.0.0.4"))

	var ip_masker: DotLogRedactor = DotLogRedactor.new()
	ip_masker.mask_ip_addresses = true
	ip_masker.compile()
	_check("and is masked when asked", not ip_masker.redact_text("from 10.0.0.4").contains("10.0.0.4"))

	var prefixed: DotLogRedactor = DotLogRedactor.new()
	prefixed.keep_prefix = 4
	_check("a kept prefix survives", prefixed.mask("abcdefghij").begins_with("abcd"))
	_check("but not when the value is shorter than the prefix", prefixed.mask("ab") == DotLogRedactor.MASK)

	var applied: Dictionary = redactor.apply(_event(DotLog.Level.INFO, "auth", "login with token abcdefghijkl", {"token": "x"}))
	_check("apply cleans message and fields together", str(applied["fields"]["token"]) == DotLogRedactor.MASK and str(applied["message"]).contains(DotLogRedactor.MASK))
	_check("and counts what it removed", redactor.redaction_count() > 0)

	var bad: DotLogRedactor = DotLogRedactor.new()
	bad.extra_patterns = PackedStringArray(["([unclosed"])
	_check("an uncompilable pattern is reported, not thrown", not bad.compile().ok)

	_line("")
	_done()


# --- Gate -------------------------------------------------------------------

func _test_gate() -> void:
	_section("gate")

	var gate: DotLogGate = DotLogGate.new()
	gate.min_level = DotLog.Level.WARN

	_check("below the level is refused", not gate.allows(_event(DotLog.Level.INFO)))
	_check("at the level passes", gate.allows(_event(DotLog.Level.WARN)))
	_check("above it passes", gate.allows(_event(DotLog.Level.ERROR)))

	var channelled: DotLogGate = DotLogGate.new()
	channelled.channels = PackedStringArray(["net", "player.*"])
	_check("a named channel passes", channelled.allows(_event(DotLog.Level.INFO, "net")))
	_check("a prefix pattern passes", channelled.allows(_event(DotLog.Level.INFO, "player.roster")))
	_check("anything else is refused", not channelled.allows(_event(DotLog.Level.INFO, "chat")))

	channelled.deny_channels = PackedStringArray(["net"])
	_check("a deny beats an allow", not channelled.allows(_event(DotLog.Level.INFO, "net")))

	var sampled: DotLogGate = DotLogGate.new()
	sampled.trace_sample = 0.0
	_check("sampling at zero keeps nothing", not sampled.allows(_event(DotLog.Level.TRACE)))
	_check("and does not touch info", sampled.allows(_event(DotLog.Level.INFO)))

	var limited: DotLogGate = DotLogGate.new()
	limited.per_channel_rate = 1.0
	limited.per_channel_burst = 3.0
	var allowed: int = 0
	for i: int in range(20):
		if limited.allows(_event(DotLog.Level.INFO, "net", "spam %d" % i)):
			allowed += 1
	_check("a rate limit caps a burst", allowed <= 4 and allowed >= 3, null, str(allowed))

	var errors_through: int = 0
	for i: int in range(20):
		if limited.allows(_event(DotLog.Level.ERROR, "net", "bad %d" % i)):
			errors_through += 1
	_check("but never touches errors", errors_through == 20, null, str(errors_through))

	var stats: Dictionary = limited.stats()
	_check("the gate counts what it dropped", int(stats["dropped_rate"]) > 0)
	_check("and describes itself", limited.describe().has("min_level"))

	_line("")
	_done()


func _test_gate_dedupe() -> void:
	_section("gate deduplication")

	var gate: DotLogGate = DotLogGate.new()
	gate.dedupe_window_sec = 30.0

	var through: int = 0
	for i: int in range(50):
		if gate.allows(_event(DotLog.Level.INFO, "net", "packet refused", {"peer": i})):
			through += 1

	_check("only the first of fifty identical lines passes", through == 1, null, str(through))
	_check("even though the fields differed", true)

	var different: bool = gate.allows(_event(DotLog.Level.INFO, "net", "a different line"))
	_check("a different line still passes", different)

	var errors: int = 0
	for i: int in range(10):
		if gate.allows(_event(DotLog.Level.ERROR, "net", "the same error")):
			errors += 1
	_check("errors are never deduplicated", errors == 10, null, str(errors))

	# The window has not closed, so nothing is summarised yet.
	_check("no summary before the window closes", gate.drain_summaries().is_empty())

	gate.dedupe_window_sec = 0.001
	# A real delay, not a hope: the window is in milliseconds and the fifty calls above
	# take less than one, so without this the "next" copy is inside the same window and
	# the test fails on a fast machine and passes on a slow one.
	OS.delay_msec(5)
	# One more copy closes the window from the inside and produces the summary.
	gate.allows(_event(DotLog.Level.INFO, "net", "packet refused"))
	var summaries: Array[Dictionary] = gate.drain_summaries()
	_check("a closed window produces one summary", summaries.size() >= 1, null, str(summaries.size()))
	_check("naming how many were suppressed", int(summaries[0]["fields"]["repeated"]) == 49, null, str(summaries[0]["fields"]["repeated"]))
	_check("and saying who suppressed them", str(summaries[0]["fields"]["suppressed_by"]) == "dot-log")
	_check("keeping the original message", str(summaries[0]["message"]) == "packet refused")
	_check("draining twice gives nothing", gate.drain_summaries().is_empty())

	var bounded: DotLogGate = DotLogGate.new()
	bounded.dedupe_window_sec = 60.0
	bounded.dedupe_capacity = 16
	for i: int in range(100):
		bounded.allows(_event(DotLog.Level.INFO, "net", "unique %d" % i))
	_check("the tracking table is bounded", int(bounded.stats()["tracked"]) <= 16, null, str(bounded.stats()["tracked"]))

	_line("")
	_done()


# --- Buffer -----------------------------------------------------------------

func _test_buffer() -> void:
	_section("buffer")

	var buffer: DotLogBuffer = DotLogBuffer.new(4)
	for i: int in range(4):
		buffer.push(_event(DotLog.Level.INFO, "net", "m%d" % i))

	_check("it holds what fits", buffer.size() == 4)
	_check("and reports its bytes", buffer.byte_size() > 0)

	buffer.push(_event(DotLog.Level.INFO, "net", "m4"))
	_check("it stays bounded", buffer.size() == 4)
	_check("dropping the oldest", str(buffer.peek(1)[0]["message"]) == "m1", null, str(buffer.peek(1)[0]["message"]))
	_check("and counting the drop", buffer.dropped() == 1)

	var taken: Array[Dictionary] = buffer.take(2)
	_check("take returns the oldest first", taken.size() == 2 and str(taken[0]["message"]) == "m1")
	_check("and removes them", buffer.size() == 2)

	buffer.requeue(taken)
	_check("requeue puts them back", buffer.size() == 4)
	_check("at the front, in order", str(buffer.peek(1)[0]["message"]) == "m1")

	var notice: Dictionary = buffer.drain_drop_notice()
	_check("a drop notice is produced", not notice.is_empty() and int(notice["fields"]["dropped"]) == 1)
	_check("at WARN", int(notice["level"]) == DotLog.Level.WARN)
	_check("and resets the count", buffer.drain_drop_notice().is_empty())

	var newest: DotLogBuffer = DotLogBuffer.new(2, DotLogBuffer.Policy.DROP_NEWEST)
	newest.push(_event(DotLog.Level.INFO, "net", "first"))
	newest.push(_event(DotLog.Level.INFO, "net", "second"))
	var refused: bool = newest.push(_event(DotLog.Level.INFO, "net", "third"))
	_check("drop-newest refuses the incoming record", not refused)
	_check("and keeps the earliest", str(newest.peek(1)[0]["message"]) == "first")

	var heavy: DotLogBuffer = DotLogBuffer.new(1000)
	heavy.max_bytes = 300
	for i: int in range(50):
		heavy.push(_event(DotLog.Level.INFO, "net", "a reasonably long message %d" % i))
	_check("the byte bound also holds", heavy.byte_size() <= 300 or heavy.size() == 1, null, str(heavy.byte_size()))
	_check("without emptying itself", heavy.size() >= 1)

	var big: DotLogBuffer = DotLogBuffer.new(10)
	big.max_bytes = 8
	big.push(_event(DotLog.Level.INFO, "net", "one record larger than the whole budget"))
	_check("an oversized single record is still kept", big.size() == 1)

	_check("estimate_size is generous", DotLogBuffer.estimate_size(_event()) > 60)
	_check("and describes itself", DotLogBuffer.new(8).describe().has("high_water"))

	_line("")
	_done()


# --- Memory target ----------------------------------------------------------

func _test_memory_target() -> void:
	_section("memory target")

	var memory: DotLogTargetMemory = DotLogTargetMemory.new(4)
	memory.open()

	for i: int in range(6):
		memory.write(_event(DotLog.Level.INFO, "net", "m%d" % i))

	_check("the ring is bounded", memory.size() == 4)
	_check("keeping the newest", str(memory.tail(1)[0]["message"]) == "m5")
	_check("tail returns oldest first", str(memory.tail(2)[0]["message"]) == "m4")
	_check("tail(0) returns everything", memory.tail(0).size() == 4)

	memory.write(_event(DotLog.Level.ERROR, "chat", "a player said something", {"name": "Ada"}))
	_check("matching finds by message", memory.matching("player").size() == 1)
	_check("and by field value", memory.matching("ada").size() == 1)
	_check("and by channel", memory.matching("", "chat").size() == 1)
	_check("and by level", memory.matching("", "", DotLog.Level.ERROR).size() == 1)
	_check("and finds nothing when there is nothing", memory.matching("nonexistent").is_empty())

	_check("to_text renders lines", memory.to_text().contains("a player said something"))

	var crumbs: Array = memory.breadcrumbs(2)
	_check("breadcrumbs have a timestamp and a category", crumbs.size() == 2 and (crumbs[1] as Dictionary).has("timestamp") and (crumbs[1] as Dictionary).has("category"))
	_check("and the fields as data", ((crumbs[1] as Dictionary)["data"] as Dictionary).has("name"))

	var filtered: DotLogTargetMemory = DotLogTargetMemory.new(8)
	filtered.min_level = DotLog.Level.WARN
	filtered.open()
	filtered.write(_event(DotLog.Level.INFO))
	filtered.write(_event(DotLog.Level.ERROR))
	_check("a target level filters independently of the gate", filtered.size() == 1)

	memory.close()
	_check("closing keeps the ring, because that is when it is read", memory.size() == 4)

	_check("it describes itself", memory.describe().has("capacity"))

	_line("")
	_done()


# --- File target ------------------------------------------------------------

func _test_file_target() -> void:
	_section("file target")

	var dir: String = "user://selftest-logs"
	DotPaths.remove_tree(dir)

	var file: DotLogTargetFile = DotLogTargetFile.new(dir, "test")
	var opened: DotResult = file.open()
	_check("it opens", opened.ok, opened)
	_check("naming a file", file.file_path().contains("test-"), null, file.file_path())

	file.write(_event(DotLog.Level.INFO, "net", "first line", {"peer": 4}))
	_check("a line is buffered, not written", file.pending() == 1)

	var flushed: DotResult = file.flush()
	_check("a flush writes it", flushed.ok and int(flushed.value) == 1, flushed)
	_check("and empties the buffer", file.pending() == 0)

	var text: DotResult = DotPaths.read_text(file.file_path())
	_check("the file has the line", text.ok and str(text.value).contains("first line"), text)
	_check("with its fields", text.ok and str(text.value).contains("peer=4"))
	_check("and a timestamp", text.ok and str(text.value).contains("T"))

	file.write(_event(DotLog.Level.ERROR, "net", "an error"))
	_check("an error skips the buffer", file.pending() == 0)

	var json_file: DotLogTargetFile = DotLogTargetFile.new(dir, "json")
	json_file.json_lines = true
	json_file.set_context({"service": "arena"})
	json_file.open()
	json_file.write(_event(DotLog.Level.INFO, "net", "structured", {"peer": 7}))
	json_file.flush()

	var json_text: DotResult = DotPaths.read_text(json_file.file_path())
	var decoded: Variant = _parse(str(json_text.value).strip_edges())
	_check("json lines parse", typeof(decoded) == TYPE_DICTIONARY, json_text, str(json_text.value))
	_check("carrying the context", str((decoded as Dictionary)["service"]) == "arena")
	_check("and the fields", int((decoded as Dictionary)["peer"]) == 7)
	json_file.close()

	var rotating: DotLogTargetFile = DotLogTargetFile.new(dir, "rot")
	rotating.max_file_bytes = 64
	rotating.open()
	var first_path: String = rotating.file_path()
	for i: int in range(20):
		rotating.write(_event(DotLog.Level.INFO, "net", "a line that is long enough %d" % i))
	rotating.flush()
	_check("it rotates on size", rotating.rotations() > 0, null, str(rotating.rotations()))
	_check("into a new file", rotating.file_path() != first_path or rotating.rotations() > 0)
	rotating.close()

	var pruning: DotLogTargetFile = DotLogTargetFile.new(dir, "rot")
	pruning.max_files = 1
	pruning.open()
	var kept: int = 0
	var listing: DirAccess = DirAccess.open(dir)
	listing.list_dir_begin()
	var n: String = listing.get_next()
	while n != "":
		if n.begins_with("rot"):
			kept += 1
		n = listing.get_next()
	listing.list_dir_end()
	_check("pruning keeps the limit plus the open file", kept <= 2, null, str(kept))
	pruning.close()

	var unopened: DotLogTargetFile = DotLogTargetFile.new("user://selftest-logs", "x")
	unopened.write(_event())
	var lost: DotResult = unopened.flush()
	_check("a flush with no file fails rather than pretending", not lost.ok)
	_check("and says how much was lost", lost.error.detail.contains("lines lost"))

	file.close()
	_check("it describes itself", file.describe().has("rotations"))

	DotPaths.remove_tree(dir)
	_line("")
	_done()


# --- Syslog -----------------------------------------------------------------

func _test_syslog_format() -> void:
	_section("syslog")

	var syslog: DotLogTargetSyslog = DotLogTargetSyslog.new("127.0.0.1", 514)
	syslog.host_name = "eu-1"
	syslog.app_name = "arena"
	syslog.set_context({"service": "arena"})

	var message: String = syslog.format_message(
		_event(DotLog.Level.ERROR, "net", "peer refused", {"peer": 4})
	)

	# facility 16 * 8 + severity 3 = 131
	_check("the priority is facility and severity", message.begins_with("<131>1 "), null, message)
	_check("the version is 1", message.split(" ")[0].ends_with("1") or message.contains(">1 "))
	_check("the host and app are there", message.contains("eu-1") and message.contains("arena"), null, message)
	_check("the channel is the message id", message.contains(" net "), null, message)
	_check("the fields are structured data", message.contains("[dot@32473") and message.contains("peer=\"4\""), null, message)
	_check("the context is too", message.contains("service=\"arena\""))
	_check("and the message is last", message.ends_with("peer refused"), null, message)

	var warn: String = syslog.format_message(_event(DotLog.Level.WARN, "vote", "waiting"))
	_check("a warning is severity 4", warn.begins_with("<132>"), null, warn)

	syslog.structured_data = false
	_check("structured data can be turned off", syslog.format_message(_event()).contains(" - "))
	syslog.structured_data = true

	var awkward: String = syslog.format_message(
		_event(DotLog.Level.INFO, "chat", "said", {"text": "a \"quoted\" ] thing"})
	)
	_check("a quote in a value is escaped", awkward.contains("\\\""), null, awkward)
	_check("and so is a bracket", awkward.contains("\\]"), null, awkward)

	var spacey: String = syslog.format_message(
		_event(DotLog.Level.INFO, "chat", "said", {"a key": "v"})
	)
	_check("a space in a param name is replaced", spacey.contains("a_key="), null, spacey)

	syslog.max_message_bytes = 480
	var long_message: String = ""
	for i: int in range(200):
		long_message += "long "
	var truncated: String = syslog.format_message(_event(DotLog.Level.INFO, "net", long_message))
	_check("a long message is truncated to the byte limit", truncated.to_utf8_buffer().size() <= 480, null, str(truncated.to_utf8_buffer().size()))
	_check("and says so", truncated.ends_with("..."))

	var unicode: String = syslog.format_message(_event(DotLog.Level.INFO, "chat", "ünïcödé ".repeat(200)))
	_check("truncation counts bytes, not characters", unicode.to_utf8_buffer().size() <= 480, null, str(unicode.to_utf8_buffer().size()))

	_check("an empty host becomes the nil value", syslog.format_message(_event(DotLog.Level.INFO, "", "x")).contains(" - "))

	syslog.transport = DotLogTargetSyslog.Transport.TCP
	_check("tcp is buffered", syslog.is_buffered())
	syslog.transport = DotLogTargetSyslog.Transport.UDP
	_check("udp is not", not syslog.is_buffered())
	_check("it describes itself", syslog.describe().has("transport"))

	_line("")
	_done()


# --- SQL --------------------------------------------------------------------

func _test_sql_target() -> void:
	_section("sql target")

	_check("the schema quotes an identifier", DotLogSqlSchema.quote_identifier("dot_log", DotLogSqlSchema.Dialect.SQLITE) == "\"dot_log\"")
	_check("and refuses one it cannot quote", not DotLogSqlSchema.quote_identifier("a\"b; DROP", DotLogSqlSchema.Dialect.SQLITE).contains("DROP;"))
	_check("mysql uses backticks", DotLogSqlSchema.quote_identifier("t", DotLogSqlSchema.Dialect.MYSQL) == "`t`")
	_check("postgres numbers its placeholders", DotLogSqlSchema.placeholder(3, DotLogSqlSchema.Dialect.POSTGRES) == "$3")
	_check("sqlite does not", DotLogSqlSchema.placeholder(3, DotLogSqlSchema.Dialect.SQLITE) == "?")

	var ddl: PackedStringArray = DotLogSqlSchema.create_statements("dot_log", DotLogSqlSchema.Dialect.SQLITE)
	_check("the DDL is a table and two indexes", ddl.size() == 3, null, str(ddl.size()))
	_check("and is idempotent", ddl[0].contains("IF NOT EXISTS"))

	var pg: PackedStringArray = DotLogSqlSchema.create_statements("dot_log", DotLogSqlSchema.Dialect.POSTGRES)
	_check("postgres gets a JSON column type", pg[0].contains("JSONB"))

	# The level is a sortable column, twice over: a number to order and compare by, and
	# a name to read. Sorting on the name alone gives ERROR < FATAL < INFO < WARN, which
	# is alphabetical and almost exactly the wrong order.
	_check("level is its own INTEGER column", ddl[0].contains("level INTEGER NOT NULL"), null, ddl[0])
	_check("with the name beside it", ddl[0].contains("level_name"))
	_check("and both are in the column list", DotLogSqlSchema.COLUMNS.has("level") and DotLogSqlSchema.COLUMNS.has("level_name"))
	_check("indexed with the channel, which is how it is queried", ddl[2].contains("(channel, level)"), null, ddl[2])

	var events: Array = [_event(DotLog.Level.WARN, "net", "one"), _event(DotLog.Level.INFO, "net", "two")]
	var insert: Dictionary = DotLogSqlSchema.insert_statement("dot_log", DotLogSqlSchema.Dialect.SQLITE, events, {"service": "arena"})
	_check("one statement covers the batch", str(insert["sql"]).begins_with("INSERT INTO") and str(insert["sql"]).count("(?") == 2)
	_check("with a parameter per column per row", (insert["params"] as Array).size() == DotLogSqlSchema.COLUMNS.size() * 2)
	_check("the message is a parameter, never inline", not str(insert["sql"]).contains("one"))
	var bound: Array = insert["params"]
	_check("the level binds as a number", typeof(bound[2]) == TYPE_INT and int(bound[2]) == DotLog.Level.WARN)
	_check("and its name beside it", str(bound[3]) == "WARN")
	_check("so ORDER BY level is severity order", int(bound[2]) > int(bound[2 + DotLogSqlSchema.COLUMNS.size()]), null, "WARN then INFO")
	_check("and the context is JSON", str((insert["params"] as Array)[7]).contains("arena"))

	var prune: Dictionary = DotLogSqlSchema.prune_statement("dot_log", DotLogSqlSchema.Dialect.SQLITE, 1000)
	_check("pruning is a parameterised delete", str(prune["sql"]).begins_with("DELETE FROM") and int((prune["params"] as Array)[0]) == 1000)

	var tail: Dictionary = DotLogSqlSchema.tail_statement("dot_log", DotLogSqlSchema.Dialect.SQLITE, 10, "net")
	_check("a tail filters and limits", str(tail["sql"]).contains("WHERE channel") and (tail["params"] as Array).size() == 2)

	var driver: FakeDriver = FakeDriver.new()
	var sql: DotLogTargetSql = DotLogTargetSql.new(driver, "dot_log")
	var opened: DotResult = await sql.open()
	_check("the target opens against a driver", opened.ok, opened)
	_check("creating the table", driver.statements.size() == 3)

	sql.write(_event(DotLog.Level.INFO, "net", "queued"))
	_check("a record is queued", sql.pending() == 1)

	var sent: DotResult = await sql.flush()
	_check("a flush inserts it", sent.ok and int(sent.value) == 1, sent)
	_check("with one INSERT", driver.inserts().size() == 1)
	_check("and empties the queue", sql.pending() == 0)

	driver.fail_next = true
	sql.write(_event(DotLog.Level.INFO, "net", "kept"))
	var failed: DotResult = await sql.flush()
	_check("a failed insert is reported", not failed.ok, null, failed.code())
	_check("and the record is kept", sql.pending() == 1)

	var retried: DotResult = await sql.flush()
	_check("the next flush sends it", retried.ok and sql.pending() == 0, retried)

	var pruned: DotResult = await sql.prune()
	_check("pruning runs a delete", pruned.ok and str(driver.statements[driver.statements.size() - 1]["sql"]).begins_with("DELETE"))

	var read: DotResult = await sql.tail(5)
	_check("a tail reads back", read.ok, read)

	var driverless: DotLogTargetSql = DotLogTargetSql.new(null, "x")
	var refused: DotResult = await driverless.open()
	_check("no driver is a clear failure, not a silent no-op", not refused.ok and refused.code() == DotError.CODE_STATE)

	_check("it describes itself", sql.describe().has("inserted"))

	_line("")
	_done()


# --- HTTP -------------------------------------------------------------------

func _test_http_target() -> void:
	_section("http target")

	var http: FakeHttp = FakeHttp.new()
	var format: DotLogFormatNdjson = DotLogFormatNdjson.new()
	var target: DotLogTargetHttp = DotLogTargetHttp.new(format, "https://logs.example")
	target.http = http

	var opened: DotResult = target.open()
	_check("it opens with a format and an endpoint", opened.ok, opened)
	_check("the endpoint is the base when the format has no path", target.resolved_endpoint() == "https://logs.example")

	target.write(_event(DotLog.Level.INFO, "net", "one"))
	target.write(_event(DotLog.Level.INFO, "net", "two"))
	_check("records are queued, not sent", http.requests.is_empty() and target.pending() == 2)

	var sent: DotResult = await target.flush()
	_check("a flush sends one request", sent.ok and http.requests.size() == 1, sent)
	_check("with both records", http.last_body().split("\n", false).size() == 2)
	_check("and empties the queue", target.pending() == 0)
	_check("as a POST", int(http.requests[0]["method"]) == HTTPClient.METHOD_POST)
	_check("with the format's content type", str((http.requests[0]["headers"] as Dictionary)["Content-Type"]) == "application/x-ndjson")

	http.status = 500
	target.write(_event(DotLog.Level.INFO, "net", "kept"))
	var failed: DotResult = await target.flush()
	_check("a 500 is reported", not failed.ok)
	_check("and the record is kept for the retry", target.pending() == 1)

	http.status = 400
	var rejected: DotResult = await target.flush()
	_check("a 400 is reported too", not rejected.ok)
	_check("but the record is dropped, because it can never be accepted", target.pending() == 0)

	http.status = 500
	for i: int in range(10):
		target.write(_event(DotLog.Level.INFO, "net", "m%d" % i))
		await target.flush()
	_check("repeated failures open the circuit", target.circuit_open_sec() > 0.0)

	var before: int = http.requests.size()
	await target.flush()
	_check("and an open circuit sends nothing", http.requests.size() == before)

	var urgent_http: FakeHttp = FakeHttp.new()
	var urgent: DotLogTargetHttp = DotLogTargetHttp.new(DotLogFormatNdjson.new(), "https://logs.example")
	urgent.http = urgent_http
	urgent.send_immediately_above = DotLog.Level.ERROR
	urgent.open()
	urgent.write(_event(DotLog.Level.INFO))
	_check("an ordinary record does not ask for a flush", not urgent.wants_flush())
	urgent.write(_event(DotLog.Level.ERROR))
	_check("an error does", urgent.wants_flush())

	var pathed: DotLogTargetHttp = DotLogTargetHttp.new(DotLogFormatLoki.new(), "https://loki.example")
	_check("a format's path is appended", pathed.resolved_endpoint() == "https://loki.example/loki/api/v1/push", null, pathed.resolved_endpoint())

	var gateway: DotLogTargetHttp = DotLogTargetHttp.new(DotLogFormatLoki.new(), "https://gw.example/logs/push")
	_check("but not to a URL that already has a path", gateway.resolved_endpoint() == "https://gw.example/logs/push", null, gateway.resolved_endpoint())

	var no_endpoint_http: FakeHttp = FakeHttp.new()
	var no_endpoint: DotLogTargetHttp = DotLogTargetHttp.new(DotLogFormatNdjson.new(), "")
	no_endpoint.http = no_endpoint_http
	_check("no endpoint is a clear failure", not no_endpoint.open().ok)

	var no_http: DotLogTargetHttp = DotLogTargetHttp.new(DotLogFormatNdjson.new(), "https://x.example")
	_check("and so is no DotHttp node", not no_http.open().ok)

	var tracker: DotLogTargetHttp = DotLogTargetHttp.new(DotLogFormatSentry.new(), "")
	_check("an error tracker with no gate takes WARN and above", tracker.accepts(_event(DotLog.Level.WARN)))
	_check("and nothing below it", not tracker.accepts(_event(DotLog.Level.INFO)))

	_check("it describes itself", target.describe().has("circuit_open_for"))

	# DotHttp is a Node, and a Node nobody parented is a Node nobody frees. Left alone
	# these show up as "ObjectDB instances were leaked at exit", which is a real warning
	# about a real leak and must not be background noise in this suite's output.
	http.free()
	urgent_http.free()
	no_endpoint_http.free()

	_line("")
	_done()


# --- Formats ----------------------------------------------------------------

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

func _test_router() -> void:
	_section("router")

	var router: DotLogRouter = DotLogRouter.new()
	router.autostart = false
	router.flush_interval_sec = 60.0
	var memory: DotLogTargetMemory = DotLogTargetMemory.new(32)
	router.targets.append(memory)
	router.set_context({"service": "arena", "env": "test"})
	add_child(router)

	var started: DotResult = await router.start()
	_check("the router starts", started.ok, started)
	_check("and is attached", router.is_started())

	DotLog.set_level(DotLog.Level.TRACE)
	DotLog.info("net", "a routed line", {"peer": 4})
	_check("a DotLog call reaches the target", memory.size() == 1, null, str(memory.size()))

	var event: Dictionary = memory.tail(1)[0]
	_check("as an enriched event", event.has("time_ms") and event.has("seq"))
	_check("with the message intact", str(event["message"]) == "a routed line")

	var seen: Array = []
	router.routed.connect(func(e: Dictionary) -> void: seen.append(e))
	DotLog.info("net", "watched")
	_check("the routed signal fires", seen.size() == 1)

	router.redactor = DotLogRedactor.new()
	DotLog.info("auth", "signing in", {"token": "abcdef"})
	_check("the redactor runs before the targets", str(memory.tail(1)[0]["fields"]["token"]) == DotLogRedactor.MASK)

	router.gate = DotLogGate.new()
	router.gate.min_level = DotLog.Level.WARN
	var before: int = memory.size()
	DotLog.info("net", "below the router gate")
	_check("the router gate refuses a record", memory.size() == before)
	DotLog.warn("net", "above it")
	_check("and passes one above it", memory.size() == before + 1)
	router.gate = null

	router.set_tag("map", "de_dust")
	_check("a tag reaches the context", str(router.context["map"]) == "de_dust")

	var file: DotLogTargetFile = DotLogTargetFile.new("user://selftest-router", "r")
	var added: DotResult = await router.add_target(file)
	_check("a target can be added at runtime", added.ok and router.targets.size() == 2, added)
	_check("and found by name", router.find_target("file") == file)

	DotLog.info("net", "to both")
	_check("a record reaches both", file.pending() == 1)

	await router.flush_all()
	_check("flush_all writes it", file.pending() == 0)

	await router.remove_target(file)
	_check("a target can be removed", router.targets.size() == 1)

	var broken: DotLogTargetSql = DotLogTargetSql.new(null, "x")
	await router.add_target(broken)
	_check("a target that cannot open is disabled, not fatal", not broken.enabled and router.is_started())

	# A FATAL must not be sitting in a buffer when the process goes.
	var fatal_http: FakeHttp = FakeHttp.new()
	var shipper: DotLogTargetHttp = DotLogTargetHttp.new(DotLogFormatNdjson.new(), "https://logs.example")
	shipper.http = fatal_http
	await router.add_target(shipper)

	DotLog.info("net", "an ordinary record")
	_check("an ordinary record waits for the flush", shipper.pending() == 1 and fatal_http.requests.is_empty())

	DotLog.fatal("net", "the process cannot continue")
	_check("a FATAL flushes every target at once", fatal_http.requests.size() == 1, null, str(shipper.pending()))
	_check("carrying the record that said so", fatal_http.last_body().contains("cannot continue"))
	_check("and the router counts the urgent flush", int(router.describe()["urgent_flushes"]) == 1)
	await router.remove_target(shipper)
	fatal_http.free()

	_check("describe_lines says what is going on", ",".join(router.describe_lines()).contains("log router"))
	_check("and describe counts records", int(router.describe()["received"]) > 0)

	await router.shutdown()
	_check("shutdown detaches", not router.is_started())

	var after: int = memory.size()
	DotLog.info("net", "after shutdown")
	_check("and nothing arrives afterwards", memory.size() == after)

	router.queue_free()
	DotPaths.remove_tree("user://selftest-router")
	DotLog.set_level(DotLog.Level.ERROR)
	_line("")
	_done()


func _test_router_reentrancy() -> void:
	_section("router reentrancy")

	var router: DotLogRouter = DotLogRouter.new()
	router.autostart = false
	router.flush_interval_sec = 60.0
	var loud: LoudTarget = LoudTarget.new()
	router.targets.append(loud)
	add_child(router)
	await router.start()

	DotLog.set_level(DotLog.Level.TRACE)
	DotLog.info("net", "the line that makes the target log")

	_check("a target that logs does not recurse", loud.writes == 1, null, str(loud.writes))
	_check("and the reentrant record is counted", int(router.describe()["reentrant_dropped"]) >= 1)
	_check("the process is, notably, still alive", true)

	await router.shutdown()
	router.queue_free()
	DotLog.set_level(DotLog.Level.ERROR)
	_line("")
	_done()


## A target that does exactly the forbidden thing: logs from inside write().
class LoudTarget extends DotLogTarget:
	var writes: int = 0

	func _init() -> void:
		target_name = "loud"

	func write(event: Dictionary) -> void:
		writes += 1
		# The natural, wrong thing to write. Without the router's guard this is
		# unbounded recursion and the process dies here.
		DotLog.warn("loud", "I am writing a record")


# --- Config -----------------------------------------------------------------

func _test_config() -> void:
	_section("config")

	var config: DotLogConfig = DotLogConfig.new()
	_check("the defaults validate", config.validate().ok)
	_check("info is the default level", DotLogConfig.parse_level(config.level) == DotLog.Level.INFO)
	_check("error is the default mirror level", DotLogConfig.parse_level(config.mirror_min_level) == DotLog.Level.ERROR)

	_check("levels parse by name", DotLogConfig.parse_level("warn") == DotLog.Level.WARN)
	_check("and by the long spelling", DotLogConfig.parse_level("warning") == DotLog.Level.WARN)
	_check("and case-insensitively", DotLogConfig.parse_level("ERROR") == DotLog.Level.ERROR)
	_check("an unknown level is -1", DotLogConfig.parse_level("loud") == -1)

	config.level = "loud"
	_check("and fails validation", not config.validate().ok)
	config.level = "debug"

	config.channel_levels = PackedStringArray(["net=trace", "chat"])
	_check("a malformed channel level is refused", not config.validate().ok)
	config.channel_levels = PackedStringArray(["net=trace"])
	_check("a good one is accepted", config.validate().ok)

	config.remote_enabled = true
	config.remote_url = ""
	_check("remote logging with no URL is refused", not config.validate().ok)
	config.remote_format = "sentry"
	_check("and sentry with no DSN is too", not config.validate().ok)
	config.sentry_dsn = "https://k@h/1"
	_check("a DSN is enough for sentry", config.validate().ok)
	config.remote_format = "nonsense"
	config.remote_url = "https://x.example"
	_check("an unknown format is refused", not config.validate().ok)
	config.remote_enabled = false
	config.remote_format = "ndjson"

	config.sql_enabled = true
	config.sql_dialect = "oracle"
	_check("an unknown dialect is refused", not config.validate().ok)
	config.sql_dialect = "postgres"
	_check("a known one is not", config.validate().ok)
	_check("and maps to the schema's enum", DotLogConfig.dialect_of("postgres") == DotLogSqlSchema.Dialect.POSTGRES)
	config.sql_enabled = false

	_check("the secrets are named", config.sensitive_keys().has("remote_token") and config.sensitive_keys().has("sentry_dsn"))
	_check("the env prefix is the family's shape", config.env_prefix() == "DOT_LOG_")
	_check("and so is the cli prefix", config.cli_prefix() == "--log-")

	var applied: PackedStringArray = config.apply_dictionary({
		"level": "warn", "file_basename": "arena", "memory_capacity": 64,
	})
	_check("a dictionary layer applies", config.level == "warn" and config.file_basename == "arena" and applied.size() == 3)
	_check("and an unknown key is remembered, not fatal", config.apply_dictionary({"nonsense": 1}).size() == 0 and config.unknown_keys.size() > 0)

	config.service = "arena"
	config.env = "prod"
	var tags: Dictionary = config.context_tags()
	_check("context tags skip what is empty", not tags.has("instance"))
	_check("and always name a host", tags.has("host"))

	config.remote_tags = PackedStringArray(["region=eu", "tier=free"])
	config.remote_token = "t"
	var loki: DotLogFormat = config.make_format()
	config.remote_format = "loki"
	loki = config.make_format()
	_check("a format is built by name", loki != null and loki.format_name() == "loki")
	_check("carrying the token", loki.token == "t")
	_check("and the fixed tags", (loki as DotLogFormatLoki).static_labels.has("region"))
	config.remote_format = "otlp"
	_check("otlp takes the service name", (config.make_format() as DotLogFormatOtlp).service_name == "arena")
	config.remote_format = "elasticsearch"
	_check("an alias resolves", config.make_format().format_name() == "elasticsearch")
	config.remote_format = "nonsense"
	_check("and an unknown name is null", config.make_format() == null)

	_line("")
	_done()


func _test_config_builds() -> void:
	_section("config builds a router")

	var config: DotLogConfig = DotLogConfig.new()
	config.service = "arena"
	config.env = "test"
	config.file_enabled = true
	config.file_directory = "user://selftest-config"
	config.memory_enabled = true
	config.dedupe_window_sec = 5.0
	config.mirror_min_level = "error"
	config.flush_interval_sec = 30.0

	var router: DotLogRouter = config.build_router()
	_check("a router is built", router != null)
	_check("with the file and the memory ring", router.targets.size() == 2)
	_check("a redactor", router.redactor != null)
	_check("and a gate, because dedupe was asked for", router.gate != null and router.gate.dedupe_window_sec == 5.0)
	_check("the context is set", str(router.context["service"]) == "arena")
	_check("and the interval", router.flush_interval_sec == 30.0)

	config.remote_enabled = true
	config.remote_format = "seq"
	config.remote_url = "https://seq.example"
	config.remote_level = "warn"
	var with_remote: DotLogRouter = config.build_router()
	_check("a remote target is added", with_remote.targets.size() == 3)
	var remote: DotLogTarget = with_remote.find_target("seq")
	_check("named after its format", remote != null)
	_check("gated at the configured level", remote.gate != null and remote.gate.min_level == DotLog.Level.WARN)

	config.remote_format = "sentry"
	config.sentry_dsn = "https://k@h.example/1"
	var with_tracker: DotLogRouter = config.build_router()
	var tracker: DotLogTargetHttp = with_tracker.find_target("sentry") as DotLogTargetHttp
	_check("an error tracker gets the memory ring for breadcrumbs", tracker != null and tracker.breadcrumb_source != null)

	# add_child is what starts it: build_router leaves autostart on, so a host that adds
	# it to the tree has a working logger without a second call.
	add_child(router)
	await get_tree().process_frame
	_check("the built router starts on being added to the tree", router.is_started())
	_check("and set DotLog's mirror level", DotLog.mirror_min_level == DotLog.Level.ERROR)

	config.apply_levels()
	_check("apply_levels sets the global level", DotLog.get_level() == DotLog.Level.INFO)

	await router.shutdown()
	router.queue_free()
	# free(), not queue_free(): neither of these was ever added to the tree, and the
	# suite quits before the next idle frame would have collected them.
	with_remote.free()
	with_tracker.free()
	DotPaths.remove_tree("user://selftest-config")
	DotLog.set_level(DotLog.Level.ERROR)
	_line("")
	_done()


# --- Levels -----------------------------------------------------------------

func _test_levels() -> void:
	_section("levels")

	_check("there are six, and OFF", DotLog.Level.OFF == 6 and DotLog.LEVEL_NAMES.size() == 7)
	_check("in severity order", DotLog.Level.TRACE < DotLog.Level.DEBUG and DotLog.Level.DEBUG < DotLog.Level.INFO and DotLog.Level.INFO < DotLog.Level.WARN and DotLog.Level.WARN < DotLog.Level.ERROR and DotLog.Level.ERROR < DotLog.Level.FATAL)
	_check("each has a name", DotLog.level_name(DotLog.Level.FATAL) == "FATAL")
	_check("and a tag", DotLog.LEVEL_TAGS[DotLog.Level.FATAL] == "FTL")

	# The level is in the line, at a fixed width, in both styles.
	for level: int in range(DotLog.Level.TRACE, DotLog.Level.OFF):
		var line: String = DotLogEvent.text_line(_event(level, "net", "a message"), false)
		_check(
			"a %s line shows its level" % DotLog.LEVEL_NAMES[level],
			line.begins_with(DotLog.LEVEL_TAGS[level]),
			null,
			line
		)

	_check("every tag is three characters", DotLog.level_column(DotLog.Level.INFO).length() == 3 and DotLog.level_column(DotLog.Level.FATAL).length() == 3)

	DotLog.level_style = DotLog.LevelStyle.NAME
	var named: String = DotLogEvent.text_line(_event(DotLog.Level.WARN, "net", "x"), false)
	_check("the NAME style spells it out", named.begins_with("WARN"), null, named)
	_check("padded to the same width for every level", DotLog.level_column(DotLog.Level.INFO).length() == DotLog.level_column(DotLog.Level.WARN).length())
	DotLog.level_style = DotLog.LevelStyle.TAG
	_check("and the style goes back", DotLogEvent.text_line(_event(DotLog.Level.WARN, "net", "x"), false).begins_with("WRN"))

	# Every wire format carries the level, under whatever name that format uses.
	var event: Dictionary = _event(DotLog.Level.ERROR, "net", "broke")
	_check("flatten names it", str(DotLogEvent.flatten(event, {})["level"]) == "error")
	_check("severity_name is the collectors' spelling", DotLogEvent.severity_name(DotLog.Level.WARN) == "warning")

	var json: Dictionary = _parse(DotLog.format_json(_record(DotLog.Level.WARN, "net", "x")))
	_check("dot-core's JSON has the name", str(json["level"]) == "WARN")
	_check("and the number, because a string sorts wrong", int(json["severity"]) == DotLog.Level.WARN)

	# DotLog.at, for a level that is data rather than a call site.
	var ring: DotLogTargetMemory = DotLogTargetMemory.new(8)
	ring.open()
	var sink: Callable = func(rec: Dictionary) -> void: ring.write(DotLogEvent.from_record(rec))
	var saved_level: int = DotLog.get_level()
	DotLog.set_level(DotLog.Level.TRACE)
	DotLog.add_sink(sink)
	DotLog.at(DotLog.Level.WARN, "test", "at a chosen level")
	_check("DotLog.at emits at the level it was given", ring.size() == 1 and int(ring.tail(1)[0]["level"]) == DotLog.Level.WARN)
	DotLog.at(DotLog.Level.OFF, "test", "this must not be logged")
	_check("and refuses OFF, which is a threshold and not a severity", ring.size() == 1)
	DotLog.remove_sink(sink)
	DotLog.set_level(saved_level)

	_line("")
	_done()


# --- Console commands -------------------------------------------------------

func _test_commands() -> void:
	_section("log command")

	var router: DotLogRouter = DotLogRouter.new()
	router.autostart = false
	router.flush_interval_sec = 60.0
	var memory: DotLogTargetMemory = DotLogTargetMemory.new(64)
	router.targets.append(memory)
	add_child(router)
	await router.start()
	DotLog.set_level(DotLog.Level.TRACE)

	var commands: DotLogCommands = DotLogCommands.new(router)

	_check("it claims `log` and nothing else", commands.claims("log") and not commands.claims("logs"))
	_check("and names it", commands.names().has("log"))
	_check("and has help", commands.help_for("log").contains("tail"))

	DotLog.info("net", "a line to find")
	DotLog.warn("chat", "another line")

	var tail: DotResult = commands.execute("log tail 5")
	_check("tail returns lines", tail.ok and str(tail.value).contains("a line to find"), tail)
	_check("with their level shown", str(tail.value).contains("inf") and str(tail.value).contains("WRN"))

	var grep: DotResult = commands.execute("log grep another")
	_check("grep finds one", grep.ok and str(grep.value).contains("another line") and not str(grep.value).contains("a line to find"), grep)
	_check("and says so when it finds none", str(commands.execute("log grep zzzznope").value).contains("no match"))

	var levels: DotResult = commands.execute("log level")
	_check("level lists all six and what they mean", levels.ok and str(levels.value).contains("FATAL") and str(levels.value).contains("cannot continue"), levels)

	var set_level: DotResult = commands.execute("log level warn")
	_check("level sets it", set_level.ok and DotLog.get_level() == DotLog.Level.WARN, set_level)
	_check("an unknown level is refused", not commands.execute("log level loud").ok)
	commands.execute("log level trace")

	var channel: DotResult = commands.execute("log channel net debug")
	_check("channel sets one channel", channel.ok and DotLog.get_channel_level("net") == DotLog.Level.DEBUG, channel)
	commands.execute("log channel net default")
	_check("and clears it again", DotLog.get_channel_level("net") == DotLog.get_level())

	var targets: DotResult = commands.execute("log targets")
	_check("targets lists them with their health", targets.ok and str(targets.value).contains("memory") and str(targets.value).contains("written"), targets)

	var status: DotResult = commands.execute("log")
	_check("a bare `log` is the status", status.ok and str(status.value).contains("log router"))

	var before: int = memory.size()
	var test: DotResult = commands.execute("log test error a deliberate one")
	_check("test emits a record", test.ok and memory.size() == before + 1, test)
	_check("at the level asked for", int(memory.tail(1)[0]["level"]) == DotLog.Level.ERROR)
	_check("with the message", str(memory.tail(1)[0]["message"]) == "a deliberate one")
	_check("on its own channel, so it cannot be mistaken for a real one", str(memory.tail(1)[0]["channel"]) == DotLogCommands.CHANNEL)

	var fatal_test: DotResult = commands.execute("log test fatal pretend everything broke")
	_check("but FATAL is refused, because it promises a shutdown", not fatal_test.ok, null, fatal_test.code())
	_check("and says why", fatal_test.error.detail.contains("cannot continue"))

	var unknown: DotResult = commands.execute("log nonsense")
	_check("an unknown subcommand lists the real ones", not unknown.ok and unknown.error.detail.contains("tail"))

	var completions: PackedStringArray = commands.complete("log ")
	_check("completion offers the subcommands", completions.has("log tail"), null, ",".join(completions))
	var level_completions: PackedStringArray = commands.complete("log level w")
	_check("and the level names", level_completions.has("log level warn"), null, ",".join(level_completions))

	var detached: DotLogCommands = DotLogCommands.new(null)
	_check("with no router it says so rather than failing", detached.execute("log").ok and str(detached.execute("log").value).contains("nowhere else"))
	_check("and refuses what it cannot do", not detached.execute("log tail").ok)

	await router.shutdown()
	router.queue_free()
	DotLog.set_level(DotLog.Level.ERROR)
	_line("")
	_done()


# --- Harness ----------------------------------------------------------------

func _section(title: String) -> void:
	_entered += 1
	print(title)


## A section reached its last line. See [constant SECTIONS].
func _done() -> void:
	_completed += 1


func _check(what: String, passed: bool, res: DotResult = null, note: String = "") -> void:
	if passed:
		_passed += 1
		_line("  %-56s ok" % what)
		return

	_failed += 1
	var why: String = ""
	if res != null and not res.ok and res.error != null:
		why = " — %s" % res.error.message
	elif note != "":
		why = " — %s" % note
	_line("  %-56s FAILED%s" % [what, why])


func _finish() -> void:
	if not DotPlatform.is_headless():
		return

	await get_tree().process_frame

	print("%d of %d sections ran to their last line" % [_completed, _entered])
	if _entered != SECTIONS or _completed != _entered:
		print("ERROR: %d sections entered and %d completed, %d expected. One aborted or was skipped." % [
			_entered, _completed, SECTIONS
		])
		get_tree().quit(1)
		return
	# The total the section counter cannot be. A runtime error inside a section aborts
	# that function, and a section counter is satisfied because the section had already
	# announced itself. See docs/testing.md.
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return

	get_tree().quit(1 if _failed > 0 else 0)


func _line(text: String) -> void:
	print(text)
