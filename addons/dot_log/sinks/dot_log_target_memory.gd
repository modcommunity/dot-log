@tool
class_name DotLogTargetMemory
extends DotLogTarget

## Keeps the last N records in memory, and nothing else.
## A ring on purpose: serves the in-game console, bug reports and Sentry breadcrumbs, and a client left overnight must not grow.
## On a dedicated server, [method tail] is the cheapest [code]status[/code] command.

const SELF_CHANNEL := "log.memory"

## Records kept. Beyond this the oldest is discarded.
## 512 is about 60 KB of typical records: small for a client, enough for the minute before a crash.
@export_range(16, 100000, 16) var capacity: int = 512

## Records below this level are not kept even if the gate passed them.
## Distinct from the gate so a console can hold DEBUG while a bug-report ring holds INFO and above.
@export var min_level: DotLog.Level = DotLog.Level.TRACE

var _ring: Array[Dictionary] = []
var _discarded: int = 0


func _init(p_capacity: int = 0) -> void:
	target_name = "memory"
	if p_capacity > 0:
		capacity = p_capacity


func open() -> DotResult:
	_opened = true
	return DotResult.success(capacity)


func close() -> void:
	_opened = false
	# The ring is deliberately NOT cleared: a router shutting down is often a process
	# shutting down, and that is exactly when something wants to read the last lines.


func write(event: Dictionary) -> void:
	if int(event.get("level", DotLog.Level.INFO)) < min_level:
		return

	super(event)
	_ring.append(event)

	if _ring.size() > capacity:
		# One at a time, because push is the only thing that grows it: the ring can
		# never be more than one over.
		_ring.remove_at(0)
		_discarded += 1


## The most recent [param count] records, oldest first.
func tail(count: int = 0) -> Array[Dictionary]:
	if count <= 0 or count >= _ring.size():
		return _ring.duplicate()
	return _ring.slice(_ring.size() - count)


## The records matching a filter, oldest first.
## [param needle] matches case-insensitively against the message and every field value ("the line with that player's name").
func matching(
	needle: String = "",
	channel: String = "",
	level: int = DotLog.Level.TRACE,
	limit: int = 0
) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var lower: String = needle.to_lower()

	for event: Dictionary in _ring:
		if int(event.get("level", 2)) < level:
			continue
		if channel != "" and String(event.get("channel", "")) != channel:
			continue
		if lower != "" and not _contains(event, lower):
			continue
		out.append(event)

	if limit > 0 and out.size() > limit:
		return out.slice(out.size() - limit)
	return out


func _contains(event: Dictionary, lower_needle: String) -> bool:
	if String(event.get("message", "")).to_lower().contains(lower_needle):
		return true
	var fields: Dictionary = event.get("fields", {})
	for k: Variant in fields:
		if str(fields[k]).to_lower().contains(lower_needle):
			return true
	return false


## The ring as text, which is what goes into a bug report.
func to_text(count: int = 0) -> String:
	var lines: PackedStringArray = PackedStringArray()
	for event: Dictionary in tail(count):
		lines.append(DotLogEvent.text_line(event))
	return "\n".join(lines)


## The ring as the breadcrumb list an error tracker wants, oldest first.
func breadcrumbs(count: int = 0) -> Array:
	var out: Array = []
	for event: Dictionary in tail(count):
		out.append({
			"timestamp": DotLogEvent.time_sec(event),
			"level": String(event.get("severity", "info")),
			"category": String(event.get("channel", "")),
			"message": String(event.get("message", "")),
			"data": DotLogEvent.json_fields(event.get("fields", {})),
		})
	return out


func size() -> int:
	return _ring.size()


func clear() -> void:
	_ring.clear()


func describe() -> Dictionary:
	var out: Dictionary = super()
	out["held"] = _ring.size()
	out["capacity"] = capacity
	out["discarded"] = _discarded
	return out
