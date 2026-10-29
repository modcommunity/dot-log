@tool
class_name DotLogFormat
extends Resource

## How a batch of records is written for one particular collector.
## [DotLogTargetHttp] owns batching, retries and the queue; a format owns the bytes, the headers and what counts as success.
## Read [method interpret] before writing one: a 200 is not a delivery.

# No log channel: a pure encoder from a record to bytes, called from inside a target,
# which is itself inside a log call -- so it must not log, for the reason DotLogTarget
# gives, and it has nothing outside the process to fail against anyway.

## The credential, whatever this service calls it.
## Never logged; refused from the environment and command line by [DotLogConfig].
@export var token: String = ""

## Extra headers, merged last, for a gateway in front of the collector.
@export var extra_headers: Dictionary = {}


## Short name, for logs and [method describe].
func format_name() -> String:
	return "none"


## The MIME type of what [method build] returns.
func content_type() -> String:
	return "application/json"


## The path this service ingests on, appended to the target's base URL when that URL has
## no path of its own. Empty means the base URL is complete as given.
func default_path() -> String:
	return ""


## A complete URL that replaces the target's own, or empty to use the target's.
## For services whose credential already names the host (an error tracker's DSN), so one thing is configured, not two.
func endpoint_override() -> String:
	return ""


## Headers for the request, excluding Content-Type, which the target adds.
func headers() -> Dictionary:
	return extra_headers.duplicate()


## The batch as bytes.
## [param events] are oldest first and must not be modified: the caller requeues this exact array if the send fails.
func build(_events: Array, _context: Dictionary) -> PackedByteArray:
	return PackedByteArray()


## The most records this service accepts in one request.
## A real limit: several services reject an oversized batch outright, and retrying one that can never be accepted stalls shipping.
func max_batch() -> int:
	return 500


## The largest payload this service accepts, in bytes. 0 means no documented limit.
func max_bytes() -> int:
	return 0


## Whether the response really means the records were accepted.
## [param response] is [DotHttp]'s success value: [code]{status, headers, body, body_text, attempts}[/code]. The default trusts a 2xx.
func interpret(_response: Dictionary) -> DotResult:
	return DotResult.success(null)


## Whether this format wants breadcrumbs and would rather have one event than a batch.
## True only for the error trackers: [DotLogTargetHttp] then sends only the records worth an alert.
func is_error_tracker() -> bool:
	return false


func describe() -> Dictionary:
	return {
		"format": format_name(),
		"path": default_path(),
		"max_batch": max_batch(),
		"authenticated": token != "",
	}
