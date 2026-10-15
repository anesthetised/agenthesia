# Composer draft updates

The owner approved three fresh-process runs per variant, each with three local attachments and
500 draft updates. No network is used by the measurement. Build and warm-up time are excluded.

```sh
just bench-composer --revision 0327b61
just bench-composer
```

The harness compiles the selected composer sources with `-O`, linking ACP and JSONRPC from
`just build`. It hosts the composer in an `NSWindow`, lets its initial tasks run, then replaces the
draft binding and lays out the hosting view for each update. Commands are empty. This isolates
composer update work; it does not measure keyboard event delivery, display latency or VoiceOver.

| Variant | Run 1 (s) | Run 2 (s) | Run 3 (s) | Median (s) |
|---|---:|---:|---:|---:|
| Before (`0327b61`) | 0.895495958 | 0.891558208 | 0.869673583 | 0.891558208 |
| After (SwiftUI review fixes) | 0.527365375 | 0.566433208 | 0.553493583 | 0.553493583 |

The median elapsed time fell by approximately 38% for this workload. File icon state survives draft
updates, and line height is computed once for the fixed font. These measurements do not isolate the
contribution of either change.

The runner currently expects the Xcode SwiftPM build layout (`.build/debug/ACP.o` and `JSONRPC.o`)
and the project's Apple silicon / macOS 26 target.
