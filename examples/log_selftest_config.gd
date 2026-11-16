extends "log_selftest_formats.gd"

## The config, layout, config-built targets, level and command checks.

func _test_config() -> void:
	_section("config")

	var config: DotLogConfig = DotLogConfig.new()
	_check("the defaults validate", config.validate().ok)
	_check("info is the default level", DotLogConfig.parse_level(config.level) == DotLog.Level.INFO)
	_check("error is the default mirror level", DotLogConfig.parse_level(config.mirror_min_level) == DotLog.Level.ERROR)

	_check("levels parse by name", DotLogConfig.parse_level("warn") == DotLog.Level.WARN)
	_check("and by the long spelling", DotLogConfig.parse_level("warning") == DotLog.Level.WARN)
	_check("and case-insensitively", DotLogConfig.parse_level("ERROR") == DotLog.Level.ERROR)
	_check("an unknown level is -1", DotLogConfig.parse_level("loud") == -1)

	config.level = "loud"
	_check("and fails validation", not config.validate().ok)
	config.level = "debug"

	config.channel_levels = PackedStringArray(["net=trace", "chat"])
	_check("a malformed channel level is refused", not config.validate().ok)
	config.channel_levels = PackedStringArray(["net=trace"])
	_check("a good one is accepted", config.validate().ok)

	config.remote_enabled = true
	config.remote_url = ""
	_check("remote logging with no URL is refused", not config.validate().ok)
	config.remote_format = "sentry"
	_check("and sentry with no DSN is too", not config.validate().ok)
	config.sentry_dsn = "https://k@h/1"
	_check("a DSN is enough for sentry", config.validate().ok)
	config.remote_format = "nonsense"
	config.remote_url = "https://x.example"
	_check("an unknown format is refused", not config.validate().ok)
	config.remote_enabled = false
	config.remote_format = "ndjson"

	config.sql_enabled = true
	config.sql_dialect = "oracle"
	_check("an unknown dialect is refused", not config.validate().ok)
	config.sql_dialect = "postgres"
	_check("a known one is not", config.validate().ok)
	_check("and maps to the schema's enum", DotLogConfig.dialect_of("postgres") == DotLogSqlSchema.Dialect.POSTGRES)
	config.sql_enabled = false

	_check("the secrets are named", config.sensitive_keys().has("remote_token") and config.sensitive_keys().has("sentry_dsn"))
	_check("the env prefix is the family's shape", config.env_prefix() == "DOT_LOG_")
	_check("and so is the cli prefix", config.cli_prefix() == "--log-")

	var applied: PackedStringArray = config.apply_dictionary({
		"level": "warn", "file_basename": "arena", "memory_capacity": 64,
	})
	_check("a dictionary layer applies", config.level == "warn" and config.file_basename == "arena" and applied.size() == 3)
	_check("and an unknown key is remembered, not fatal", config.apply_dictionary({"nonsense": 1}).size() == 0 and config.unknown_keys.size() > 0)

	config.service = "arena"
	config.env = "prod"
	var tags: Dictionary = config.context_tags()
	_check("context tags skip what is empty", not tags.has("instance"))
	_check("and always name a host", tags.has("host"))

	config.remote_tags = PackedStringArray(["region=eu", "tier=free"])
	config.remote_token = "t"
	var loki: DotLogFormat = config.make_format()
	config.remote_format = "loki"
	loki = config.make_format()
	_check("a format is built by name", loki != null and loki.format_name() == "loki")
	_check("carrying the token", loki.token == "t")
	_check("and the fixed tags", (loki as DotLogFormatLoki).static_labels.has("region"))
	config.remote_format = "otlp"
	_check("otlp takes the service name", (config.make_format() as DotLogFormatOtlp).service_name == "arena")
	config.remote_format = "elasticsearch"
	_check("an alias resolves", config.make_format().format_name() == "elasticsearch")
	config.remote_format = "nonsense"
	_check("and an unknown name is null", config.make_format() == null)

	_line("")
	_done()


func _test_cfg_layout() -> void:
	_section("log.yml: cfg/addons/dot_log wins over the flat file, cfg/server/addons/dot_log wins over both")

	var legacy := "user://dot_log_selftest_legacy"
	var addon_dir := "user://cfg/addons/dot_log"
	var server_dir := "user://cfg/server/addons/dot_log"
	DotPaths.remove_tree(addon_dir)
	DotPaths.remove_tree(server_dir)
	DotPaths.remove_tree(legacy)
	DotCfgLegacy.reset()

	_write_text(legacy.path_join("log.yml"), "level: debug\nservice: old\n")
	var config := DotLogConfig.new()
	var res := config.load_cfg("log.yml", legacy)
	_check("only the flat file: it is still read", res.ok and config.level == "debug", res)
	_check("and warned once", DotCfgLegacy.warned_count() == 1)
	DotLogConfig.new().load_cfg("log.yml", legacy)
	_check("a second load does not warn again", DotCfgLegacy.warned_count() == 1)

	_write_text(addon_dir.path_join("log.yml"), "level: warn\n")
	config = DotLogConfig.new()
	res = config.load_cfg("log.yml", legacy)
	_check("the new path wins over the flat file", res.ok and config.level == "warn", res)
	_check("and the two are never merged", config.service == "")

	_write_text(server_dir.path_join("log.yml"), "level: error\nremote_token: abc\n")
	config = DotLogConfig.new()
	res = config.load_cfg("log.yml", legacy)
	_check("the operator's server layer wins", res.ok and config.level == "error", res)
	_check("a secret in a file is read", config.remote_token == "abc")

	var game_dir := "user://cfg/game/mg-test/dot_log"
	var server_game_dir := "user://cfg/server/game/mg-test/dot_log"
	DotAddonConfig.game = "mg-test"
	_write_text(game_dir.path_join("log.yml"), "level: trace\n")
	config = DotLogConfig.new()
	res = config.load_cfg("log.yml", legacy)
	_check("the game tier sits between the addon's and the operator's", res.ok and config.level == "error", res)
	DotPaths.remove_tree(server_dir)
	config = DotLogConfig.new()
	res = config.load_cfg("log.yml", legacy)
	_check("and wins over the addon's own", res.ok and config.level == "trace", res)
	_write_text(server_game_dir.path_join("log.yml"), "level: fatal\n")
	config = DotLogConfig.new()
	res = config.load_cfg("log.yml", legacy)
	_check("the operator's per-game tier wins over the game's", res.ok and config.level == "fatal", res)
	DotAddonConfig.game = ""
	DotPaths.remove_tree("user://cfg/game/mg-test")
	DotPaths.remove_tree("user://cfg/server/game/mg-test")

	DotPaths.remove_tree(addon_dir)
	DotPaths.remove_tree(server_dir)
	DotPaths.remove_tree(legacy)
	DotCfgLegacy.reset()
	_write_text("user://cfg/server/dot_log/log.yml", "level: info\n")
	config = DotLogConfig.new()
	res = config.load_cfg("log.yml", legacy)
	_check("the old cfg/server/dot_log/ still loads", res.ok and config.level == "info", res)
	_check("and warns once", DotCfgLegacy.warned_count() == 1)
	DotPaths.remove_tree("user://cfg/server/dot_log")
	DotPaths.remove_tree(server_dir)
	DotPaths.remove_tree(legacy)
	DotCfgLegacy.reset()
	_line("")
	_done()


func _write_text(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _test_config_builds() -> void:
	_section("config builds a router")

	var config: DotLogConfig = DotLogConfig.new()
	config.service = "arena"
	config.env = "test"
	config.file_enabled = true
	config.file_directory = "user://selftest-config"
	config.memory_enabled = true
	config.dedupe_window_sec = 5.0
	config.mirror_min_level = "error"
	config.flush_interval_sec = 30.0

	var router: DotLogRouter = config.build_router()
	_check("a router is built", router != null)
	_check("with the file and the memory ring", router.targets.size() == 2)
	_check("a redactor", router.redactor != null)
	_check("and a gate, because dedupe was asked for", router.gate != null and router.gate.dedupe_window_sec == 5.0)
	_check("the context is set", str(router.context["service"]) == "arena")
	_check("and the interval", router.flush_interval_sec == 30.0)

	config.remote_enabled = true
	config.remote_format = "seq"
	config.remote_url = "https://seq.example"
	config.remote_level = "warn"
	var with_remote: DotLogRouter = config.build_router()
	_check("a remote target is added", with_remote.targets.size() == 3)
	var remote: DotLogTarget = with_remote.find_target("seq")
	_check("named after its format", remote != null)
	_check("gated at the configured level", remote.gate != null and remote.gate.min_level == DotLog.Level.WARN)

	config.remote_format = "sentry"
	config.sentry_dsn = "https://k@h.example/1"
	var with_tracker: DotLogRouter = config.build_router()
	var tracker: DotLogTargetHttp = with_tracker.find_target("sentry") as DotLogTargetHttp
	_check("an error tracker gets the memory ring for breadcrumbs", tracker != null and tracker.breadcrumb_source != null)

	# add_child is what starts it: build_router leaves autostart on, so a host that adds
	# it to the tree has a working logger without a second call.
	add_child(router)
	await get_tree().process_frame
	_check("the built router starts on being added to the tree", router.is_started())
	_check("and set DotLog's mirror level", DotLog.mirror_min_level == DotLog.Level.ERROR)

	config.apply_levels()
	_check("apply_levels sets the global level", DotLog.get_level() == DotLog.Level.INFO)

	await router.shutdown()
	router.queue_free()
	# free(), not queue_free(): neither of these was ever added to the tree, and the
	# suite quits before the next idle frame would have collected them.
	with_remote.free()
	with_tracker.free()
	DotPaths.remove_tree("user://selftest-config")
	DotLog.set_level(DotLog.Level.ERROR)
	_line("")
	_done()


func _test_levels() -> void:
	_section("levels")

	_check("there are six, and OFF", DotLog.Level.OFF == 6 and DotLog.LEVEL_NAMES.size() == 7)
	_check("in severity order", DotLog.Level.TRACE < DotLog.Level.DEBUG and DotLog.Level.DEBUG < DotLog.Level.INFO and DotLog.Level.INFO < DotLog.Level.WARN and DotLog.Level.WARN < DotLog.Level.ERROR and DotLog.Level.ERROR < DotLog.Level.FATAL)
	_check("each has a name", DotLog.level_name(DotLog.Level.FATAL) == "FATAL")
	_check("and a tag", DotLog.LEVEL_TAGS[DotLog.Level.FATAL] == "FTL")

	# The level is in the line, at a fixed width, in both styles.
	for level: int in range(DotLog.Level.TRACE, DotLog.Level.OFF):
		var line: String = DotLogEvent.text_line(_event(level, "net", "a message"), false)
		_check(
			"a %s line shows its level" % DotLog.LEVEL_NAMES[level],
			line.begins_with(DotLog.LEVEL_TAGS[level]),
			null,
			line
		)

	_check("every tag is three characters", DotLog.level_column(DotLog.Level.INFO).length() == 3 and DotLog.level_column(DotLog.Level.FATAL).length() == 3)

	DotLog.level_style = DotLog.LevelStyle.NAME
	var named: String = DotLogEvent.text_line(_event(DotLog.Level.WARN, "net", "x"), false)
	_check("the NAME style spells it out", named.begins_with("WARN"), null, named)
	_check("padded to the same width for every level", DotLog.level_column(DotLog.Level.INFO).length() == DotLog.level_column(DotLog.Level.WARN).length())
	DotLog.level_style = DotLog.LevelStyle.TAG
	_check("and the style goes back", DotLogEvent.text_line(_event(DotLog.Level.WARN, "net", "x"), false).begins_with("WRN"))

	# Every wire format carries the level, under whatever name that format uses.
	var event: Dictionary = _event(DotLog.Level.ERROR, "net", "broke")
	_check("flatten names it", str(DotLogEvent.flatten(event, {})["level"]) == "error")
	_check("severity_name is the collectors' spelling", DotLogEvent.severity_name(DotLog.Level.WARN) == "warning")

	var json: Dictionary = _parse(DotLog.format_json(_record(DotLog.Level.WARN, "net", "x")))
	_check("dot-core's JSON has the name", str(json["level"]) == "WARN")
	_check("and the number, because a string sorts wrong", int(json["severity"]) == DotLog.Level.WARN)

	# DotLog.at, for a level that is data rather than a call site.
	var ring: DotLogTargetMemory = DotLogTargetMemory.new(8)
	ring.open()
	var sink: Callable = func(rec: Dictionary) -> void: ring.write(DotLogEvent.from_record(rec))
	var saved_level: int = DotLog.get_level()
	DotLog.set_level(DotLog.Level.TRACE)
	DotLog.add_sink(sink)
	DotLog.at(DotLog.Level.WARN, "test", "at a chosen level")
	_check("DotLog.at emits at the level it was given", ring.size() == 1 and int(ring.tail(1)[0]["level"]) == DotLog.Level.WARN)
	DotLog.at(DotLog.Level.OFF, "test", "this must not be logged")
	_check("and refuses OFF, which is a threshold and not a severity", ring.size() == 1)
	DotLog.remove_sink(sink)
	DotLog.set_level(saved_level)

	_line("")
	_done()


func _test_commands() -> void:
	_section("log command")

	var router: DotLogRouter = DotLogRouter.new()
	router.autostart = false
	router.flush_interval_sec = 60.0
	var memory: DotLogTargetMemory = DotLogTargetMemory.new(64)
	router.targets.append(memory)
	add_child(router)
	await router.start()
	DotLog.set_level(DotLog.Level.TRACE)

	var commands: DotLogCommands = DotLogCommands.new(router)

	_check("it claims `log` and nothing else", commands.claims("log") and not commands.claims("logs"))
	_check("and names it", commands.names().has("log"))
	_check("and has help", commands.help_for("log").contains("tail"))

	DotLog.info("net", "a line to find")
	DotLog.warn("chat", "another line")

	var tail: DotResult = commands.execute("log tail 5")
	_check("tail returns lines", tail.ok and str(tail.value).contains("a line to find"), tail)
	_check("with their level shown", str(tail.value).contains("inf") and str(tail.value).contains("WRN"))

	var grep: DotResult = commands.execute("log grep another")
	_check("grep finds one", grep.ok and str(grep.value).contains("another line") and not str(grep.value).contains("a line to find"), grep)
	_check("and says so when it finds none", str(commands.execute("log grep zzzznope").value).contains("no match"))

	var levels: DotResult = commands.execute("log level")
	_check("level lists all six and what they mean", levels.ok and str(levels.value).contains("FATAL") and str(levels.value).contains("cannot continue"), levels)

	var set_level: DotResult = commands.execute("log level warn")
	_check("level sets it", set_level.ok and DotLog.get_level() == DotLog.Level.WARN, set_level)
	_check("an unknown level is refused", not commands.execute("log level loud").ok)
	commands.execute("log level trace")

	var channel: DotResult = commands.execute("log channel net debug")
	_check("channel sets one channel", channel.ok and DotLog.get_channel_level("net") == DotLog.Level.DEBUG, channel)
	commands.execute("log channel net default")
	_check("and clears it again", DotLog.get_channel_level("net") == DotLog.get_level())

	var targets: DotResult = commands.execute("log targets")
	_check("targets lists them with their health", targets.ok and str(targets.value).contains("memory") and str(targets.value).contains("written"), targets)

	var status: DotResult = commands.execute("log")
	_check("a bare `log` is the status", status.ok and str(status.value).contains("log router"))

	var before: int = memory.size()
	var test: DotResult = commands.execute("log test error a deliberate one")
	_check("test emits a record", test.ok and memory.size() == before + 1, test)
	_check("at the level asked for", int(memory.tail(1)[0]["level"]) == DotLog.Level.ERROR)
	_check("with the message", str(memory.tail(1)[0]["message"]) == "a deliberate one")
	_check("on its own channel, so it cannot be mistaken for a real one", str(memory.tail(1)[0]["channel"]) == DotLogCommands.CHANNEL)

	var fatal_test: DotResult = commands.execute("log test fatal pretend everything broke")
	_check("but FATAL is refused, because it promises a shutdown", not fatal_test.ok, null, fatal_test.code())
	_check("and says why", fatal_test.error.detail.contains("cannot continue"))

	var unknown: DotResult = commands.execute("log nonsense")
	_check("an unknown subcommand lists the real ones", not unknown.ok and unknown.error.detail.contains("tail"))

	var completions: PackedStringArray = commands.complete("log ")
	_check("completion offers the subcommands", completions.has("log tail"), null, ",".join(completions))
	var level_completions: PackedStringArray = commands.complete("log level w")
	_check("and the level names", level_completions.has("log level warn"), null, ",".join(level_completions))

	var detached: DotLogCommands = DotLogCommands.new(null)
	_check("with no router it says so rather than failing", detached.execute("log").ok and str(detached.execute("log").value).contains("nowhere else"))
	_check("and refuses what it cannot do", not detached.execute("log tail").ok)

	await router.shutdown()
	router.queue_free()
	DotLog.set_level(DotLog.Level.ERROR)
	_line("")
	_done()
