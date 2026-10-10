# History

Bugs found by running rather than reading. Both engine ones were invisible to `--check-only`, and one was invisible to an assertion about the value's length.

- **`Time.get_datetime_string_from_unix_time(t, true)` puts a space where RFC 3339 requires a `T`.** The second argument is `use_space`, not `utc`; the function is always UTC. The timestamp was the right length, the right value, and rejected or mis-parsed by Loki, OTLP and the bulk APIs. Found by a check asserting `stamp[10] == "T"` rather than `stamp.length() == 24`.
- **`RegEx.create_from_string` does not return null for a pattern it cannot compile.** It returns a `RegEx` whose `is_valid()` is false, and one of those matches nothing at all, silently, for the life of the process, so a typo in a redaction pattern would have looked exactly like a redactor that was working.
- **A 400 from a collector would have been retried forever** with every subsequent record stuck behind it, because dot-core maps unrecognised non-2xx onto the retryable `CODE_HTTP`. See [design.md](design.md#decisions-worth-not-reversing).
- **`log` did not exist on a dedicated server.** `DotLogCommands` was described as plugging into "a client console or a server console", and only the first was true: dot-server's console had no `add_source`. The one kind of process with a log worth tailing could not type `log tail`, and nothing reported it. Fixed in dot-server, not here; not one line of this addon changed, which is what the duck-typed shape was for.
- **Completion was unreachable from both consoles at once**: dot-console's panel returned early on any space in the input, and dot-server's `complete()` matched the partial against command names only. Both fixed in their own repositories.
