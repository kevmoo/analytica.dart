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

<!-- CLI_README_START -->
```console
$ dedupe --help
dedupe - High-performance code duplication and clone detection engine for Dart.

Usage: dedupe [options] [target_path]

-f, --format                               Output formatting mode for stdout (json for agents/CI, markdown for humans).
                                           [markdown (default), json, github, text]
    --json-output=<path/to/report.json>    Write machine-readable JSON analysis report to the specified file (recommended for CI pipelines alongside human stdout).
-k, --min-tokens                           Minimum token count for a reported duplicate block.
                                           (defaults to "40")
-l, --min-lines                            Minimum line count for a reported duplicate block.
                                           (defaults to "4")
    --[no-]ignore-comments                 Ignore single-line and doc comments when comparing tokens.
                                           (defaults to on)
    --[no-]ignore-literals                 Normalize string and numeric literals to detect structural clones.
                                           (defaults to on)
    --[no-]ignore-identifiers              Normalize variable and type identifiers to detect parameterized clones.
    --category                             Filter displayed clusters by category.
                                           [all (default), logic, data, boilerplate]
    --bucket                               Filter displayed clusters by match bucket.
                                           [all (default), identical, structural, parameterized, gapped]
    --top                                  Limit number of top duplicate clusters to display (0 for all).
                                           (defaults to "0")
    --fail-threshold=<percentage>          Exit with non-zero code (1) if overall duplication percentage (or diff duplication percentage when --git-diff is set) exceeds this ceiling.
-d, --git-diff=<git-ref>                   Git reference (e.g. origin/main or HEAD~1) to compare against for PR/CL delta evaluation.
    --[no-]only-changed                    Only report duplicate clusters that intersect modified lines in the Git diff.
    --exclude=<pattern1,pattern2>          Comma-separated glob/wildcard patterns of files to exclude.
    --include=<pattern1,pattern2>          Comma-separated glob/wildcard patterns of files to include.
    --[no-]files                           Include per-file duplication metrics table in report.
                                           (defaults to on)
    --[no-]clusters                        Include duplicate clusters list in report.
                                           (defaults to on)
    --[no-]cache                           Enable content-hashed on-disk caching of AST candidate units and token sequences.
                                           (defaults to on)
    --cache-dir=<path>                     Custom directory path for disk cache (defaults to .dart_tool/dedupe).
    --clear-cache                          Clear existing disk cache before running analysis.
    --sdk-path                             Path to the Dart SDK root (overrides auto-discovery).
-h, --help                                 Print usage information.
    --version                              Print dedupe version.
```
<!-- CLI_README_END -->

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

## 🧠 AI Agent Integration

This repository packages an agent skill (`dart-dedupe`) to train AI pair programmers on structural code duplication audits, clone triage, and safe deduplication refactoring:

```bash
npx skills add kevmoo/analytica.dart --skill dart-dedupe
```
