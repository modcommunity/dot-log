@tool
class_name DotLogTargetSyslog
extends DotLogTarget

## Sends records to a syslog collector, in the format from RFC 5424.
##
## [b]Worth having even in a world of hosted log services, for one reason: it is already
## there.[/b] Every Linux box a dedicated server runs on has a syslog daemon listening,
## every managed host has a documented way to forward it, and every log aggregator ever
## built accepts it. A game server that speaks syslog needs no agent installed, no API
## key, and no account — which makes it the destination a community host can actually
## turn on.
##
## Two transports, and they fail differently:
##
## - [b]UDP[/b] is fire-and-forget. It cannot block the game and it cannot tell you the
##   collector is gone; a datagram over about 1 KB may also be dropped silently by a
##   router in between, so [member max_message_bytes] truncates rather than gambling.
##   Sent as the record arrives, because the whole point of a UDP tail is that it is live.
## - [b]TCP[/b] is framed with octet counting (RFC 6587), delivers in order, and reports
##   a dead collector — at the cost of a connection to maintain. Buffered and sent on the
##   flush, because a connect is not something to do inside a log call.
##
## Neither exists in a browser, which has no raw sockets of either kind: [method open]
## says so rather than pretending to send.

const SELF_CHANNEL := "log.syslog"

## Framing. Both are in wide use; the collector decides which it wants.
enum Transport {
	UDP,  ## RFC 5426. No connection, no delivery guarantee, no back pressure.
	TCP,  ## RFC 6587 octet counting. Ordered, connected, and it notices an outage.
}

## The RFC 5424 facility. 16 is [code]local0[/code], which is the conventional home for
## an application that is not one of the named system services.
const FACILITY_LOCAL0 := 16

## Structured-data id for our own fields.
##
## The RFC requires a custom SD-ID to be [code]name@<private enterprise number>[/code].
## 32473 is the number IANA reserved for documentation and examples (RFC 5612), which is
## the honest choice for a project that has not registered one — it is unambiguous about
## being unregistered rather than squatting on somebody else's.
const SD_ID := "dot@32473"

@export var host: String = "127.0.0.1"

@export_range(1, 65535, 1) var port: int = 514

@export var transport: Transport = Transport.UDP

## The APP-NAME field: which program on the host this is. Collectors index on it.
@export var app_name: String = "dot-server"

## The HOSTNAME field. Empty asks the OS, which is right nearly always.
@export var host_name: String = ""

## Facility, 0–23. Change it to sort several services apart at the collector.
@export_range(0, 23, 1) var facility: int = FACILITY_LOCAL0

## Send the message's fields as RFC 5424 structured data.
##
## On, because it is the difference between a searchable record and a sentence. Off for
## a collector that mishandles structured data, of which there are still some.
@export var structured_data: bool = true

## Longest datagram to send, in bytes. Longer messages are truncated with an ellipsis.
##
## 1024 is the minimum every RFC 5424 receiver must accept; many accept 8 KB, and a
## datagram larger than the path MTU is fragmented and then quietly lost by something in
## the middle. Raise it only against a collector you control.
@export_range(480, 65535, 1) var max_message_bytes: int = 1024

## Lines held while TCP is connecting or down. Beyond this the oldest go.
@export_range(16, 100000, 16) var max_queued: int = 2048

var _udp: PacketPeerUDP = null
var _tcp: StreamPeerTCP = null
var _queue: PackedStringArray = PackedStringArray()
var _context: Dictionary = {}
var _procid: String = "-"
var _dropped: int = 0
var _reconnects: int = 0


func _init(p_host: String = "", p_port: int = 0) -> void:
	target_name = "syslog"
	if p_host != "":
		host = p_host
	if p_port > 0:
		port = p_port


func set_context(context: Dictionary) -> void:
	_context = context


func open() -> DotResult:
	if host_name == "":
		host_name = _default_hostname()
	_procid = str(OS.get_process_id())

	if transport == Transport.UDP:
		if not DotPlatform.has_udp():
			return DotResult.fail(
				DotError.CODE_UNSUPPORTED,
				"Syslog over UDP needs UDP, which this platform does not have.",
				"use an HTTP target on web"
			)
		_udp = PacketPeerUDP.new()
		var err: int = _udp.connect_to_host(host, port)
		if err != OK:
			_udp = null
			return DotResult.failure(
				DotError.from_engine(err, "resolving syslog host '%s'" % host)
			)
	else:
		if DotPlatform.is_web():
			# There is no TCP capability question to ask dot-core: a browser has no raw
			# sockets of any kind, and has_udp() already answers false there for the same
			# underlying reason.
			return DotResult.fail(
				DotError.CODE_UNSUPPORTED,
				"Syslog over TCP needs a raw socket, which a browser does not have.",
				"use an HTTP target on web"
			)
		var connected: DotResult = _connect_tcp()
		if not connected.ok:
			# Not fatal: the collector may simply not be up yet, and the flush retries.
			note_failure(connected)

	_opened = true
	return DotResult.success(null)


func close() -> void:
	if _tcp != null:
		_send_queued_tcp()
		_tcp.disconnect_from_host()
		_tcp = null
	if _udp != null:
		_udp.close()
		_udp = null
	_queue.clear()
	_opened = false


func write(event: Dictionary) -> void:
	super(event)
	var line: String = format_message(event)

	if transport == Transport.UDP:
		if _udp != null:
			# Sent here rather than queued: a UDP send is a copy into the socket's
			# buffer and cannot block, and a live tail that lagged by a flush interval
			# would not be a live tail.
			_udp.put_packet(line.to_utf8_buffer())
		return

	_queue.append(line)
	while _queue.size() > max_queued:
		_queue.remove_at(0)
		_dropped += 1


func flush() -> DotResult:
	if transport == Transport.UDP:
		return DotResult.success(0)
	return _send_queued_tcp()


func is_buffered() -> bool:
	return transport == Transport.TCP


func pending() -> int:
	return _queue.size()


# --- RFC 5424 --------------------------------------------------------------

## One record as a syslog message, without any transport framing.
func format_message(event: Dictionary) -> String:
	var level: int = int(event.get("level", DotLog.Level.INFO))
	var severity: int = DotLogEvent.syslog_severity(level)
	var pri: int = facility * 8 + severity

	var channel: String = String(event.get("channel", ""))
	var msgid: String = _nilable(channel.replace(" ", "_"))

	var head: String = "<%d>1 %s %s %s %s %s " % [
		pri,
		DotLogEvent.iso8601(event),
		_nilable(host_name),
		_nilable(app_name),
		_procid,
		msgid,
	]

	var sd: String = "-"
	if structured_data:
		sd = _structured(event)

	var msg: String = String(event.get("message", ""))
	var line: String = head + sd + " " + msg

	# Truncated on the encoded length, not the character count: one multi-byte
	# character past the limit is how a "safe" 1024-character message becomes a
	# 1100-byte datagram and disappears at the first router with a small MTU.
	var bytes: PackedByteArray = line.to_utf8_buffer()
	if bytes.size() > max_message_bytes:
		# Three bytes of headroom for the marker, and a cut that cannot land inside a
		# code point: to_utf8_buffer/get_string_from_utf8 round-trips a truncated
		# sequence as a replacement character rather than as garbage.
		line = bytes.slice(0, max_message_bytes - 3).get_string_from_utf8() + "..."

	return line


func _structured(event: Dictionary) -> String:
	var params: PackedStringArray = PackedStringArray()

	for k: Variant in _context:
		params.append("%s=\"%s\"" % [_sd_name(str(k)), _sd_escape(str(_context[k]))])

	var fields: Dictionary = event.get("fields", {})
	for k: Variant in fields:
		params.append("%s=\"%s\"" % [_sd_name(str(k)), _sd_escape(str(fields[k]))])

	if params.is_empty():
		return "-"
	return "[%s %s]" % [SD_ID, " ".join(params)]


## A PARAM-NAME may not contain a space, an equals sign or a closing bracket.
static func _sd_name(name: String) -> String:
	var out: String = name.replace(" ", "_").replace("=", "_").replace("]", "_")
	out = out.replace("\"", "_")
	return out if out != "" else "field"


## Inside a PARAM-VALUE, a quote, a backslash and a closing bracket are escaped.
static func _sd_escape(value: String) -> String:
	return (
		value.replace("\\", "\\\\").replace("\"", "\\\"").replace("]", "\\]")
	)


static func _nilable(s: String) -> String:
	# The RFC's NILVALUE. An empty field is a parse error at a strict collector, which
	# is the kind of failure that shows up as "no logs at all" rather than as an error.
	return s if s != "" else "-"


static func _default_hostname() -> String:
	var name: String = OS.get_environment("HOSTNAME")
	if name == "":
		name = OS.get_environment("COMPUTERNAME")
	if name == "":
		name = "-"
	return name


# --- TCP -------------------------------------------------------------------

func _connect_tcp() -> DotResult:
	_tcp = StreamPeerTCP.new()
	var err: int = _tcp.connect_to_host(host, port)
	if err != OK:
		_tcp = null
		return DotResult.failure(
			DotError.from_engine(err, "connecting to syslog at %s:%d" % [host, port])
		)
	_reconnects += 1
	return DotResult.success(null)


func _send_queued_tcp() -> DotResult:
	if _queue.is_empty():
		return DotResult.success(0)

	if _tcp == null:
		var reconnected: DotResult = _connect_tcp()
		if not reconnected.ok:
			return reconnected

	_tcp.poll()
	var status: int = _tcp.get_status()

	if status == StreamPeerTCP.STATUS_CONNECTING:
		# Not an error. The queue holds, and the next flush tries again.
		return DotResult.success(0)

	if status != StreamPeerTCP.STATUS_CONNECTED:
		_tcp = null
		return DotResult.fail(
			DotError.CODE_NETWORK, "The syslog connection dropped.", host
		)

	var sent: int = 0
	for line: String in _queue:
		var payload: PackedByteArray = line.to_utf8_buffer()
		# Octet counting, RFC 6587: the byte length, a space, then the message. The
		# alternative framing is a trailing newline, which breaks the moment a message
		# contains one — and a stack trace always does.
		var framed: PackedByteArray = ("%d " % payload.size()).to_utf8_buffer()
		framed.append_array(payload)

		var err: int = _tcp.put_data(framed)
		if err != OK:
			# Everything from here stays queued, in order.
			_queue = _queue.slice(sent)
			var res: DotResult = DotResult.failure(
				DotError.from_engine(err, "sending to syslog")
			)
			note_failure(res)
			return res
		sent += 1

	_queue.clear()
	return DotResult.success(sent)


func describe() -> Dictionary:
	var out: Dictionary = super()
	out["to"] = "%s:%d" % [host, port]
	out["transport"] = "udp" if transport == Transport.UDP else "tcp"
	out["queued"] = _queue.size()
	out["dropped"] = _dropped
	out["reconnects"] = _reconnects
	return out
