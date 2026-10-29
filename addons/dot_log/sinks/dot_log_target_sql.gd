@tool
class_name DotLogTargetSql
extends DotLogTarget

## Writes the log into a database table, in batches.
## Godot ships no database driver, so the driver is duck-typed ([code]execute(sql, params) -> DotResult[/code], the shape of dot-moderation's [code]DotSqlDriver[/code]) and everything else is in [DotLogSqlSchema].
## Keep the file target on too: this one has a dependency, so it can be unavailable.

const SELF_CHANNEL := "log.sql"

## Table name. Quoted, and anything unquotable is replaced rather than escaped.
@export var table: String = "dot_log"

## Which SQL to speak. Ask the driver if it says, and set it here if it does not.
@export var dialect: DotLogSqlSchema.Dialect = DotLogSqlSchema.Dialect.SQLITE

## Records per INSERT.
## One statement per batch, so also the transaction size. Older SQLite caps at 999 parameters (124 rows of eight), so this is checked at send.
@export_range(1, 5000, 1) var batch_size: int = 100

## Records held while the database is unavailable.
@export_range(16, 200000, 16) var max_queued: int = 8192

## Delete rows older than this many days on [method prune]. 0 keeps everything.
## Never automatic: a DELETE over a large table does not belong in a mid-round flush. Call it from a scheduled task or console command.
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
## Created here, not by a migration: a log table has no history worth migrating, so a changed shape starts a new table.
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
