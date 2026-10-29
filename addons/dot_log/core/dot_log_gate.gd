@tool
class_name DotLogGate
extends Resource

## Decides which records get past, and collapses the ones that repeat.
## Four stages, cheapest first: level and channel, per-level sampling, deduplication over a window, a per-channel rate limit.
## Suppression is never silent: [method drain_summaries] returns one synthetic record per collapsed group.

# No `const CHANNEL`. A gate sits inside the log pipeline, so a record from here would go
# back through the gate that raised it; what it drops it reports as a synthetic summary.

## Minimum level to pass. Independent of [DotLog]'s own threshold, which has already
## been applied — this can only ever narrow it further.
@export var min_level: DotLog.Level = DotLog.Level.TRACE

## Channels to pass, as exact names or [code]prefix.*[/code] patterns. Empty passes all.
@export var channels: PackedStringArray = PackedStringArray()

## Channels to refuse, checked after [member channels]. A deny always wins.
@export var deny_channels: PackedStringArray = PackedStringArray()

@export_group("Sampling")

## Fraction of TRACE records to keep, 0 to 1.
## Sampling applies to TRACE and DEBUG only: a sampled state change at INFO is a lie.
@export_range(0.0, 1.0, 0.01) var trace_sample: float = 1.0

@export_range(0.0, 1.0, 0.01) var debug_sample: float = 1.0

@export_group("Deduplication")

## Seconds an identical line is collapsed for. 0 disables deduplication.
@export_range(0.0, 600.0, 0.5) var dedupe_window_sec: float = 0.0

## Levels at or above this are never deduplicated.
## ERROR by default: a count alone does not carry the fields that tell ten thousand errors from one.
@export var dedupe_below_level: DotLog.Level = DotLog.Level.ERROR

## Distinct lines tracked at once. Beyond this the oldest tracking entry is forgotten,
## which lets its next copy through — a leak-free failure mode, and the right one.
@export_range(16, 65536, 16) var dedupe_capacity: int = 1024

@export_group("Rate limit")

## Records per second per channel. 0 disables the limit.
@export_range(0.0, 10000.0, 1.0) var per_channel_rate: float = 0.0

## Burst allowance, so a legitimate spike at map change is not clipped.
@export_range(1.0, 10000.0, 1.0) var per_channel_burst: float = 200.0

## Levels at or above this bypass the rate limit entirely.
@export var rate_limit_below_level: DotLog.Level = DotLog.Level.ERROR

var _rng := RandomNumberGenerator.new()
var _limiter: DotRateLimiter = null

## key -> {"count": int, "first_ms": int, "last_ms": int, "event": Dictionary}
var _repeats: Dictionary = {}

## Summaries for windows that have already closed, waiting for the next flush.
var _pending: Array[Dictionary] = []

var _passed: int = 0
var _dropped_level: int = 0
var _dropped_sample: int = 0
var _dropped_dedupe: int = 0
var _dropped_rate: int = 0


func _init() -> void:
	_rng.randomize()


## Whether this event should be written.
## Call once per event per target: the dedupe counters and rate-limit buckets advance as a side effect.
func allows(event: Dictionary) -> bool:
	var level: int = int(event.get("level", DotLog.Level.INFO))
	var channel: String = String(event.get("channel", ""))

	if level < min_level:
		_dropped_level += 1
		return false

	if not _channel_allowed(channel):
		_dropped_level += 1
		return false

	if not _sampled(level):
		_dropped_sample += 1
		return false

	if not _deduped(event, level):
		_dropped_dedupe += 1
		return false

	if not _within_rate(channel, level):
		_dropped_rate += 1
		return false

	_passed += 1
	return true


## One synthetic event per group of collapsed repeats, and clears the groups.
## Called on every router flush, so a summary arrives even for a flood that has just stopped.
func drain_summaries() -> Array[Dictionary]:
	var now: int = Time.get_ticks_msec()
	var window_ms: int = int(dedupe_window_sec * 1000.0)

	var stale: Array = []
	for key: Variant in _repeats:
		var entry: Dictionary = _repeats[key]
		if now - int(entry["first_ms"]) < window_ms:
			continue
		# The window closed and nothing has arrived since to close it from the inside.
		_close_window(entry)
		stale.append(key)

	for key: Variant in stale:
		_repeats.erase(key)

	var out: Array[Dictionary] = _pending
	_pending = []
	return out


## Turns a closed window's count into a summary event, if there is anything to say.
func _close_window(entry: Dictionary) -> void:
	var count: int = int(entry["count"])
	if count <= 0:
		return

	var original: Dictionary = entry["event"]
	var elapsed: float = float(int(entry["last_ms"]) - int(entry["first_ms"])) / 1000.0

	_pending.append(DotLogEvent.synthetic(
		int(original.get("level", DotLog.Level.INFO)),
		String(original.get("channel", "")),
		String(original.get("message", "")),
		{
			"repeated": count,
			"over": "%.1fs" % elapsed,
			"suppressed_by": "dot-log",
		}
	))


func _channel_allowed(channel: String) -> bool:
	if not channels.is_empty() and not _matches(channel, channels):
		return false
	if not deny_channels.is_empty() and _matches(channel, deny_channels):
		return false
	return true


func _matches(channel: String, list: PackedStringArray) -> bool:
	for pattern: String in list:
		if pattern == channel:
			return true
		if pattern.ends_with("*") and channel.begins_with(pattern.substr(0, pattern.length() - 1)):
			return true
	return false


func _sampled(level: int) -> bool:
	if level == DotLog.Level.TRACE and trace_sample < 1.0:
		return _rng.randf() < trace_sample
	if level == DotLog.Level.DEBUG and debug_sample < 1.0:
		return _rng.randf() < debug_sample
	return true


func _deduped(event: Dictionary, level: int) -> bool:
	if dedupe_window_sec <= 0.0 or level >= dedupe_below_level:
		return true

	var key: String = DotLogEvent.repeat_key(event)
	var now: int = Time.get_ticks_msec()
	var window_ms: int = int(dedupe_window_sec * 1000.0)

	if not _repeats.has(key):
		if _repeats.size() >= dedupe_capacity:
			# Forgetting the oldest rather than refusing to track: an unbounded table
			# keyed by message text is a memory leak driven by attacker input, which is
			# a worse failure than letting a duplicate through.
			_forget_oldest()
		_repeats[key] = {"count": 0, "first_ms": now, "last_ms": now, "event": event}
		return true

	var entry: Dictionary = _repeats[key]

	if now - int(entry["first_ms"]) >= window_ms:
		# The window closed: this copy opens the next one and goes through. The old count is
		# summarised now, otherwise a steadily repeating line would be summarised only after
		# it finally stopped.
		_close_window(entry)
		entry["count"] = 0
		entry["first_ms"] = now
		entry["last_ms"] = now
		entry["event"] = event
		return true

	entry["count"] = int(entry["count"]) + 1
	entry["last_ms"] = now
	return false


func _forget_oldest() -> void:
	var oldest_key: Variant = null
	var oldest_ms: int = 0x7FFFFFFF

	for key: Variant in _repeats:
		var entry: Dictionary = _repeats[key]
		var last: int = int(entry["last_ms"])
		if last < oldest_ms:
			oldest_ms = last
			oldest_key = key

	if oldest_key != null:
		_repeats.erase(oldest_key)


func _within_rate(channel: String, level: int) -> bool:
	if per_channel_rate <= 0.0 or level >= rate_limit_below_level:
		return true

	if _limiter == null:
		_limiter = DotRateLimiter.new(per_channel_rate, per_channel_burst)

	return _limiter.allow(channel)


## Counters, for [method describe] and for the suite.
func stats() -> Dictionary:
	return {
		"passed": _passed,
		"dropped_level": _dropped_level,
		"dropped_sample": _dropped_sample,
		"dropped_dedupe": _dropped_dedupe,
		"dropped_rate": _dropped_rate,
		"tracked": _repeats.size(),
		"pending_summaries": _pending.size(),
	}


func describe() -> Dictionary:
	var out: Dictionary = stats()
	out["min_level"] = DotLog.level_name(min_level)
	out["channels"] = ",".join(channels) if not channels.is_empty() else "*"
	out["dedupe_sec"] = dedupe_window_sec
	out["rate"] = per_channel_rate
	return out
