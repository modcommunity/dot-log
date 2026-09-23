@tool
class_name DotLogTarget
extends Resource

## Somewhere a log record goes. One of these per destination.
##
## [DotLogRouter] owns a list of them and hands every record to every one, so a server
## can write a file for the admin, keep a ring in memory for the console, and ship WARN
## and above to a collector, from one log call — which is the point of the whole addon.
##
## Four rules a target must obey, each of which is a specific failure somebody has had:
##
## - [b][method write] must not block.[/b] It is called from inside a log call, which is
##   called from inside gameplay. A target that does a network round trip in [method
##   write] has moved the collector's latency into the frame time; queue instead, and do
##   the work in [method flush].
## - [b][method write] must not log.[/b] Not through [DotLog], not once. See
##   [DotLogRouter]'s reentrancy guard for what that costs.
## - [b]A failure must be survivable and visible.[/b] Return the failure, keep taking
##   records, and let [method health] say what is wrong. A target that throws away the
##   log because its disk is full has made the incident harder to investigate.
## - [b]Never mutate the event.[/b] Every other target is about to be handed the same
##   [Dictionary].
##
## A [Resource] so that a project can build its logging in the inspector, save it as a
## [code].tres[/code], and give every one of its servers the same one.

# No log channel, and there must never be one: a target runs inside a log call, and a
# target that logged would re-enter the router (the second rule above). Its failures are
# returned and reported through health(), which DotLogRouter surfaces.

## Short name, for [method describe] and for the console listing. Unique within a router.
@export var target_name: String = "target"

## Whether this target takes records at all. A disabled target keeps its configuration
## and its counters, which is what makes it useful as a runtime switch.
@export var enabled: bool = true

## What this target accepts, over and above [DotLog]'s own threshold.
##
## Null means everything that reaches the router. This is where "the file keeps DEBUG
## and the hosted collector gets WARN and above" is expressed.
@export var gate: DotLogGate = null

var _written: int = 0
var _failed: int = 0
var _last_error: String = ""
var _last_error_ms: int = 0
var _opened: bool = false


# --- Lifecycle -------------------------------------------------------------

## Prepares the destination: opens the file, resolves the socket, creates the table.
##
## Called by the router before the first record. Failing here is not fatal to the router
## — the other targets carry on — but this target is left closed and says so.
func open() -> DotResult:
	_opened = true
	return DotResult.success(null)


## Releases whatever [method open] acquired. Must be safe to call twice.
func close() -> void:
	_opened = false


func is_open() -> bool:
	return _opened


# --- Records ---------------------------------------------------------------

## Whether this target wants this event. Cheap, and called once per event per target.
func accepts(event: Dictionary) -> bool:
	if not enabled:
		return false
	if gate != null and not gate.allows(event):
		return false
	return true


## Takes one event. Must return promptly and must not call [DotLog].
##
## The base implementation only counts, so a subclass that queues can call
## [code]super(event)[/code] and get its counters for free.
func write(event: Dictionary) -> void:
	_written += 1


## Sends or persists whatever [method write] has queued.
##
## May be a coroutine — the router always awaits it. Returns the number of records
## dealt with, so a caller can tell "nothing to do" from "sent forty".
func flush() -> DotResult:
	return DotResult.success(0)


## Whether [method flush] does real work, so the router can skip an await per tick.
func is_buffered() -> bool:
	return false


## Records waiting to be flushed. 0 for a target that writes as it goes.
func pending() -> int:
	return 0


# --- Diagnostics -----------------------------------------------------------

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
##
## Separate from [method describe] because this is the half a monitoring endpoint wants:
## a server whose log shipper has been failing for an hour is a server nobody is
## watching, and that is worth an alert of its own.
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
