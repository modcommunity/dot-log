@tool
class_name DotLogFormat
extends Resource

## How a batch of records is written for one particular collector.
##
## [b]The transport is the same everywhere and the payload never is.[/b] Every hosted log
## service takes a batch of records over HTTP POST; not one of them agrees with another
## about the envelope, the timestamp units, where the credential goes, or what a
## successful response looks like. So [DotLogTargetHttp] owns batching, retries, back
## pressure and the queue — the parts that are genuinely common — and a format owns the
## bytes and the headers.
##
## Adding a service is therefore one small file: build the body, name the path and the
## header, and say what counts as success. Nothing else in the addon changes.
##
## [b]Read [method interpret] before writing one.[/b] A 200 is not a delivery. At least
## one widely used collector returns HTTP 200 with a body saying every single record was
## rejected, and a shipper that trusts the status code drops that batch and reports
## itself healthy for as long as the mistake lasts.

const CHANNEL := "log.format"

## The credential, whatever this service calls it. Never logged, never sent anywhere but
## its own endpoint, and refused from the environment and the command line by
## [DotLogConfig] — argv and the environment are readable by other processes and both
## end up in pasted bug reports.
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
##
## For the services whose credential already names the host — an error tracker's DSN is
## the whole address — so that a deployment configures one thing rather than two things
## that can disagree.
func endpoint_override() -> String:
	return ""


## Headers for the request, excluding Content-Type, which the target adds.
func headers() -> Dictionary:
	return extra_headers.duplicate()


## The batch as bytes.
##
## [param events] are in order, oldest first, and must not be modified — the caller
## requeues this exact array if the send fails.
func build(_events: Array, _context: Dictionary) -> PackedByteArray:
	return PackedByteArray()


## The most records this service accepts in one request.
##
## A real limit, not a preference: several of them reject an oversized batch outright,
## and a shipper that keeps retrying a batch that can never be accepted stops shipping
## anything at all.
func max_batch() -> int:
	return 500


## The largest payload this service accepts, in bytes. 0 means no documented limit.
func max_bytes() -> int:
	return 0


## Whether the response really means the records were accepted.
##
## [param response] is [DotHttp]'s success value:
## [code]{status, headers, body, body_text, attempts}[/code]. The default trusts a 2xx,
## which is right for the services that are honest about it.
func interpret(_response: Dictionary) -> DotResult:
	return DotResult.success(null)


## Whether this format wants breadcrumbs and would rather have one event than a batch.
##
## True only for the error trackers. It changes what [DotLogTargetHttp] sends: everything
## for a log collector, only the records worth an alert for a tracker.
func is_error_tracker() -> bool:
	return false


func describe() -> Dictionary:
	return {
		"format": format_name(),
		"path": default_path(),
		"max_batch": max_batch(),
		"authenticated": token != "",
	}
