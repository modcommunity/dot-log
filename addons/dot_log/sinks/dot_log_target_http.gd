@tool
class_name DotLogTargetHttp
extends DotLogTarget

## Ships records to a collector over HTTP, in batches, with a [DotLogFormat] deciding the
## bytes.
##
## This is the target that reaches every hosted service. It owns everything those
## services have in common — a bounded queue, batching, one request in flight, retry with
## back-off, a circuit that opens when the collector is down — and knows nothing at all
## about any of them. Swapping Loki for a collector is one assignment.
##
## [b]HTTP is the only transport a browser has, which is why this matters beyond servers.[/b]
## A web client has no UDP, no raw TCP and nowhere useful to put a file; if a shipped
## browser build is to report anything at all, it is through here.
##
## Three behaviours worth knowing before deploying one:
##
## - [b]One request at a time.[/b] Not for politeness: two concurrent requests from one
##   queue arrive out of order, and every collector on the list displays records in the
##   order of the timestamps they carry — so an interleaved retry shows the past
##   arriving after the present.
## - [b]The circuit opens.[/b] After [member failures_before_open] consecutive failures
##   the target stops trying for [member open_circuit_sec]. A collector that is down
##   stays down for minutes, and a shipper that keeps trying every two seconds turns one
##   outage into a second one — every attempt costs a socket, a DNS lookup and a frame.
## - [b]A rejected batch is dropped, a failed one is kept.[/b] See [method _worth_retrying]:
##   a 400 means these exact bytes will never be accepted, and requeuing them blocks
##   every record behind them forever.

const SELF_CHANNEL := "log.http"

## Base URL of the collector, including scheme. The format's path is appended when this
## has none of its own.
@export var endpoint: String = ""

## How the batch is written. Without one, nothing is sent.
@export var format: DotLogFormat = null

## Records per request, capped by the format's own limit.
@export_range(1, 5000, 1) var batch_size: int = 100

## Records held while the collector is unreachable.
##
## About 4 MB of typical records. When it fills, the oldest go — see [DotLogBuffer] for
## why the alternative is an out-of-memory kill during an outage.
@export_range(16, 500000, 16) var max_queued: int = 8192

## Seconds a request may take before it is abandoned.
@export_range(1.0, 120.0, 0.5) var timeout_sec: float = 10.0

## Consecutive failures before the target stops trying.
@export_range(1, 100, 1) var failures_before_open: int = 5

## Seconds to wait with the circuit open before trying one request again.
@export_range(1.0, 3600.0, 1.0) var open_circuit_sec: float = 60.0

## Send immediately when a record at this level or above arrives.
##
## A crash report that waits for the flush interval is a crash report that does not
## arrive, because the process is gone. FATAL by default; ERROR for a client build where
## the process usually survives.
@export var send_immediately_above: DotLog.Level = DotLog.Level.FATAL

## The HTTP node. Created by the router, which parents it — [DotHttp] is a [Node] and its
## retry timer needs a tree.
var http: DotHttp = null

## Where breadcrumbs come from, handed to an error-tracking format that wants them.
var breadcrumb_source: DotLogTargetMemory = null

var _buffer: DotLogBuffer = null
var _context: Dictionary = {}
var _sending: bool = false
var _consecutive_failures: int = 0
var _circuit_open_until_ms: int = 0
var _sent_batches: int = 0
var _sent_records: int = 0
var _rejected: int = 0
var _urgent: bool = false


func _init(p_format: DotLogFormat = null, p_endpoint: String = "") -> void:
	target_name = "http"
	format = p_format
	if p_endpoint != "":
		endpoint = p_endpoint
	_buffer = DotLogBuffer.new(max_queued, DotLogBuffer.Policy.DROP_OLDEST)


func set_context(context: Dictionary) -> void:
	_context = context


func open() -> DotResult:
	if format == null:
		return DotResult.fail(
			DotError.CODE_STATE, "The HTTP log target has no format."
		)

	if resolved_endpoint() == "":
		return DotResult.fail(
			DotError.CODE_STATE,
			"The HTTP log target has no endpoint.",
			"set `endpoint`, or a DSN on the format"
		)

	if http == null:
		return DotResult.fail(
			DotError.CODE_STATE,
			"The HTTP log target has no DotHttp node.",
			"the router assigns one; a target used standalone must be given one"
		)

	http.timeout_sec = timeout_sec
	# Retries are this target's job, not DotHttp's. Two layers of back-off multiply,
	# and the outer one is the one that can drop a batch it knows will never land.
	http.max_retries = 0

	_buffer.max_records = max_queued

	if breadcrumb_source != null and format.is_error_tracker():
		if "breadcrumb_source" in format:
			format.set("breadcrumb_source", breadcrumb_source)

	_opened = true
	return DotResult.success(resolved_endpoint())


func close() -> void:
	_opened = false


func accepts(event: Dictionary) -> bool:
	if not super(event):
		return false

	# An error tracker takes only what its gate let through, and nothing else. Without
	# a gate it would take everything, which is the expensive mistake — so the absence
	# of one means WARN and above rather than everything.
	if format != null and format.is_error_tracker() and gate == null:
		return int(event.get("level", DotLog.Level.INFO)) >= DotLog.Level.WARN

	return true


func write(event: Dictionary) -> void:
	super(event)
	_buffer.push(event)

	if int(event.get("level", DotLog.Level.INFO)) >= send_immediately_above:
		_urgent = true


func is_buffered() -> bool:
	return true


func pending() -> int:
	return _buffer.size()


## Whether the next flush should not wait for the interval.
func wants_flush() -> bool:
	return _urgent or _buffer.size() >= batch_size


func flush() -> DotResult:
	_urgent = false

	if not _opened or format == null or _buffer.is_empty():
		return DotResult.success(0)

	if _sending:
		return DotResult.success(0)

	var now: int = Time.get_ticks_msec()
	if now < _circuit_open_until_ms:
		return DotResult.success(0)

	_sending = true
	var total: int = 0
	var last: DotResult = DotResult.success(0)

	# One batch per flush, not a loop until empty: a backlog of ten thousand records
	# against a slow collector would otherwise hold this coroutine open across many
	# seconds, and the router's shutdown would wait for all of it.
	var limit: int = mini(batch_size, format.max_batch())
	var batch: Array[Dictionary] = _buffer.take(limit)

	if not batch.is_empty():
		last = await _send(batch)
		if last.ok:
			total = batch.size()

	_sending = false
	return last if not last.ok else DotResult.success(total)


func _send(batch: Array[Dictionary]) -> DotResult:
	var body: PackedByteArray = format.build(batch, _context)

	var cap: int = format.max_bytes()
	if cap > 0 and body.size() > cap and batch.size() > 1:
		# Split rather than send something that will be refused. Halving is enough: the
		# next flush halves again if it has to, and a batch of one that is still too
		# large is a single oversized record, which is reported instead.
		var half: int = batch.size() / 2
		_buffer.requeue(batch.slice(half))
		return await _send(batch.slice(0, half))

	var headers: Dictionary = format.headers()
	headers["Content-Type"] = format.content_type()

	var res: DotResult = await http.request(
		HTTPClient.METHOD_POST, resolved_endpoint(), body, headers, true
	)

	if res.ok:
		var verdict: DotResult = format.interpret(res.value)
		if verdict.ok:
			_consecutive_failures = 0
			_sent_batches += 1
			_sent_records += batch.size()
			return DotResult.success(batch.size())
		res = verdict

	# From here the send failed, and the only question is whether these bytes could ever
	# be accepted.
	note_failure(res)
	_consecutive_failures += 1

	if _worth_retrying(res):
		_buffer.requeue(batch)
		if res.error != null and res.error.retry_after > 0.0:
			# The collector said how long. Believed, because retrying inside a rate
			# limit is what extends one.
			_circuit_open_until_ms = (
				Time.get_ticks_msec() + int(res.error.retry_after * 1000.0)
			)
	else:
		# A 400, a 401, a malformed payload: these bytes are not going to be accepted on
		# the fifth attempt either, and keeping them blocks every record behind them.
		_rejected += batch.size()

	if _consecutive_failures >= failures_before_open:
		_circuit_open_until_ms = maxi(
			_circuit_open_until_ms,
			Time.get_ticks_msec() + int(open_circuit_sec * 1000.0)
		)

	return res


## Whether these exact bytes could ever be accepted.
##
## [b]Not simply [method DotResult.is_retryable].[/b] dot-core maps every non-2xx it does
## not recognise onto [constant DotError.CODE_HTTP], which is retryable — the right
## default for an API call, where a 400 is usually a caller that can be fixed and retried
## by a person. It is the wrong default here: nobody is going to fix the batch, so a 400
## from a collector that has decided it dislikes this payload would be retried forever,
## and every record behind it would sit in the queue until the queue dropped it.
##
## So a 4xx means these bytes are refused, with two exceptions that genuinely are about
## timing rather than content: 408 (the request took too long to arrive) and 429 (too
## many, too fast). A 5xx and a transport failure are always worth another go.
func _worth_retrying(res: DotResult) -> bool:
	if res == null or res.error == null:
		return false

	var status: int = res.error.http_status
	if status >= 400 and status < 500:
		return status == 408 or status == 429

	return res.is_retryable()


## The URL requests actually go to.
func resolved_endpoint() -> String:
	if format == null:
		return endpoint

	var override: String = format.endpoint_override()
	if override != "":
		return override

	if endpoint == "":
		return ""

	var base: String = endpoint
	while base.ends_with("/"):
		base = base.substr(0, base.length() - 1)

	var path: String = format.default_path()
	if path == "":
		return base

	# A base URL that already has a path is left alone: a collector behind a gateway
	# often lives at /logs/loki/api/v1/push, and appending the default path again would
	# produce a 404 that looks like a broken collector.
	var after_scheme: int = base.find("://")
	var rest: String = base.substr(after_scheme + 3) if after_scheme >= 0 else base
	if rest.contains("/"):
		return base

	return base + path


## Whether the circuit is currently open, and for how much longer.
func circuit_open_sec() -> float:
	var left: int = _circuit_open_until_ms - Time.get_ticks_msec()
	return maxf(0.0, float(left) / 1000.0)


func describe() -> Dictionary:
	var out: Dictionary = super()
	out["endpoint"] = resolved_endpoint()
	out["format"] = format.format_name() if format != null else "none"
	out["queued"] = _buffer.size()
	out["queue_dropped"] = _buffer.dropped()
	out["batches"] = _sent_batches
	out["records_sent"] = _sent_records
	out["rejected"] = _rejected
	out["circuit_open_for"] = "%.0fs" % circuit_open_sec()
	return out
