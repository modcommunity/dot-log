@tool
class_name DotLogConfig
extends DotConfig

## Logging as a deployment document: one flat file that builds the whole pipeline.
##
## [b]The reason this is flat rather than a list of targets.[/b] A configuration format
## expressive enough to describe any arrangement of targets is a small programming
## language, and every deployment that has ever needed one was building the same four
## things: a file, a ring in memory, somewhere to forward to, and possibly a table. So
## this describes exactly those, each switched on by one flag — and a deployment that
## genuinely needs two collectors adds the second target in code, where a second one
## belongs.
##
## Layered like every other [DotConfig]: exported defaults, then a JSON file, then
## [code]DOT_LOG_*[/code] in the environment, then [code]--log-*[/code] on the command
## line. Which means a server started with [code]--log-level debug --log-remote-enabled
## true[/code] ships debug records to the collector for one run without any file being
## edited, and goes back to normal on restart.
##
## [b][member remote_token] and [member sentry_dsn] are refused from the environment and
## from the command line[/b], like every other secret in this family: both are readable
## by other processes on most systems, both end up in [code]ps[/code] output, and a token
## that appears in a pasted bug report has to be rotated.

## The named levels, for the string-valued settings.
const LEVEL_KEYS: Array[String] = [
	"trace", "debug", "info", "warn", "error", "fatal", "off",
]

@export_group("Levels")

## Global threshold: trace, debug, info, warn, error, fatal, off.
@export var level: String = "info"

## Per-channel overrides, as [code]channel=level[/code].
##
## What lets one subsystem be turned up without turning everything up — the reason a
## per-channel level exists at all is that global DEBUG buries the lines you wanted.
@export var channel_levels: PackedStringArray = PackedStringArray()

## The lowest level mirrored into the engine's own warning and error output.
##
## [code]error[/code] is right for a server. At [code]warn[/code] every recoverable
## warning arrives with an engine backtrace attached, which reads as a crash in a log an
## admin is scanning; see [member DotLogRouter.mirror_min_level] for the full reasoning.
@export var mirror_min_level: String = "error"

## Print to stdout as well as to the targets. On: a supervisor captures stdout.
@export var stdout: bool = true

## Seconds between flushes.
@export var flush_interval_sec: float = 2.0

@export_group("Context")

## Which service these records came from. The single most important tag.
@export var service: String = ""

## Which deployment: prod, staging, dev.
@export var env: String = ""

## Which machine. Empty asks the OS.
@export var host: String = ""

## Which process on that machine, when several servers share it.
@export var instance: String = ""

## The build. What makes "this started in 412" answerable.
@export var version: String = ""

@export_group("File")

@export var file_enabled: bool = true

@export var file_directory: String = "user://logs"

@export var file_basename: String = "server"

## One JSON object per line instead of the human format.
@export var file_json: bool = false

@export var file_level: String = "debug"

@export var file_max_bytes: int = 16 * 1024 * 1024

@export var file_max_files: int = 10

## Rotate at UTC midnight as well as on size.
@export var file_daily: bool = false

@export_group("Memory")

## Keep the recent records in memory, for the console and for bug reports.
@export var memory_enabled: bool = true

@export var memory_capacity: int = 512

@export_group("Syslog")

@export var syslog_enabled: bool = false

@export var syslog_host: String = "127.0.0.1"

@export var syslog_port: int = 514

## Use TCP with octet-counted framing instead of UDP datagrams.
@export var syslog_tcp: bool = false

@export var syslog_app: String = "dot-server"

@export var syslog_level: String = "info"

@export_group("Remote")

## Ship over HTTP to a collector.
@export var remote_enabled: bool = false

## Which wire format: ndjson, loki, elasticsearch, splunk, datadog, seq, gelf, otlp,
## sentry.
@export var remote_format: String = "ndjson"

## Base URL of the collector. Ignored for sentry, whose DSN carries the address.
@export var remote_url: String = ""

## The credential. Never accepted from the environment or the command line.
@export var remote_token: String = ""

## Sentry's DSN, when [member remote_format] is [code]sentry[/code].
@export var sentry_dsn: String = ""

## Minimum level to ship.
##
## [code]info[/code] rather than [code]debug[/code], because the bill and the search
## quality both come from this line. An error tracker narrows it further on its own.
@export var remote_level: String = "info"

@export var remote_batch: int = 100

## Fixed tags sent with every record, as [code]key=value[/code]. Kept low-cardinality:
## a tag carrying a player id is how a log backend gets taken down.
@export var remote_tags: PackedStringArray = PackedStringArray()

@export_group("Database")

@export var sql_enabled: bool = false

@export var sql_table: String = "dot_log"

## sqlite, postgres or mysql.
@export var sql_dialect: String = "sqlite"

@export var sql_level: String = "info"

@export var sql_retention_days: int = 30

@export_group("Redaction")

@export var redact_enabled: bool = true

## Treat IPv4 addresses as personal data. Off on a server, where they are the job.
@export var redact_ips: bool = false

@export var redact_emails: bool = true

## Fields dropped entirely, over and above the built-in secret list.
@export var redact_drop_keys: PackedStringArray = PackedStringArray()

@export_group("Flood control")

## Seconds an identical line is collapsed for. 0 disables.
@export var dedupe_window_sec: float = 0.0

## Records per second per channel, above which a channel is throttled. 0 disables.
@export var per_channel_rate: float = 0.0


func env_prefix() -> String:
	return "DOT_LOG_"


func cli_prefix() -> String:
	return "--log-"


func sensitive_keys() -> PackedStringArray:
	return PackedStringArray(["remote_token", "sentry_dsn"])


func validate() -> DotResult:
	if parse_level(level) < 0:
		return DotResult.fail(
			DotError.CODE_INVALID, "Unknown log level '%s'." % level,
			"one of: " + ", ".join(LEVEL_KEYS)
		)

	for entry: String in channel_levels:
		var parts: PackedStringArray = entry.split("=", false, 1)
		if parts.size() != 2 or parse_level(parts[1]) < 0:
			return DotResult.fail(
				DotError.CODE_INVALID,
				"A channel level must be written channel=level.",
				entry
			)

	if remote_enabled:
		if remote_format == "sentry":
			if sentry_dsn == "":
				return DotResult.fail(
					DotError.CODE_INVALID, "The sentry format needs a DSN."
				)
		elif remote_url == "":
			return DotResult.fail(
				DotError.CODE_INVALID,
				"Remote logging is on but no collector URL was given.",
				"set remote_url, or turn remote_enabled off"
			)

	if sql_enabled and dialect_of(sql_dialect) < 0:
		return DotResult.fail(
			DotError.CODE_INVALID, "Unknown SQL dialect '%s'." % sql_dialect,
			"sqlite, postgres or mysql"
		)

	if remote_enabled and make_format() == null:
		return DotResult.fail(
			DotError.CODE_INVALID, "Unknown log format '%s'." % remote_format,
			"ndjson, loki, elasticsearch, splunk, datadog, seq, gelf, otlp, sentry"
		)

	return DotResult.success(null)


# --- Building --------------------------------------------------------------

## Builds the router this document describes, without starting it.
##
## The caller adds it to the tree, which is what starts it — so a host can add a target
## of its own, or set the context, between building and starting.
func build_router() -> DotLogRouter:
	var router: DotLogRouter = DotLogRouter.new()
	router.name = "DotLogRouter"
	router.flush_interval_sec = flush_interval_sec
	router.stdout_on_start = 1 if stdout else 0
	router.mirror_min_level = maxi(0, parse_level(mirror_min_level))
	router.context = context_tags()

	if redact_enabled:
		var redactor: DotLogRedactor = DotLogRedactor.new()
		redactor.mask_ip_addresses = redact_ips
		redactor.mask_emails = redact_emails
		redactor.drop_keys = redact_drop_keys
		router.redactor = redactor

	if dedupe_window_sec > 0.0 or per_channel_rate > 0.0:
		var gate: DotLogGate = DotLogGate.new()
		gate.dedupe_window_sec = dedupe_window_sec
		gate.per_channel_rate = per_channel_rate
		router.gate = gate

	var memory: DotLogTargetMemory = null
	if memory_enabled:
		memory = DotLogTargetMemory.new(memory_capacity)
		router.targets.append(memory)

	if file_enabled:
		var file: DotLogTargetFile = DotLogTargetFile.new(file_directory, file_basename)
		file.json_lines = file_json
		file.max_file_bytes = file_max_bytes
		file.max_files = file_max_files
		file.daily = file_daily
		file.gate = _gate_at(file_level)
		router.targets.append(file)

	if syslog_enabled:
		var syslog: DotLogTargetSyslog = DotLogTargetSyslog.new(syslog_host, syslog_port)
		syslog.transport = (
			DotLogTargetSyslog.Transport.TCP
			if syslog_tcp
			else DotLogTargetSyslog.Transport.UDP
		)
		syslog.app_name = syslog_app
		syslog.gate = _gate_at(syslog_level)
		router.targets.append(syslog)

	if remote_enabled:
		var format: DotLogFormat = make_format()
		if format != null:
			var remote: DotLogTargetHttp = DotLogTargetHttp.new(format, remote_url)
			remote.target_name = remote_format
			remote.batch_size = remote_batch
			remote.gate = _gate_at(remote_level)
			# Breadcrumbs only mean anything to an error tracker, and only if there is
			# a ring to take them from.
			remote.breadcrumb_source = memory
			router.targets.append(remote)

	if sql_enabled:
		# The driver is not built here: it is a GDExtension this addon cannot name, and
		# the host assigns it. The target reports itself unopened until it has one,
		# which is a clearer failure than a silent no-op.
		var sql: DotLogTargetSql = DotLogTargetSql.new(null, sql_table)
		sql.dialect = dialect_of(sql_dialect) as DotLogSqlSchema.Dialect
		sql.retention_days = sql_retention_days
		sql.gate = _gate_at(sql_level)
		router.targets.append(sql)

	return router


## Applies the level settings to [DotLog] itself. Called separately from
## [method build_router], because a process may want the levels without the targets.
func apply_levels() -> void:
	DotLog.set_level(maxi(0, parse_level(level)))

	for entry: String in channel_levels:
		var parts: PackedStringArray = entry.split("=", false, 1)
		if parts.size() != 2:
			continue
		var parsed: int = parse_level(parts[1])
		if parsed >= 0:
			DotLog.set_channel_level(parts[0].strip_edges(), parsed)


## The context tags, with anything empty left out.
##
## An empty tag is worse than a missing one: it is a label with an empty value in every
## dashboard, and it groups every unconfigured server in the fleet together.
func context_tags() -> Dictionary:
	var out: Dictionary = {}
	if service != "":
		out["service"] = service
	if env != "":
		out["env"] = env
	out["host"] = host if host != "" else _hostname()
	if instance != "":
		out["instance"] = instance
	if version != "":
		out["version"] = version
	return out


## A format object for [member remote_format], or null if the name is unknown.
func make_format() -> DotLogFormat:
	match remote_format.to_lower():
		"ndjson", "json", "http":
			var ndjson: DotLogFormatNdjson = DotLogFormatNdjson.new()
			ndjson.token = remote_token
			return ndjson
		"loki", "grafana":
			var loki: DotLogFormatLoki = DotLogFormatLoki.new()
			loki.token = remote_token
			loki.static_labels = _tag_dictionary()
			return loki
		"elastic", "elasticsearch", "opensearch":
			var elastic: DotLogFormatElastic = DotLogFormatElastic.new()
			elastic.token = remote_token
			return elastic
		"splunk", "hec":
			var splunk: DotLogFormatSplunk = DotLogFormatSplunk.new()
			splunk.token = remote_token
			return splunk
		"datadog", "dd":
			var datadog: DotLogFormatDatadog = DotLogFormatDatadog.new()
			datadog.token = remote_token
			datadog.tags = _tag_dictionary()
			if service != "":
				datadog.service = service
			return datadog
		"seq", "clef":
			var seq: DotLogFormatSeq = DotLogFormatSeq.new()
			seq.token = remote_token
			return seq
		"gelf", "graylog":
			var gelf: DotLogFormatGelf = DotLogFormatGelf.new()
			gelf.token = remote_token
			return gelf
		"otlp", "opentelemetry", "otel":
			var otlp: DotLogFormatOtlp = DotLogFormatOtlp.new()
			otlp.token = remote_token
			if service != "":
				otlp.service_name = service
			return otlp
		"sentry":
			var sentry: DotLogFormatSentry = DotLogFormatSentry.new()
			sentry.dsn = sentry_dsn
			sentry.tags = _tag_dictionary()
			sentry.release = version
			return sentry
		_:
			return null


func _tag_dictionary() -> Dictionary:
	var out: Dictionary = {}
	for entry: String in remote_tags:
		var parts: PackedStringArray = entry.split("=", false, 1)
		if parts.size() == 2:
			out[parts[0].strip_edges()] = parts[1].strip_edges()
	return out


func _gate_at(level_name: String) -> DotLogGate:
	var gate: DotLogGate = DotLogGate.new()
	gate.min_level = maxi(0, parse_level(level_name)) as DotLog.Level
	return gate


## A level name to a [enum DotLog.Level], or -1.
##
## [method DotLog.parse_level] does this too, and this wraps it only to accept the short
## spellings a configuration file uses.
static func parse_level(name: String) -> int:
	var trimmed: String = name.strip_edges().to_lower()
	if trimmed == "warning":
		trimmed = "warn"
	var index: int = LEVEL_KEYS.find(trimmed)
	if index >= 0:
		return index
	return DotLog.parse_level(name)


static func dialect_of(name: String) -> int:
	match name.strip_edges().to_lower():
		"sqlite", "sqlite3":
			return DotLogSqlSchema.Dialect.SQLITE
		"postgres", "postgresql", "psql":
			return DotLogSqlSchema.Dialect.POSTGRES
		"mysql", "mariadb":
			return DotLogSqlSchema.Dialect.MYSQL
		_:
			return -1


static func _hostname() -> String:
	var name: String = OS.get_environment("HOSTNAME")
	if name == "":
		name = OS.get_environment("COMPUTERNAME")
	return name if name != "" else "unknown"
