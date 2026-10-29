@tool
class_name DotLogTarget
extends Resource

## Somewhere a log record goes. One of these per destination, owned by [DotLogRouter].
## [method write] must not block, must not log (reentrancy), must not mutate the event; a failure is survivable and visible through [method health].
## A [Resource] so logging can be built in the inspector and saved as a [code].tres[/code].

# No log channel, and there must never be one: a target runs inside a log call, and a
# target that logged would re-enter the router (the second rule above). Its failures are
# returned and reported through health(), which DotLogRouter surfaces.

## Short name, for [method describe] and for the console listing. Unique within a router.
@export var target_name: String = "target"

## Whether this target takes records at all. A disabled target keeps its configuration
## and its counters, which is what makes it useful as a runtime switch.
@export var enabled: bool = true

## What this target accepts, over and above [DotLog]'s own threshold.
## Null means everything; this is where "file keeps DEBUG, collector gets WARN" is expressed.
@export var gate: DotLogGate = null

var _written: int = 0
var _failed: int = 0
var _last_error: String = ""
var _last_error_ms: int = 0
var _opened: bool = false


## Prepares the destination: opens the file, resolves the socket, creates the table.
## Failing is not fatal to the router; this target is left closed and says so.
func open() -> DotResult:
	_opened = true
	return DotResult.success(null)


## Releases whatever [method open] acquired. Must be safe to call twice.
func close() -> void:
	_opened = false


func is_open() -> bool:
	return _opened


## Whether this target wants this event. Cheap, and called once per event per target.
func accepts(event: Dictionary) -> bool:
	if not enabled:
		return false
	if gate != null and not gate.allows(event):
		return false
	return true


## Takes one event. Must return promptly and must not call [DotLog].
## The base implementation only counts; a queueing subclass can call [code]super(event)[/code].
func write(event: Dictionary) -> void:
	_written += 1


## Sends or persists whatever [method write] has queued.
## May be a coroutine (the router awaits it). Returns the number of records dealt with.
func flush() -> DotResult:
	return DotResult.success(0)


## Whether [method flush] does real work, so the router can skip an await per tick.
func is_buffered() -> bool:
	return false


## Records waiting to be flushed. 0 for a target that writes as it goes.
func pending() -> int:
	return 0


## Records this target has accepted.
func written() -> int:
	return _written


func failed() -> int:
	return _failed


## Records a failure for [method health]. Never logs: see the rules above.
func note_failure(res: DotResult) -> void:
	_failed += 1
	_last_error_ms = Time.get_ticks_msec()
	if res != null and res.error != null:
		_last_error = res.error.message
		if res.error.detail != "":
			_last_error += " (" + res.error.detail + ")"


## Whether this target is currently working, and what went wrong if not.
## Separate from [method describe] because this is the half a monitoring endpoint wants.
func health() -> Dictionary:
	return {
		"target": target_name,
		"open": _opened,
		"enabled": enabled,
		"written": _written,
		"failed": _failed,
		"pending": pending(),
		"last_error": _last_error,
		"stale_sec": (
			float(Time.get_ticks_msec() - _last_error_ms) / 1000.0
			if _last_error_ms > 0 else -1.0
		),
	}


func describe() -> Dictionary:
	var out: Dictionary = health()
	if gate != null:
		out["gate"] = gate.describe()
	return out


func describe_lines() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var d: Dictionary = describe()
	var keys: Array = d.keys()
	keys.sort()
	for k: Variant in keys:
		out.append("  %-12s %s" % [str(k), str(d[k])])
	return out
