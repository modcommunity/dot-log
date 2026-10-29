@tool
class_name DotLogRedactor
extends Resource

## Removes the things that must not leave the process, before anything ships them.
## Two passes: by key (reliable, extend it per field) and by shape (best-effort patterns for secrets interpolated into prose).
## Put values in fields, not the message. A [Resource] so one policy can be saved as a [code].tres[/code] for every server.

const CHANNEL := "log.redact"

## What a redacted value is replaced with. Kept distinctive so grepping a shipped log
## for it shows how much was removed.
const MASK := "<redacted>"

## Field names that are secret whatever they contain, matched case-insensitively as
## substrings — [code]token[/code] catches [code]refresh_token[/code] and
## [code]tokenExpiry[/code], and catching the second one too is the correct trade.
@export var secret_keys: PackedStringArray = PackedStringArray([
	"password", "passwd", "secret", "token", "api_key", "apikey",
	"authorization", "auth_header", "cookie", "session_id", "ticket",
	"private_key", "signature", "hmac", "credential", "passphrase",
])

## Field names to drop entirely rather than mask.
## For large non-secret values (a serialised map, a packet dump) that only cost quota at a hosted collector.
@export var drop_keys: PackedStringArray = PackedStringArray()

## Whether to scan message text as well as field values.
@export var scan_messages: bool = true

## Whether to treat IPv4 addresses as personal data and mask them.
## Off by default on purpose: a server admin needs addresses to correlate cheat reports and justify bans. Turn on for client builds shipping to a hosted collector.
@export var mask_ip_addresses: bool = false

## Whether to mask anything shaped like an email address.
@export var mask_emails: bool = true

## Extra regular expressions, each replaced with [constant MASK] wherever it matches.
@export var extra_patterns: PackedStringArray = PackedStringArray()

## How many leading characters of a masked value to keep.
## Zero is safe; four tells "which key" without being enough to authenticate with.
@export_range(0, 8, 1) var keep_prefix: int = 0

var _patterns: Array[RegEx] = []
var _compiled: bool = false
var _redactions: int = 0


func _init(p_secret_keys: PackedStringArray = PackedStringArray()) -> void:
	if not p_secret_keys.is_empty():
		secret_keys = p_secret_keys


## Compiles the patterns. Called on first use; call it early to surface a bad pattern at
## boot rather than on the first ERROR at three in the morning.
func compile() -> DotResult:
	_patterns.clear()
	_compiled = true

	var sources: PackedStringArray = PackedStringArray()

	# Anything after a bearer/basic scheme, or after a key-like query parameter or
	# assignment. Non-greedy up to whitespace or a delimiter, so one match does not
	# swallow the rest of the sentence.
	sources.append("(?i)\\b(bearer|basic|token)\\s+[A-Za-z0-9._~+/=-]{8,}")
	sources.append("(?i)\\b(api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret|signature|sig|auth)\\s*[=:]\\s*[^\\s,;&)\"']{4,}")

	# A JSON Web Token, which is three base64url segments and is unmistakable.
	sources.append("\\beyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{4,}")

	if mask_emails:
		sources.append("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")

	if mask_ip_addresses:
		sources.append("\\b(?:[0-9]{1,3}\\.){3}[0-9]{1,3}\\b")

	for extra: String in extra_patterns:
		sources.append(extra)

	for source: String in sources:
		var re: RegEx = RegEx.create_from_string(source)
		if re == null or not re.is_valid():
			# Both checks: create_from_string returns a RegEx with is_valid() false for a bad
			# pattern, not null, and that matches nothing for the life of the process. The caller
			# keeps the patterns that compiled and is told which one did not.
			return DotResult.fail(
				DotError.CODE_INVALID,
				"A redaction pattern would not compile.",
				source
			)
		_patterns.append(re)

	return DotResult.success(_patterns.size())


## Redacts one event, returning a new [Dictionary]. The original is never touched.
func apply(event: Dictionary) -> Dictionary:
	if not _compiled:
		var compiled: DotResult = compile()
		if not compiled.ok:
			DotLog.result(CHANNEL, "redactor patterns", compiled)

	var out: Dictionary = event.duplicate()
	out["fields"] = redact_fields(event.get("fields", {}))

	if scan_messages:
		out["message"] = redact_text(String(event.get("message", "")))

	return out


## Masks or drops secret-looking keys, recursing into nested dictionaries.
func redact_fields(fields: Dictionary) -> Dictionary:
	var out: Dictionary = {}

	for k: Variant in fields:
		var key: String = str(k)

		if _matches_any(key, drop_keys):
			_redactions += 1
			continue

		var value: Variant = fields[k]

		if _matches_any(key, secret_keys):
			_redactions += 1
			out[key] = mask(value)
			continue

		if typeof(value) == TYPE_DICTIONARY:
			out[key] = redact_fields(value as Dictionary)
		elif scan_messages and typeof(value) == TYPE_STRING:
			out[key] = redact_text(value as String)
		else:
			out[key] = value

	return out


## Replaces anything matching a pattern. Safe on text with no secrets in it.
func redact_text(text: String) -> String:
	if text == "":
		return text

	if not _compiled:
		var compiled: DotResult = compile()
		if not compiled.ok:
			return text

	var out: String = text
	for re: RegEx in _patterns:
		var before: String = out
		out = re.sub(out, MASK, true)
		if out != before:
			_redactions += 1

	return out


## What one secret value becomes.
func mask(value: Variant) -> String:
	if keep_prefix <= 0:
		return MASK
	var s: String = str(value)
	if s.length() <= keep_prefix:
		# Keeping a prefix as long as the value keeps the value.
		return MASK
	return s.substr(0, keep_prefix) + MASK


func _matches_any(key: String, list: PackedStringArray) -> bool:
	if list.is_empty():
		return false
	var lower: String = key.to_lower()
	for needle: String in list:
		if needle != "" and lower.contains(needle.to_lower()):
			return true
	return false


## How many values this redactor has removed, for [method describe].
func redaction_count() -> int:
	return _redactions


func describe() -> Dictionary:
	return {
		"patterns": _patterns.size(),
		"secret_keys": secret_keys.size(),
		"drop_keys": drop_keys.size(),
		"redactions": _redactions,
		"emails": mask_emails,
		"ips": mask_ip_addresses,
	}
