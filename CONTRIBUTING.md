# Contributing to ADSQL

Developer tooling lives in the package itself — SwiftPM plugins and committed git hooks — so
there are no shell scripts to run and nothing to install globally.

## One-time setup

Enable the repo's git hooks (pre-commit lint, pre-push test):

```sh
git config core.hooksPath .githooks
```

That's it. The toolchain's bundled `swift format` powers the plugins; no extra tools needed.

## Everyday commands

```sh
swift build                      # build the library
swift test                       # run the test + SQLite-differential suite
swift run -c release ADSQLBench  # benchmarks (sql / fts / table scenarios)

swift package format             # format in place (add --allow-writing-to-package-directory if prompted)
swift package lint               # formatting gate (what CI runs)
```

`swift package lint` is the single source of truth for the lint rules: `swift format lint
--strict`. Fix formatting with `swift package format`. Unlike the sibling ADJSON package, ADSQL
does **not** ban force-unwraps in a regex: `.strictMemorySafety()` already makes every unsafe
construct compiler-visible, so a provably-safe `!` is fine where the invariant is local.

## Sanitizers

`--sanitize` instruments the whole graph (no manifest change needed). TSan and ASan are
**mutually exclusive**, so run them as separate passes:

```sh
# Tests — race / memory correctness across the storage + SQL suite
swift test --sanitize=thread                        # data races: single-writer / wait-free readers, group commit
swift test --sanitize=address --sanitize=undefined  # OOB / use-after-free in the mmap'd page + record codecs
```

These catch what the test target's `-enable-actor-data-race-checks` (actor-isolation only)
cannot — the engine is a COW B+tree over `mmap` with `RawSpan`/`Unsafe*Pointer` page views and a
single-writer / wait-free-reader MVCC layer. **Don't read bench timings under a sanitizer**: TSan
is ~5–15× slower and ASan changes allocation layout, so the sanitized run is a correctness pass,
not a measurement — use the plain `swift run -c release ADSQLBench` for numbers.

## The `ADSQL_DEV` flag

Heavier dev tooling is gated behind the `ADSQL_DEV` environment variable so that packages which
merely *depend on* ADSQL never resolve it (the engine itself stays zero-dependency). Set it when
you want:

```sh
# Build-time formatting enforcement (the LintBuild plugin attaches to the ADSQL target):
ADSQL_DEV=1 swift build      # fails the build on any formatting violation

# Generate the DocC documentation (pulls swift-docc-plugin):
ADSQL_DEV=1 swift package generate-documentation --target ADSQL
```

The `format` and `lint` command plugins are dependency-free and work without the flag.

## Git hooks

Committed in `.githooks/` and enabled via `core.hooksPath` (above):

- **pre-commit** → `swift package lint` (check-only; blocks the commit on violations).
- **pre-push** → `swift test`.

## CI & documentation

A single workflow — **`.github/workflows/ci.yml`** — chains everything and only fans out after
the gate passes:

- **`build-test`** (macOS): lint → build → test, in one job (one cache, warm build).
- **`platforms`**: a cross-platform compile matrix (iOS / tvOS / watchOS / visionOS), on
  `main` / manual dispatch.
- **`sanitizers`**: TSan + ASan passes over `swift test`, on `main` / manual dispatch (not PRs);
  each pass rebuilds the graph under instrumentation, so they stay off the PR path.
- **`docs`**: builds the DocC site and deploys it to GitHub Pages on `main`. Requires Pages
  source = "GitHub Actions" in the repo settings (a one-time manual step).
