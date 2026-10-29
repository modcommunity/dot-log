class_name DotLogBuffer
extends RefCounted

## A bounded queue of events (records and bytes) with an explicit drop policy.
## An unbounded queue turns a collector outage into an out-of-memory kill.
## [constant DROP_OLDEST] (default) keeps the newest, [constant DROP_NEWEST] the earliest; drops are counted by [method drain_drop_notice].

enum Policy {
	DROP_OLDEST,  ## Discard from the front. Keeps the most recent.
	DROP_NEWEST,  ## Refuse the incoming record. Keeps the earliest.
}

const CHANNEL := "log.buffer"

## Maximum records held.
var max_records: int = 4096

## Maximum bytes held, estimated from message and field sizes. 0 disables.
## Estimated because the encoded size is unknown until the format runs, and encoding a record that may be dropped is wasted work.
var max_bytes: int = 8 * 1024 * 1024

var policy: Policy = Policy.DROP_OLDEST

var _events: Array[Dictionary] = []
var _bytes: int = 0
var _dropped: int = 0
var _dropped_bytes: int = 0
var _high_water: int = 0
var _first_drop_ms: int = 0


func _init(p_max_records: int = 4096, p_policy: Policy = Policy.DROP_OLDEST) -> void:
	max_records = maxi(1, p_max_records)
	policy = p_policy


## Adds one event. Returns false if it was refused or displaced another.
func push(event: Dictionary) -> bool:
	var size: int = estimate_size(event)

	if policy == Policy.DROP_NEWEST and _is_full(size):
		_note_drop(size)
		return false

	_events.append(event)
	_bytes += size

	var displaced: bool = false
	while _is_over():
		var gone: Dictionary = _events[0]
		_events.remove_at(0)
		_bytes -= estimate_size(gone)
		_note_drop(estimate_size(gone))
		displaced = true

	_high_water = maxi(_high_water, _events.size())
	return not displaced


## Removes and returns up to [param count] events from the front, oldest first.
func take(count: int) -> Array[Dictionary]:
	var n: int = mini(count, _events.size())
	var out: Array[Dictionary] = []
	if n <= 0:
		return out

	for i: int in range(n):
		var event: Dictionary = _events[i]
		out.append(event)
		_bytes -= estimate_size(event)

	# One slice, not n removals: remove_at on the front is O(size) each time, which
	# makes draining a full queue quadratic exactly when it is under pressure.
	_events = _events.slice(n)
	_bytes = maxi(0, _bytes)
	return out


## Puts a batch back at the front, for a send that failed and will be retried.
## Order matters: a collector sorts by the timestamp the record carries, so these must stay ahead of newer ones.
func requeue(events: Array[Dictionary]) -> void:
	if events.is_empty():
		return

	var combined: Array[Dictionary] = events.duplicate()
	combined.append_array(_events)
	_events = combined

	_bytes = 0
	for event: Dictionary in _events:
		_bytes += estimate_size(event)

	while _is_over():
		# Dropping from the front even under DROP_NEWEST: the requeued batch is already
		# in hand, and refusing it here would mean discarding records that have already
		# been counted as accepted.
		var gone: Dictionary = _events[0]
		_events.remove_at(0)
		_bytes -= estimate_size(gone)
		_note_drop(estimate_size(gone))


func peek(count: int) -> Array[Dictionary]:
	return _events.slice(0, mini(count, _events.size()))


func size() -> int:
	return _events.size()


func byte_size() -> int:
	return _bytes


func is_empty() -> bool:
	return _events.is_empty()


func clear() -> void:
	_events.clear()
	_bytes = 0


func dropped() -> int:
	return _dropped


## A record describing the drops since the last call, and resets the count.
## Returned rather than logged: a log call from in here is the reentrancy [DotLogRouter] guards against.
func drain_drop_notice() -> Dictionary:
	if _dropped <= 0:
		return {}

	var notice: Dictionary = DotLogEvent.synthetic(
		DotLog.Level.WARN,
		CHANNEL,
		"log records were dropped; the buffer was full",
		{
			"dropped": _dropped,
			"bytes": _dropped_bytes,
			"policy": "oldest" if policy == Policy.DROP_OLDEST else "newest",
			"since": "%.1fs" % (
				float(Time.get_ticks_msec() - _first_drop_ms) / 1000.0
			),
		}
	)

	_dropped = 0
	_dropped_bytes = 0
	_first_drop_ms = 0
	return notice


## A generous guess at what one event will cost on the wire.
static func estimate_size(event: Dictionary) -> int:
	var n: int = 64  # envelope: timestamps, level, seq, punctuation
	n += String(event.get("message", "")).length()
	n += String(event.get("channel", "")).length()

	var fields: Dictionary = event.get("fields", {})
	for k: Variant in fields:
		n += str(k).length() + 8
		var v: Variant = fields[k]
		match typeof(v):
			TYPE_STRING, TYPE_STRING_NAME:
				n += str(v).length()
			TYPE_DICTIONARY, TYPE_ARRAY:
				# Not walked: a nested structure is rare in a log field and walking it
				# per push would make the estimate cost more than the copy.
				n += 128
			_:
				n += 16

	return n


func _is_full(incoming: int) -> bool:
	if _events.size() >= max_records:
		return true
	if max_bytes > 0 and _bytes + incoming > max_bytes:
		return true
	return false


func _is_over() -> bool:
	if _events.size() > max_records:
		return true
	if max_bytes > 0 and _bytes > max_bytes and _events.size() > 1:
		# Never below one record: a single event larger than the whole byte budget must
		# still go somewhere, and an empty queue that refuses everything is a worse bug
		# than one oversized payload.
		return true
	return false


func _note_drop(bytes: int) -> void:
	if _dropped == 0:
		_first_drop_ms = Time.get_ticks_msec()
	_dropped += 1
	_dropped_bytes += bytes


func describe() -> Dictionary:
	return {
		"records": _events.size(),
		"bytes": _bytes,
		"max_records": max_records,
		"max_bytes": max_bytes,
		"high_water": _high_water,
		"dropped": _dropped,
		"policy": "oldest" if policy == Policy.DROP_OLDEST else "newest",
	}
