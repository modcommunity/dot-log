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

## Maximum records held; 0 is unlimited.
var max_records: int = 4096:
	set(value):
		max_records = maxi(0, value)
		_queue.capacity = max_records

## Maximum bytes held, estimated from message and field sizes. 0 disables.
## Estimated because the encoded size is unknown until the format runs, and encoding a record that may be dropped is wasted work.
var max_bytes: int = 8 * 1024 * 1024:
	set(value):
		max_bytes = maxi(0, value)
		_queue.max_weight = max_bytes

var policy: Policy = Policy.DROP_OLDEST:
	set(value):
		policy = value
		_queue.policy = DotBoundedBuffer.Policy.DROP_OLDEST if value == Policy.DROP_OLDEST else DotBoundedBuffer.Policy.REFUSE

# The storage, bounds and counters live in the shared DotBoundedBuffer; this class adds the byte estimate and the drop notice.
var _queue: DotBoundedBuffer = DotBoundedBuffer.new()
var _drops_seen: int = 0
var _first_drop_ms: int = 0


func _init(p_max_records: int = 4096, p_policy: Policy = Policy.DROP_OLDEST) -> void:
	_queue.weigher = estimate_size
	max_records = p_max_records
	_queue.max_weight = max_bytes
	policy = p_policy


## Adds one event. Returns false if it was refused or displaced another.
func push(event: Dictionary) -> bool:
	var ok: bool = _queue.push(event)
	_note_drops()
	return ok


## Removes and returns up to [param count] events from the front, oldest first.
func take(count: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if count > 0:
		out.assign(_queue.take(count))
	return out


## Puts a batch back at the front, for a send that failed and will be retried.
## Order matters: a collector sorts by the timestamp the record carries, so these must stay ahead of newer ones.
## Over the bound the front is dropped even under DROP_NEWEST: the requeued batch is already in hand, and refusing it here would mean discarding records that have already been counted as accepted.
func requeue(events: Array[Dictionary]) -> void:
	_queue.requeue(events)
	_note_drops()


func peek(count: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	out.assign(_queue.peek(maxi(1, count)) if count > 0 else [])
	return out


func size() -> int:
	return _queue.size()


func byte_size() -> int:
	return _queue.weight()


func is_empty() -> bool:
	return _queue.is_empty()


func clear() -> void:
	_queue.clear()


func dropped() -> int:
	return _queue.dropped + _queue.refused


## A record describing the drops since the last call, and resets the count.
## Returned rather than logged: a log call from in here is the reentrancy [DotLogRouter] guards against.
func drain_drop_notice() -> Dictionary:
	if dropped() <= 0:
		return {}

	var notice: Dictionary = DotLogEvent.synthetic(
		DotLog.Level.WARN,
		CHANNEL,
		"log records were dropped; the buffer was full",
		{
			"dropped": dropped(),
			"bytes": _queue.dropped_weight + _queue.refused_weight,
			"policy": "oldest" if policy == Policy.DROP_OLDEST else "newest",
			"since": "%.1fs" % (
				float(Time.get_ticks_msec() - _first_drop_ms) / 1000.0
			),
		}
	)

	_queue.reset_counters()
	_drops_seen = 0
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


func _note_drops() -> void:
	var total: int = dropped()
	if total > _drops_seen and _first_drop_ms == 0:
		_first_drop_ms = Time.get_ticks_msec()
	_drops_seen = total


func describe() -> Dictionary:
	return {
		"records": _queue.size(),
		"bytes": _queue.weight(),
		"max_records": max_records,
		"max_bytes": max_bytes,
		"high_water": _queue.high_water,
		"dropped": dropped(),
		"policy": "oldest" if policy == Policy.DROP_OLDEST else "newest",
	}
