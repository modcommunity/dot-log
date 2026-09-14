@tool
class_name DotLogTargetFile
extends DotLogTarget

## Writes the log to a file on disk, rotating it so it cannot fill the volume.
##
## This is the target a dedicated server always has. Everything else here is optional;
## a file on the machine that produced it is the one destination that keeps working when
## the network, the collector and the account behind it do not, and it is where the
## answer to "what happened last night" actually lives.
##
## [b]Buffered, never line-by-line.[/b] A busy server emits hundreds of lines a second
## and a flush per line is a system call per line — on web it is an IndexedDB
## transaction per line, which is catastrophic rather than merely slow. Lines accumulate
## and go out on the router's flush, so the worst case is losing one flush interval of
## log to a hard kill. [member flush_on_error] narrows that to zero for the lines that
## actually matter.
##
## [b]Rotation opens a new file rather than renaming the old one.[/b] Renaming a file
## that is open behaves differently on each of the five targets — Windows refuses it
## outright — and the name already carries a sortable timestamp, so a directory listing
## is in chronological order without the numbered-suffix dance.
##
## dot-core ships [DotLogSink], which is a smaller version of this. Both exist on
## purpose: that one is what a project with no dependency but dot-core reaches for, this
## one is the one that participates in the pipeline — a gate of its own, redaction
## applied upstream, and the router's context on every line.

const SELF_CHANNEL := "log.file"

@export_group("File")

## Directory for log files. [code]user://[/code] and absolute paths both work.
@export var directory: String = "user://logs"

## Base name. A timestamp and [code].log[/code] are appended.
@export var basename: String = "server"

## Start a new file each run instead of appending to the last one.
##
## On by default: interleaved runs in one file make "what happened last night" much
## harder to answer than a directory listing does.
@export var new_file_per_run: bool = true

@export_group("Format")

## One JSON object per line instead of the human format.
##
## For a file something else will read — a shipper tailing it, a script counting
## errors. Off by default, because the primary reader is a person over SSH.
@export var json_lines: bool = false

## Prefix for field names in JSON output, so a field cannot collide with an envelope
## key. Empty means no prefix, which is fine when the fields are known.
@export var field_prefix: String = ""

@export_group("Rotation")

## Rotate once the file passes this size. 0 disables size rotation.
@export var max_file_bytes: int = 16 * 1024 * 1024

## Rotate when the UTC date changes, whatever the size.
##
## What makes "send me yesterday's log" a filename rather than a search.
@export var daily: bool = false

## Files to keep, oldest deleted first. 0 keeps everything.
##
## [b]Not zero by default.[/b] A log directory with no bound is the most common way a
## game server fills a disk, and a full disk stops the server rather than the logging.
@export var max_files: int = 10

@export_group("Flushing")

## Lines buffered before an immediate write, whatever the router's interval.
@export_range(1, 100000, 1) var max_buffered_lines: int = 256

## Write immediately on ERROR and above.
##
## The lines you most want after a crash are the ones written just before it, and those
## are precisely the ones still in a buffer.
@export var flush_on_error: bool = true

var _buffer: PackedStringArray = PackedStringArray()
var _file: FileAccess = null
var _path: String = ""
var _bytes: int = 0
var _day: String = ""
var _context: Dictionary = {}
var _rotations: int = 0


func _init(p_directory: String = "", p_basename: String = "") -> void:
	target_name = "file"
	if p_directory != "":
		directory = p_directory
	if p_basename != "":
		basename = p_basename


## Context tags from the router, written into JSON lines.
##
## Not written into the human format: an admin reading their own server's log already
## knows which server it is, and repeating five tags per line halves how much of the
## message fits on screen.
func set_context(context: Dictionary) -> void:
	_context = context


func open() -> DotResult:
	var res: DotResult = _open_file()
	if not res.ok:
		note_failure(res)
		return res
	_opened = true
	return res


func close() -> void:
	_write_out()
	if _file != null:
		_file.close()
		_file = null
	_opened = false


func write(event: Dictionary) -> void:
	super(event)

	_buffer.append(
		DotLogEvent.flatten_json(event, _context, field_prefix)
		if json_lines
		else DotLogEvent.text_line(event)
	)

	var level: int = int(event.get("level", DotLog.Level.INFO))
	if _buffer.size() >= max_buffered_lines:
		_write_out()
	elif flush_on_error and level >= DotLog.Level.ERROR:
		_write_out()


func flush() -> DotResult:
	return _write_out()


func is_buffered() -> bool:
	return true


func pending() -> int:
	return _buffer.size()


## Where it is writing now. Not `path`: [Resource] has enough path-shaped members
## already, and a method that quietly shadows a native one is a bug this tree has paid
## for. See docs/gdscript-hazards.md.
func file_path() -> String:
	return _path


func rotations() -> int:
	return _rotations


# --- Writing ---------------------------------------------------------------

func _write_out() -> DotResult:
	if _buffer.is_empty():
		return DotResult.success(0)

	if _file == null:
		# Not an error every flush: a target whose disk went away would otherwise
		# produce one failure per flush for the rest of the session, which is the
		# noise the whole addon is trying to stop. It is counted once, at open.
		var n_lost: int = _buffer.size()
		_buffer.clear()
		return DotResult.fail(
			DotError.CODE_STATE, "The log file is not open.", str(n_lost) + " lines lost"
		)

	var text: String = "\n".join(_buffer) + "\n"
	var count: int = _buffer.size()
	_buffer.clear()

	_file.store_string(text)
	_file.flush()
	_bytes += text.to_utf8_buffer().size()

	# Persist through IndexedDB on web, where an unsynced write is lost when the tab
	# closes — which is exactly the moment the log becomes interesting.
	DotWeb.sync_filesystem()

	var err: int = _file.get_error()
	if err != OK and err != ERR_FILE_EOF:
		var res: DotResult = DotResult.failure(
			DotError.from_engine(err, "writing to '%s'" % _path)
		)
		note_failure(res)
		return res

	if _should_rotate():
		var rotated: DotResult = _rotate()
		if not rotated.ok:
			note_failure(rotated)
			return rotated

	return DotResult.success(count)


func _should_rotate() -> bool:
	if max_file_bytes > 0 and _bytes >= max_file_bytes:
		return true
	if daily and _day != "" and _day != _today():
		return true
	return false


func _rotate() -> DotResult:
	if _file != null:
		_file.close()
		_file = null

	var saved: bool = new_file_per_run
	new_file_per_run = true
	var res: DotResult = _open_file()
	new_file_per_run = saved

	if res.ok:
		_rotations += 1
	return res


static func _today() -> String:
	return Time.get_date_string_from_system(true)


func _open_file() -> DotResult:
	var made: DotResult = DotPaths.ensure_dir(directory)
	if not made.ok:
		return made.wrap("preparing the log directory")

	var filename: String = basename
	if new_file_per_run:
		# Sortable, filesystem-safe and unique per second. Two starts inside one second
		# would be a restart loop, which is worth noticing rather than accommodating.
		var stamp: String = Time.get_datetime_string_from_system(false, false)
		filename += "-" + stamp.replace(":", "").replace("-", "").replace("T", "-")
	filename += ".log"

	_path = directory.path_join(filename)
	_day = _today()

	var mode: int = FileAccess.WRITE if new_file_per_run else FileAccess.READ_WRITE
	_file = FileAccess.open(_path, mode)

	if _file == null and mode == FileAccess.READ_WRITE:
		# READ_WRITE does not create a file that is not there; the first run needs WRITE.
		_file = FileAccess.open(_path, FileAccess.WRITE)

	if _file == null:
		return DotResult.failure(
			DotError.from_engine(
				FileAccess.get_open_error(), "opening log file '%s'" % _path
			)
		)

	if new_file_per_run:
		_bytes = 0
	else:
		_file.seek_end()
		_bytes = int(_file.get_position())

	_prune()
	return DotResult.success(_path)


func _prune() -> void:
	if max_files <= 0:
		return

	var dir: DirAccess = DirAccess.open(directory)
	if dir == null:
		return

	var names: PackedStringArray = PackedStringArray()
	dir.list_dir_begin()
	var n: String = dir.get_next()
	while n != "":
		if not dir.current_is_dir() and n.begins_with(basename) and n.ends_with(".log"):
			names.append(n)
		n = dir.get_next()
	dir.list_dir_end()

	if names.size() <= max_files:
		return

	# The names carry a sortable timestamp, so lexical order is chronological.
	names.sort()

	for i: int in range(names.size() - max_files):
		var victim: String = directory.path_join(names[i])
		if victim == _path:
			continue
		DirAccess.remove_absolute(victim)


func describe() -> Dictionary:
	var out: Dictionary = super()
	out["path"] = _path
	out["bytes"] = _bytes
	out["rotations"] = _rotations
	out["json"] = json_lines
	return out
