High-performance structural code duplication and clone detection engine and CLI
tool for Dart and Flutter.

## Features

- **Token-Level & Structural Clone Detection**: Detects exact duplicates,
  structural clones (normalized string & numeric literals), and parameterized
  clones (renamed identifiers).
- **Polynomial Rolling Hash Engine**: Fast k-gram indexing with maximal
  bidirectional expansion for sub-second analysis across large monorepos.
- **Git Diff & PR Delta Scanning**: Analyzes pull request changes against a Git
  base ref (`--git-diff=origin/main`) and isolates newly introduced duplication
  (`--only-changed`).
- **Rich Multi-Format Reporting**: Outputs human-readable Markdown with
  clickable file line links, machine-readable JSON, terminal text summaries, and
  GitHub Actions step annotations.
- **Deduplication Metrics**: Computes per-file and package-level duplication
  percentages, duplicate cluster inventories, and estimated lines saved.

## Usage

### CLI Execution

Run directly using `dart run dedupe@`:

```bash
# Full package/repository scan
dart run dedupe@

# Scan specific directories or files
dart run dedupe@ lib/src packages/core

# JSON output for automated pipelines / AI agents
dart run dedupe@ --format=json

# Write machine-readable JSON report to file
dart run dedupe@ --json-output=report.json
```

### Git Diff / PR Regression Gate

Scan only modified files and evaluate delta duplication:

```bash
# Audit PR delta against base ref
dart run dedupe@ --git-diff=origin/main

# Only report clusters intersecting changed lines
dart run dedupe@ --git-diff=origin/main --only-changed

# Fail CI if duplication exceeds 5%
dart run dedupe@ --git-diff=origin/main --fail-threshold=5
```

## CLI options

<!-- mdformat off(prevent table wrapping) -->

| Flag | Default | Description |
| :--- | :---: | :--- |
| `-f`, `--format` | `markdown` | Output formatting mode for stdout (`markdown`, `json`, `github`, `text`). |
| `--json-output` | _None_ | File path to write machine-readable JSON report. |
| `-k`, `--min-tokens` | `40` | Minimum token count for a reported duplicate block. |
| `-l`, `--min-lines` | `4` | Minimum line count for a reported duplicate block. |
| `--[no-]ignore-comments` | `true` | Ignore comments when comparing tokens. |
| `--[no-]ignore-literals` | `true` | Normalize string and numeric literals to match structural clones. |
| `--[no-]ignore-identifiers` | `false` | Normalize identifiers to detect renamed/parameterized clones. |
| `--category` | `all` | Filter displayed clusters by category (`all`, `logic`, `data`, `boilerplate`). |
| `--bucket` | `all` | Filter displayed clusters by match bucket (`all`, `identical`, `structural`, `parameterized`, `gapped`). |
| `--top` | `0` | Limit number of top duplicate clusters to display (`0` for all). |
| `--fail-threshold` | _None_ | Exit with code `1` if overall duplication percentage (or diff duplication percentage when `--git-diff` is set) exceeds this ceiling. |
| `-d`, `--git-diff` | _None_ | Git reference (e.g. `origin/main` or `HEAD~1`) to compare against for PR/CL delta evaluation. |
| `--[no-]only-changed` | `false` | Only report clusters intersecting modified lines in the Git diff. |
| `--exclude` | _Standard_ | Comma-separated glob patterns to exclude (defaults to standard generated files: `**/*.g.dart`, `**/*.freezed.dart`, `**/*.pb*.dart`, etc.). |
| `--include` | `**/*.dart` | Comma-separated glob/wildcard patterns of files to include. |
| `--[no-]files` | `true` | Include per-file duplication metrics table in report. |
| `--[no-]clusters` | `true` | Include duplicate clusters list in report. |
| `--[no-]cache` | `true` | Enable content-hashed on-disk caching of AST candidate units and token sequences. |
| `--cache-dir` | _Auto_ | Custom directory path for disk cache (defaults to `.dart_tool/dedupe`). |
| `--clear-cache` | `false` | Clear existing disk cache before running analysis. |
| `-h`, `--help` | | Print usage information. |
| `--version` | | Print dedupe version. |

<!-- mdformat on -->

## Programmatic API

```dart
import 'package:dedupe/dedupe.dart';

void main() async {
  final options = DedupeOptions(
    targetPath: '.',
    minTokens: 30,
    minLines: 4,
    format: OutputFormat.markdown,
  );

  final engine = DedupeEngine(options);
  final report = await engine.analyze();

  print('Duplicate lines: ${report.summary.duplicateLines} (${report.summary.duplicationPercentage.toStringAsFixed(1)}%)');
  print('Clusters found: ${report.clusters.length}');

  for (final cluster in report.clusters) {
    print('Cluster ${cluster.id}: ~${cluster.estimatedLinesSaved} lines saved across ${cluster.instances.length} locations');
  }
}
```
