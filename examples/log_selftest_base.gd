extends Node

## Shared state and harness for the dot-log self-test; the checks live in the subclasses.

const CHECKS := 457

## Sections entered against sections run to their last line. A runtime error aborts a
## section silently, so an early bail-out counts as unfinished on purpose; CHECKS is the
## other half (docs/testing.md).
const SECTIONS := 27

var _passed := 0
var _failed := 0
var _entered := 0
var _completed := 0

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
