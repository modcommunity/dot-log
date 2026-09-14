@tool
class_name DotLogRouter
extends Node

## Attaches to [DotLog] once and fans every record out to the targets.
##
## This is the node a project places. [DotLog] stays exactly what it was — the thing
## fifty-odd addons call, with no dependency on this one — and everything about where the
## records go is decided here, in one place, at the host's discretion.
##
## [codeblock]
## var router := DotLogRouter.new()
## router.set_context({"service": "arena", "env": "prod", "host": "eu-1"})
## router.add_target(DotLogTargetFile.new("user://logs", "arena"))
## router.add_target(DotLogTargetMemory.new(512))
## add_child(router)          # starts on _ready
## [/codeblock]
##
## [b]Not an autoload, like everything else here.[/b] A process running a server and a
## client — which is every listen server, and every headless test of one — has two of
## these, with different targets and different context, and an autoload could not
## express that.
##
## [b]The reentrancy guard is the load-bearing part of this file.[/b] A target that calls
## [DotLog] from inside [method DotLogTarget.write] re-enters the sink it is being called
## from, which calls the target, which logs again: a stack overflow that takes the
## process down, from a diagnostic. It is not a hypothetical — the natural way to report
## that a log file could not be opened is to log it. So [member _dispatching] is checked
## before anything, and a record produced while dispatching is counted and dropped.

const CHANNEL := "log.router"

## Emitted for every record after the targets have taken it.
##
## For UI that wants records live — a console, an admin overlay — without registering a
## sink of its own. The payload is the enriched event, not [DotLog]'s raw record.
signal routed(event: Dictionary)

## Emitted when a target's [method DotLogTarget.flush] fails, so a server can put its
## shipper's health somewhere an operator sees it.
signal target_failed(target_name: String, error: DotError)

@export_group("Lifecycle")

## Attach to [DotLog] on [method Node._ready].
##
## Off for a router assembled in code that wants to add its targets first. [method start]
## does it by hand.
@export var autostart: bool = true

## Seconds between flushes.
##
## 2 seconds is a compromise: a shorter interval means more, smaller HTTP requests and
## more file writes; a longer one is more log lost to a hard kill. Targets that need to
## go sooner say so — see [member DotLogTargetHttp.send_immediately_above].
@export_range(0.1, 300.0, 0.1) var flush_interval_sec: float = 2.0

@export_group("Pipeline")

## Applied to every record before any target sees it. Null disables redaction.
##
## One redactor in front of all of them rather than one per target, because a secret
## that must not reach a hosted collector must not reach the file either — the file gets
## attached to bug reports.
@export var redactor: DotLogRedactor = null

## Applied before the per-target gates. Null passes everything [DotLog] emitted.
@export var gate: DotLogGate = null

## The targets, in order. A target may be added and removed at runtime.
@export var targets: Array[DotLogTarget] = []

@export_group("DotLog")

## Set [member DotLog.print_to_stdout] on start. -1 leaves it alone.
##
## A server with a file target usually still wants stdout, because that is what the
## process supervisor captures. A shipped client usually does not.
@export_enum("leave:-1", "off:0", "on:1") var stdout_on_start: int = -1

## Set [member DotLog.mirror_min_level] on start, or -1 to leave it.
##
## [b]This is where the stack traces come from.[/b] [DotLog] mirrors serious records
## through [method push_warning] / [method push_error] so they reach the editor's Errors
## dock, and in a debug build the engine appends an [code]at:[/code] line and a full
## GDScript backtrace to each one — with no way to turn that off per call. At WARN that
## turns every recoverable, expected warning into eight lines of stderr that read like a
## crash. ERROR is [DotLog]'s own default and the right one for a server; set it to
## [constant DotLog.Level.WARN] while hunting where one particular warning comes from.
@export_enum(
	"leave:-1", "trace:0", "debug:1", "info:2", "warn:3", "error:4", "fatal:5", "off:6"
) var mirror_min_level: int = -1

## Context tags attached to every shipped record: service, env, host, instance, version.
##
## Not written into the human file format — an admin reading their own server's log
## already knows which server it is — but essential everywhere else, because a collector
## holding four servers' records and no way to tell them apart is a collector nobody uses
## twice.
var context: Dictionary = {}

var _sink: Callable
var _timer: Timer = null
var _http_nodes: Array[DotHttp] = []
var _started: bool = false
var _dispatching: bool = false

var _received: int = 0
var _routed: int = 0
var _gated: int = 0
var _reentrant: int = 0
var _flushes: int = 0


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	if autostart:
		# Awaited: start() suspends while opening targets, and a coroutine called
		# without await returns null rather than its result — which would then be a
		# null dereference on the line below. See docs/gdscript-hazards.md.
		var res: DotResult = await start()
		if not res.ok:
			DotLog.result(CHANNEL, "starting the log router", res)


func _exit_tree() -> void:
	if _started:
		stop()


# --- Lifecycle -------------------------------------------------------------

## Opens every target and attaches to [DotLog].
##
## A target that fails to open is disabled and reported; the rest carry on. Logging that
## degrades to fewer destinations is always better than logging that refuses to start,
## because the second one takes the server with it.
func start() -> DotResult:
	if _started:
		return DotResult.fail(DotError.CODE_STATE, "The log router is already started.")

	if stdout_on_start >= 0:
		DotLog.print_to_stdout = stdout_on_start == 1
	if mirror_min_level >= 0:
		DotLog.mirror_min_level = mirror_min_level

	if redactor != null:
		var compiled: DotResult = redactor.compile()
		if not compiled.ok:
			DotLog.result(CHANNEL, "compiling redaction patterns", compiled)

	var failures: PackedStringArray = PackedStringArray()

	for target: DotLogTarget in targets:
		var opened: DotResult = await _open_target(target)
		if not opened.ok:
			failures.append("%s: %s" % [target.target_name, opened.error.message])

	_timer = Timer.new()
	_timer.name = "FlushTimer"
	_timer.wait_time = flush_interval_sec
	_timer.autostart = true
	_timer.timeout.connect(_on_flush_timer)
	add_child(_timer)

	_sink = _ingest
	DotLog.add_sink(_sink)
	_started = true

	DotLog.info(
		CHANNEL,
		"log router started",
		{"targets": targets.size(), "interval": flush_interval_sec}
	)

	if not failures.is_empty():
		return DotResult.fail(
			DotError.CODE_IO,
			"%d of %d log targets could not be opened." % [
				failures.size(), targets.size()
			],
			"; ".join(failures)
		)

	return DotResult.success(targets.size())


## Detaches from [DotLog] and closes every target, flushing what is buffered.
##
## [b]Synchronous, and that is a real limitation rather than an oversight.[/b] This runs
## from [method Node._exit_tree], where the tree is coming down and awaiting a network
## round trip is not something that can be relied on to complete. File, memory, syslog
## and SQL targets write what they hold; an HTTP target loses whatever has not gone out.
## Call [method shutdown] instead for a clean exit that waits.
func stop() -> void:
	if _sink.is_valid():
		DotLog.remove_sink(_sink)

	if _timer != null and is_instance_valid(_timer):
		_timer.queue_free()
		_timer = null

	for target: DotLogTarget in targets:
		if not target.is_buffered():
			target.close()
			continue
		# Not awaited: see above. A target whose flush is a coroutine runs to its first
		# suspension and no further, which for a file target is the whole of it.
		target.flush()
		target.close()

	_started = false


## Flushes everything and then stops. The clean path out of a process.
##
## [codeblock]
## await router.shutdown()
## get_tree().quit()
## [/codeblock]
func shutdown() -> void:
	if not _started:
		return
	await flush_all()
	stop()


func is_started() -> bool:
	return _started


# --- Targets ---------------------------------------------------------------

## Adds a target and opens it. Returns the open result.
func add_target(target: DotLogTarget) -> DotResult:
	if target == null:
		return DotResult.fail(DotError.CODE_INVALID, "A null log target.")

	targets.append(target)

	if not _started:
		return DotResult.success(target.target_name)

	return await _open_target(target)


## Removes a target, flushing and closing it first.
func remove_target(target: DotLogTarget) -> void:
	if not targets.has(target):
		return
	if target.is_buffered():
		await target.flush()
	target.close()
	targets.erase(target)


## The first target with this name, or null.
##
## The parameter is not called `name`: this is a [Node], [Node] has a `name`, and
## shadowing it is how a method quietly reads the node's own name instead.
func find_target(wanted: String) -> DotLogTarget:
	for target: DotLogTarget in targets:
		if target.target_name == wanted:
			return target
	return null


func _open_target(target: DotLogTarget) -> DotResult:
	# Context is pushed rather than pulled so a target does not need a reference back to
	# the router — which would be a cycle between a Node and a Resource it holds.
	if target.has_method("set_context"):
		target.call("set_context", context)

	if target is DotLogTargetHttp:
		var http_target: DotLogTargetHttp = target as DotLogTargetHttp
		if http_target.http == null:
			http_target.http = _make_http()

	var opened: DotResult = await target.open()
	if opened == null:
		opened = DotResult.success(null)

	if not opened.ok:
		# Disabled rather than removed: the configuration is still visible in describe(),
		# which is how an operator finds out why nothing is arriving.
		target.enabled = false
		DotLog.warn(
			CHANNEL,
			"a log target could not be opened",
			{
				"target": target.target_name,
				"why": opened.error.message,
				"detail": opened.error.detail,
			}
		)

	return opened


func _make_http() -> DotHttp:
	var http: DotHttp = DotHttp.new()
	http.name = "LogHttp%d" % (_http_nodes.size() + 1)
	# The user agent is how a collector's operator identifies what is filling their
	# quota, which is a question they do ask.
	http.user_agent = "dot-log/0.1 (Godot)"
	add_child(http)
	_http_nodes.append(http)
	return http


# --- Context ---------------------------------------------------------------

## Replaces the context tags and pushes them to every target.
func set_context(new_context: Dictionary) -> void:
	context = new_context.duplicate()
	_push_context()


## Sets one tag. The common case at runtime is the map or the match id changing.
func set_tag(key: String, value: Variant) -> void:
	context[key] = value
	_push_context()


func _push_context() -> void:
	for target: DotLogTarget in targets:
		if target.has_method("set_context"):
			target.call("set_context", context)


# --- Records ---------------------------------------------------------------

## The sink [DotLog] calls. Never call this directly.
func _ingest(record: Dictionary) -> void:
	if _dispatching:
		# A target logged from inside write(). Counted and dropped: the alternative is
		# unbounded recursion, and a logger that can crash the process it is
		# instrumenting is worse than a logger that loses a line about itself.
		_reentrant += 1
		return

	_received += 1

	var event: Dictionary = DotLogEvent.from_record(record)

	if gate != null and not gate.allows(event):
		_gated += 1
		return

	if redactor != null:
		event = redactor.apply(event)

	_dispatch(event)


func _dispatch(event: Dictionary) -> void:
	_dispatching = true

	for target: DotLogTarget in targets:
		if target.accepts(event):
			target.write(event)

	_dispatching = false
	_routed += 1

	# Emitted outside the guard on purpose: a listener is entitled to log, and a
	# listener is not a target — it cannot re-enter a write that has already finished.
	routed.emit(event)


## Injects an event that did not come through [DotLog].
##
## For the records this addon makes about itself — dropped-record notices, repeat
## summaries — which must not be logged normally, because they are produced from inside
## the dispatch the guard above is protecting.
func inject(event: Dictionary) -> void:
	if _dispatching:
		return
	_dispatch(event)


# --- Flushing --------------------------------------------------------------

func _on_flush_timer() -> void:
	# Not awaited: a Timer's callback is not a coroutine and the flush may take longer
	# than the interval. The per-target `_sending` guards make an overlapping call a
	# no-op rather than a double send.
	flush_all()


## Flushes every buffered target, and emits the pipeline's own summaries first.
func flush_all() -> void:
	_flushes += 1

	if gate != null:
		for summary: Dictionary in gate.drain_summaries():
			_dispatch(summary)

	for target: DotLogTarget in targets:
		if not target.enabled or not target.is_buffered():
			continue

		var res: DotResult = await target.flush()
		if res != null and not res.ok:
			target_failed.emit(target.target_name, res.error)


# --- Diagnostics -----------------------------------------------------------

func describe() -> Dictionary:
	return {
		"started": _started,
		"targets": targets.size(),
		"received": _received,
		"routed": _routed,
		"gated": _gated,
		"reentrant_dropped": _reentrant,
		"flushes": _flushes,
		"context": context,
	}


func describe_lines() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	out.append("log router: %s, %d targets, %d records in, %d out" % [
		"started" if _started else "stopped", targets.size(), _received, _routed
	])

	if _reentrant > 0:
		out.append("  %d records dropped as reentrant (a target logged from write())"
			% _reentrant)

	if gate != null:
		out.append("  gate: " + str(gate.describe()))

	if redactor != null:
		out.append("  redactor: " + str(redactor.describe()))

	for target: DotLogTarget in targets:
		out.append("  target %s" % target.target_name)
		out.append_array(target.describe_lines())

	return out


## Whether every enabled target is currently working.
##
## The question a health endpoint asks. A server whose shipper has been failing for an
## hour is a server nobody is watching, which is worth knowing separately from whether
## the server itself is up.
func is_healthy() -> bool:
	for target: DotLogTarget in targets:
		if not target.enabled:
			continue
		if not target.is_open():
			return false
		if target is DotLogTargetHttp and (target as DotLogTargetHttp).circuit_open_sec() > 0.0:
			return false
	return true
