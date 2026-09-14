@tool
class_name DotLogTargetSql
extends DotLogTarget

## Writes the log into a database table, in batches.
##
## [b]Godot ships no database driver, and this class is built around saying so honestly.[/b]
## There is no [code]SQLite[/code], no [code]PostgreSQLClient[/code] and no
## [code]MySQL[/code] class in the engine; every one of them is a GDExtension somebody
## installs. So everything that can be done in GDScript is done here and in
## [DotLogSqlSchema] — the DDL, the parameterised multi-row insert, the batching,
## retention — and the one step that needs a native library is handed to whatever is
## installed.
##
## The driver is duck-typed rather than a class of ours: anything with
## [code]execute(sql, params) -> DotResult[/code] will do, which is deliberately the
## shape dot-moderation's [code]DotSqlDriver[/code] already has. An operator who has set
## up a database for bans should not have to set up a second one for logs, and the two
## addons must not have to know about each other to share it.
##
## [b]When a log table beats a log file:[/b] several servers writing one place, a web
## admin panel that needs to query rather than grep, retention measured in rows, and
## joins against the tables that hold the bans and the players a line is about. When it
## does not: a single box, where a file costs nothing and survives the database being
## down. Keep the file target on either way — this one has a dependency, and a target
## with a dependency is a target that can be unavailable.

const SELF_CHANNEL := "log.sql"

## Table name. Quoted, and anything unquotable is replaced rather than escaped.
@export var table: String = "dot_log"

## Which SQL to speak. Ask the driver if it says, and set it here if it does not.
@export var dialect: DotLogSqlSchema.Dialect = DotLogSqlSchema.Dialect.SQLITE

## Records per INSERT.
##
## One statement per batch, so this is also the transaction size. 200 is comfortably
## inside every driver's parameter limit at eight columns a row — SQLite's default
## ceiling is 999 parameters in older builds, which is 124 rows, so this is checked at
## send rather than assumed.
@export_range(1, 5000, 1) var batch_size: int = 100

## Records held while the database is unavailable.
@export_range(16, 200000, 16) var max_queued: int = 8192

## Delete rows older than this many days on [method prune]. 0 keeps everything.
##
## Not called automatically — a DELETE over a large table is not something to do from a
## flush on a server that is mid-round. Call it from a scheduled task or a console
## command, at a moment of your choosing.
@export_range(0, 3650, 1) var retention_days: int = 30

## The database driver. Any object with `execute(sql, params) -> DotResult`.
var driver: Object = null

var _buffer: DotLogBuffer = null
var _context: Dictionary = {}
var _sending: bool = false
var _inserted: int = 0


func _init(p_driver: Object = null, p_table: String = "") -> void:
	target_name = "sql"
	driver = p_driver
	if p_table != "":
		table = p_table
	_buffer = DotLogBuffer.new(max_queued, DotLogBuffer.Policy.DROP_OLDEST)


func set_context(context: Dictionary) -> void:
	_context = context


## Checks the driver and creates the table.
##
## The table is created here rather than by a migration because a log table has no
## history worth migrating: if the shape changes, the old table is still readable and the
## new one starts empty, which is the correct outcome for a log and would not be for
## anything else.
func open() -> DotResult:
	if driver == null:
		return DotResult.fail(
			DotError.CODE_STATE,
			"No database driver was given to the SQL log target.",
			"assign `driver` before starting the router"
		)

	if not driver.has_method("execute"):
		return DotResult.fail(
			DotError.CODE_INVALID,
			"The log driver has no execute(sql, params) method.",
			str(driver.get_class())
		)

	if driver.has_method("is_available"):
		var available: DotResult = driver.is_available()
		if available != null and not available.ok:
			return available

	if driver.has_method("is_open") and not driver.is_open():
		if driver.has_method("open"):
			var opened: DotResult = await driver.open()
			if opened != null and not opened.ok:
				return opened.wrap("opening the log database")

	_buffer.max_records = max_queued

	for sql: String in DotLogSqlSchema.create_statements(table, dialect):
		var made: DotResult = await driver.execute(sql, [])
		if made != null and not made.ok:
			return made.wrap("creating the log table")

	_opened = true
	return DotResult.success(table)


func close() -> void:
	_opened = false
	# The driver is not closed here: it was given to us and may well be the same
	# connection something else is using. Whoever opened it closes it.


func write(event: Dictionary) -> void:
	super(event)
	_buffer.push(event)


func flush() -> DotResult:
	if _buffer.is_empty() or not _opened:
		return DotResult.success(0)

	if _sending:
		# One batch in flight at a time. Two concurrent inserts from one queue would
		# interleave, and a retry would then have to work out which rows had landed.
		return DotResult.success(0)

	_sending = true
	var total: int = 0

	while not _buffer.is_empty():
		var batch: Array[Dictionary] = _buffer.take(batch_size)
		var statement: Dictionary = DotLogSqlSchema.insert_statement(
			table, dialect, batch, _context
		)

		var res: DotResult = await driver.execute(
			String(statement["sql"]), statement["params"]
		)

		if res == null:
			res = DotResult.fail(
				DotError.CODE_INTERNAL, "The driver returned nothing."
			)

		if not res.ok:
			# Back at the front, in order, for the next flush. A database that is down
			# usually comes back, and a log that threw the rows away in the meantime is
			# missing exactly the window that explains why it went down.
			_buffer.requeue(batch)
			note_failure(res)
			_sending = false
			return res

		total += batch.size()
		_inserted += batch.size()

	_sending = false
	return DotResult.success(total)


func is_buffered() -> bool:
	return true


func pending() -> int:
	return _buffer.size()


## Deletes rows older than [member retention_days]. Returns what the driver said.
func prune() -> DotResult:
	if retention_days <= 0:
		return DotResult.success(0)
	if driver == null or not _opened:
		return DotResult.fail(DotError.CODE_STATE, "The log database is not open.")

	var cutoff_ms: int = (
		int(Time.get_unix_time_from_system() * 1000.0)
		- retention_days * 86400 * 1000
	)
	var statement: Dictionary = DotLogSqlSchema.prune_statement(
		table, dialect, cutoff_ms
	)
	var res: DotResult = await driver.execute(
		String(statement["sql"]), statement["params"]
	)
	return res if res != null else DotResult.success(0)


## The most recent rows back out of the table, for a console command.
func tail(limit: int = 50, channel: String = "") -> DotResult:
	if driver == null or not driver.has_method("query"):
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED, "This driver cannot read rows back."
		)

	var statement: Dictionary = DotLogSqlSchema.tail_statement(
		table, dialect, limit, channel
	)
	var res: DotResult = await driver.query(
		String(statement["sql"]), statement["params"]
	)
	return res if res != null else DotResult.fail(
		DotError.CODE_INTERNAL, "The driver returned nothing."
	)


func describe() -> Dictionary:
	var out: Dictionary = super()
	out["table"] = table
	out["dialect"] = ["sqlite", "postgres", "mysql"][dialect]
	out["driver"] = (
		String(driver.call("driver_name"))
		if driver != null and driver.has_method("driver_name")
		else ("present" if driver != null else "none")
	)
	out["inserted"] = _inserted
	out["queued"] = _buffer.size()
	out["queue_dropped"] = _buffer.dropped()
	return out
