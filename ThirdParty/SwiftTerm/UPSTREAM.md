# SwiftTerm provenance and downstream patches

- Upstream: https://github.com/migueldeicaza/SwiftTerm
- Version: v1.13.0
- Revision: `8e7a1e154f470e19c709a00a8768df348ba5fc43`
- Imported: the complete `Sources/SwiftTerm/` tree and upstream `LICENSE`, without normalization.
- License: MIT; copyright and license retained in `LICENSE` and repository `licenses/SwiftTerm-MIT.txt`.

The app project and `scripts/terminal-url` both use this local package. The small
`Package.swift` retains the upstream library platforms, Swift 5 language mode,
Apple Metal shader resource, and non-Apple platform exclusions. It omits the
upstream fuzz/termcast executables, tests, benchmarks, documentation plugin and
all their external dependencies. Non-Apple builds do not declare the excluded
Apple shader resource; there are no package dependencies.

Only `Sources/SwiftTerm/Terminal.swift` differs from the upstream library:

1. `resetNormalBuffer()` installs the same weak-self scroll callback as initial
   construction, so a full reset (`ESC c`) cannot retain the terminal model.
2. `getBufferTailAsData(maxBytes:kind:)` returns the exact UTF-8 byte suffix of
   `getBufferAsData(kind:)`, with non-positive limits returning empty data. It
   visits rows from newest to oldest until enough bytes have been collected,
   using the same right trimming and per-row newline as the full exporter. It
   preserves byte boundaries even when the suffix starts inside a UTF-8 scalar.
   Only the final needed rows are translated. Memory is bounded by the requested
   suffix plus one translated row; a full individual row can exceed the limit.

No other upstream library files are changed. To review a future update, compare
all source hashes to the pinned upstream checkout and inspect the focused
`Terminal.swift` diff before replacing the snapshot.
