class_name DotLogCommands
extends RefCounted

## The `log` command: what the logger is doing, and what it has been saying.
##
## [b]It names no console.[/b] This object has `claims`, `execute`, `complete`, `names`
## and `help_for` — which is exactly the shape dot-console's `DotConsoleBridge` duck-types
## and exactly the shape dot-server's console reaches through the same bridge. Neither is
## a dependency of dot-log and neither is mentioned in this file; a host that has one
## wraps this, and a host that has neither loses nothing else.
##
## [codeblock]
## # with dot-console present, in the host project:
## console.add_source(DotConsoleBridge.wrap(DotLogCommands.new(router), "log"))
## [/codeblock]
##
## The command it exists for is `log test`. Everything else here is diagnostics that could
## be read another way; **whether the collector is actually receiving anything** cannot be,
## and the usual way of finding out is to wait for a real error and see whether it turns
## up — which is a test you run once, badly, at the worst moment. `log test error a
## deliberate test` puts one record of a chosen level through the whole pipeline on demand.

const CHANNEL := "log.cmd"

const SUBCOMMANDS: Array[String] = [
	"status", "tail", "grep", "level", "channel", "targets", "flush", "test",
]

## Default number of lines `tail` returns. A console scrollback is not a pager.
const DEFAULT_TAIL := 20

var router: DotLogRouter = null

## Where `tail` and `grep` read from. Resolved from the router when not set.
var memory: DotLogTargetMemory = null


func _init(p_router: DotLogRouter = null) -> void:
	router = p_router


# --- The duck-typed console source shape -----------------------------------

func names() -> PackedStringArray:
	return PackedStringArray(["log"])


func claims(name: String) -> bool:
	return name.to_lower() == "log"


func help_for(name: String) -> String:
	if name.to_lower() != "log":
		return ""
	return "log <status|tail|grep|level|channel|targets|flush|test> — the logger"


func complete(partial: String, limit: int = 24) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var words: PackedStringArray = partial.strip_edges().split(" ", false)

	if words.is_empty() or (words.size() == 1 and not partial.ends_with(" ")):
		if "log".begins_with(partial.strip_edges().to_lower()):
			out.append("log")
		return out

	if words[0].to_lower() != "log":
		return out

	var prefix: String = "" if partial.ends_with(" ") else words[words.size() - 1].to_lower()
	var position: int = words.size() if partial.ends_with(" ") else words.size() - 1

	var candidates: Array[String] = []
	if position == 1:
		candidates.assign(SUBCOMMANDS)
	elif position == 2 and words[1].to_lower() in ["level", "test"]:
		# The level names, which is the completion that actually saves typing: nobody
		# remembers whether this logger spells it `warn` or `warning`.
		for i: int in range(DotLog.LEVEL_NAMES.size()):
			candidates.append(DotLog.LEVEL_NAMES[i].to_lower())

	for c: String in candidates:
		if c.begins_with(prefix):
			out.append("log " + " ".join(words.slice(1, position)) + (" " if position > 1 else "") + c)
			if out.size() >= limit:
				break
	return out


func execute(line: String) -> DotResult:
	var words: PackedStringArray = line.strip_edges().split(" ", false)
	if words.is_empty() or words[0].to_lower() != "log":
		return DotResult.fail(DotError.CODE_INVALID, "not a log command")

	var sub: String = words[1].to_lower() if words.size() > 1 else "status"
	var args: PackedStringArray = words.slice(2)

	match sub:
		"status":
			return _status()
		"targets":
			return _targets()
		"tail":
			return _tail(args)
		"grep":
			return _grep(args)
		"level":
			return _level(args)
		"channel":
			return _channel(args)
		"flush":
			return _flush()
		"test":
			return _test(args)
		_:
			return DotResult.fail(
				DotError.CODE_INVALID,
				"Unknown: log %s" % sub,
				"one of: " + ", ".join(SUBCOMMANDS)
			)


# --- Subcommands -----------------------------------------------------------

func _status() -> DotResult:
	if router == null:
		return DotResult.success(
			"No log router. Records are going to stdout and nowhere else."
		)
	return DotResult.success("\n".join(router.describe_lines()))


func _targets() -> DotResult:
	if router == null:
		return DotResult.fail(DotError.CODE_STATE, "No log router.")

	var lines: PackedStringArray = PackedStringArray()
	lines.append("%-12s %-6s %-8s %8s %8s %8s  %s" % [
		"target", "open", "state", "written", "pending", "failed", "detail"
	])

	for target: DotLogTarget in router.targets:
		var health: Dictionary = target.health()
		lines.append("%-12s %-6s %-8s %8d %8d %8d  %s" % [
			target.target_name,
			"yes" if target.is_open() else "NO",
			"on" if target.enabled else "off",
			int(health["written"]),
			int(health["pending"]),
			int(health["failed"]),
			str(health["last_error"]),
		])

	return DotResult.success("\n".join(lines))


func _tail(args: PackedStringArray) -> DotResult:
	var ring: DotLogTargetMemory = _memory()
	if ring == null:
		return DotResult.fail(
			DotError.CODE_STATE,
			"There is no memory target to read back.",
			"add a DotLogTargetMemory to the router"
		)

	var count: int = DEFAULT_TAIL
	if args.size() > 0 and args[0].is_valid_int():
		count = maxi(1, args[0].to_int())

	var events: Array[Dictionary] = ring.tail(count)
	if events.is_empty():
		return DotResult.success("(nothing recorded yet)")

	var lines: PackedStringArray = PackedStringArray()
	for event: Dictionary in events:
		lines.append(DotLogEvent.text_line(event))
	return DotResult.success("\n".join(lines))


func _grep(args: PackedStringArray) -> DotResult:
	var ring: DotLogTargetMemory = _memory()
	if ring == null:
		return DotResult.fail(DotError.CODE_STATE, "There is no memory target to search.")

	if args.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "log grep <text> [count]")

	var count: int = DEFAULT_TAIL
	var needle: String = " ".join(args)
	if args.size() > 1 and args[args.size() - 1].is_valid_int():
		count = maxi(1, args[args.size() - 1].to_int())
		needle = " ".join(args.slice(0, args.size() - 1))

	var events: Array[Dictionary] = ring.matching(needle, "", DotLog.Level.TRACE, count)
	if events.is_empty():
		return DotResult.success("(no match for '%s' in the last %d records)" % [
			needle, ring.size()
		])

	var lines: PackedStringArray = PackedStringArray()
	for event: Dictionary in events:
		lines.append(DotLogEvent.text_line(event))
	return DotResult.success("\n".join(lines))


func _level(args: PackedStringArray) -> DotResult:
	if args.is_empty():
		var lines: PackedStringArray = PackedStringArray()
		lines.append("level %s" % DotLog.level_name(DotLog.get_level()))
		for i: int in range(DotLog.Level.TRACE, DotLog.Level.OFF + 1):
			lines.append("  %-5s %s" % [
				DotLog.LEVEL_NAMES[i], _level_meaning(i)
			])
		return DotResult.success("\n".join(lines))

	var parsed: int = DotLog.parse_level(args[0])
	if parsed < 0:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Unknown level '%s'." % args[0],
			", ".join(DotLog.LEVEL_NAMES).to_lower()
		)

	DotLog.set_level(parsed)
	return DotResult.success("level is now %s" % DotLog.level_name(parsed))


func _channel(args: PackedStringArray) -> DotResult:
	if args.size() < 2:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"log channel <channel> <level>",
			"or `log channel <channel> default` to clear the override"
		)

	var channel: String = args[0]

	if args[1].to_lower() == "default":
		DotLog.clear_channel_level(channel)
		return DotResult.success("%s follows the global level again" % channel)

	var parsed: int = DotLog.parse_level(args[1])
	if parsed < 0:
		return DotResult.fail(DotError.CODE_INVALID, "Unknown level '%s'." % args[1])

	DotLog.set_channel_level(channel, parsed)
	return DotResult.success("%s is now %s" % [channel, DotLog.level_name(parsed)])


func _flush() -> DotResult:
	if router == null:
		return DotResult.fail(DotError.CODE_STATE, "No log router.")
	# Started rather than awaited: a console command that blocked the frame on a slow
	# collector would be a worse experience than one that returns and lets the next
	# `log targets` report what happened.
	router.flush_all()
	return DotResult.success("flushing %d targets" % router.targets.size())


## Puts one record of a chosen level through the whole pipeline.
##
## The only way to answer "is the collector receiving anything" that does not involve
## waiting for a real failure. Deliberately logged on its own channel so that a test
## record can never be mistaken for the subsystem it is named after.
func _test(args: PackedStringArray) -> DotResult:
	var level: int = DotLog.Level.INFO
	var rest: PackedStringArray = args

	if args.size() > 0:
		var parsed: int = DotLog.parse_level(args[0])
		if parsed >= 0 and parsed < DotLog.Level.OFF:
			level = parsed
			rest = args.slice(1)

	var message: String = " ".join(rest)
	if message == "":
		message = "a deliberate test record"

	if level >= DotLog.Level.FATAL:
		# FATAL promises a shutdown follows. A console command that made that promise
		# falsely would teach every reader of the log to stop believing the level, which
		# is the only thing the level is worth.
		return DotResult.fail(
			DotError.CODE_INVALID,
			"FATAL is not a level you may send a test at.",
			"it means the process cannot continue, and this one plainly can"
		)

	DotLog.at(level, CHANNEL, message, {"test": true, "level": DotLog.level_name(level)})

	return DotResult.success(
		"emitted one %s record; `log targets` says where it got to"
		% DotLog.level_name(level)
	)


static func _level_meaning(level: int) -> String:
	match level:
		DotLog.Level.TRACE:
			return "per-frame or per-packet detail"
		DotLog.Level.DEBUG:
			return "decisions and state transitions"
		DotLog.Level.INFO:
			return "what an admin would want kept"
		DotLog.Level.WARN:
			return "recoverable; someone should look eventually"
		DotLog.Level.ERROR:
			return "the operation failed"
		DotLog.Level.FATAL:
			return "the process cannot continue"
		_:
			return "nothing is emitted"


func _memory() -> DotLogTargetMemory:
	if memory != null:
		return memory
	if router == null:
		return null
	for target: DotLogTarget in router.targets:
		if target is DotLogTargetMemory:
			memory = target as DotLogTargetMemory
			return memory
	return null


func describe() -> Dictionary:
	return {
		"commands": ", ".join(SUBCOMMANDS),
		"router": router != null,
		"memory": _memory() != null,
	}
