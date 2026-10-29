@tool
class_name DotLogSqlSchema
extends RefCounted

## The table a log goes into, and the statements that put it there.
## Apart from [DotLogTargetSql] so the DDL, the multi-row insert and the column mapping test without a database.
## Narrow: six indexed columns plus one JSON blob, and every statement is parameterised (a log message is attacker-influenced).

## Which SQL to speak. The differences are small and all three matter.
enum Dialect {
	SQLITE,    ## The default. One file, no server, and it is what a community host has.
	POSTGRES,  ## $1-style placeholders, and a real JSON type.
	MYSQL,     ## Backtick quoting and a different auto-increment spelling.
}

## Columns, in the order the insert builds them.
const COLUMNS: Array[String] = [
	"ts_ms", "seq", "level", "level_name", "channel", "message", "fields", "context",
]


## The table, the index, and nothing else.
## Two indexes: time (every query has a range) and (channel, level); a third costs more on insert than it saves.
static func create_statements(table: String, dialect: Dialect) -> PackedStringArray:
	var t: String = quote_identifier(table, dialect)
	var out: PackedStringArray = PackedStringArray()

	var text_type: String = "TEXT"
	var json_type: String = "TEXT"
	var big_int: String = "BIGINT"

	match dialect:
		Dialect.POSTGRES:
			# jsonb rather than text: it is indexable and queryable, and the storage
			# difference on a log table is not the interesting part.
			json_type = "JSONB"
		Dialect.MYSQL:
			# MySQL cannot index an unbounded TEXT column without a prefix length, and
			# a channel is short by construction.
			text_type = "VARCHAR(190)"
			json_type = "JSON"
		Dialect.SQLITE:
			big_int = "INTEGER"

	out.append(
		"CREATE TABLE IF NOT EXISTS %s (" % t
		+ "ts_ms %s NOT NULL, " % big_int
		+ "seq %s NOT NULL, " % big_int
		+ "level INTEGER NOT NULL, "
		+ "level_name %s NOT NULL, " % text_type
		+ "channel %s NOT NULL, " % text_type
		+ "message TEXT NOT NULL, "
		+ "fields %s, " % json_type
		+ "context %s)" % json_type
	)

	out.append(
		"CREATE INDEX IF NOT EXISTS %s ON %s (ts_ms)"
		% [quote_identifier(table + "_ts", dialect), t]
	)
	out.append(
		"CREATE INDEX IF NOT EXISTS %s ON %s (channel, level)"
		% [quote_identifier(table + "_chan", dialect), t]
	)

	return out


## A multi-row INSERT and its parameters, as [code]{"sql": String, "params": Array}[/code].
## One statement per batch: per-row inserts are a transaction each on SQLite.
static func insert_statement(
	table: String, dialect: Dialect, events: Array, context: Dictionary
) -> Dictionary:
	var t: String = quote_identifier(table, dialect)
	var params: Array = []
	var rows: PackedStringArray = PackedStringArray()
	var context_json: String = JSON.stringify(DotLogEvent.json_fields(context))

	var n: int = 0
	for event: Dictionary in events:
		var placeholders: PackedStringArray = PackedStringArray()
		for i: int in range(COLUMNS.size()):
			n += 1
			placeholders.append(placeholder(n, dialect))
		rows.append("(" + ", ".join(placeholders) + ")")

		params.append(DotLogEvent.time_ms(event))
		params.append(int(event.get("seq", 0)))
		params.append(int(event.get("level", DotLog.Level.INFO)))
		params.append(String(event.get("level_name", "INFO")))
		params.append(String(event.get("channel", "")))
		params.append(String(event.get("message", "")))
		params.append(JSON.stringify(DotLogEvent.json_fields(event.get("fields", {}))))
		params.append(context_json)

	return {
		"sql": "INSERT INTO %s (%s) VALUES %s" % [
			t, ", ".join(COLUMNS), ", ".join(rows)
		],
		"params": params,
	}


## Deletes everything older than a cut-off, as the same shape.
## Retention is what makes a log table viable; the file target already has rotation, a database does not.
static func prune_statement(
	table: String, dialect: Dialect, before_ms: int
) -> Dictionary:
	return {
		"sql": "DELETE FROM %s WHERE ts_ms < %s" % [
			quote_identifier(table, dialect), placeholder(1, dialect)
		],
		"params": [before_ms],
	}


## A recent-records query, for a console command that reads the table back.
static func tail_statement(
	table: String, dialect: Dialect, limit: int, channel: String = ""
) -> Dictionary:
	var t: String = quote_identifier(table, dialect)
	var params: Array = []
	var where: String = ""

	if channel != "":
		where = " WHERE channel = %s" % placeholder(1, dialect)
		params.append(channel)

	params.append(limit)
	return {
		"sql": "SELECT %s FROM %s%s ORDER BY ts_ms DESC, seq DESC LIMIT %s" % [
			", ".join(COLUMNS), t, where, placeholder(params.size(), dialect)
		],
		"params": params,
	}


## The placeholder for the [param n]th parameter, one-based.
static func placeholder(n: int, dialect: Dialect) -> String:
	if dialect == Dialect.POSTGRES:
		# Numbered, and the number is not optional: Postgres has no positional "?".
		return "$%d" % n
	return "?"


## Quotes an identifier for the dialect, and refuses one that cannot be quoted safely.
## A table name comes from an edited config file; rejecting all but word characters is simpler and more complete than escaping.
static func quote_identifier(name: String, dialect: Dialect) -> String:
	var safe: String = ""
	for i: int in range(name.length()):
		var c: String = name[i]
		if c.is_valid_identifier() or c == "_" or (c >= "0" and c <= "9"):
			safe += c
		else:
			safe += "_"

	if safe == "" or (safe[0] >= "0" and safe[0] <= "9"):
		safe = "log_" + safe

	if dialect == Dialect.MYSQL:
		return "`%s`" % safe
	return "\"%s\"" % safe
