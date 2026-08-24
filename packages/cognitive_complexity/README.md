Long, complex functions are hard for humans (and AI agents) to understand.
Asking an agent to "refactor the code to make it cleaner" is poorly defined and
leaves the agent to make arbitrary decisions.

This Dart package, GitHub Action, and AI agent skill make finding and fixing
overly complex logic easy, reliable, and repeatable by implementing the
[Cognitive Complexity principles][whitepaper] articulated by SonarSource.

## ✨ Features

- **Modern Dart 3 AST Support**: Natively parses switch expressions, pattern
  guards (`when` clauses), and collection control flow structures.
- **Deterministic Engine**: Calculates complexity algorithmically without LLM
  calls, external network requests, or token latency.
- **Statement Data-Flow Analysis**: Evaluates variable inputs, mutations, and
  downstream live outputs for arbitrary statement slices to power automated
  method extraction.
- **Git Diff Analysis & Ratchet**: Compares working copy changes against a
  target base ref to isolate complexity deltas (Δ) in modified functions.
- **Lightweight GitHub Action**: Exposes workflow annotations and markdown
  summary tables for automated CI quality gates.

## ⚡ Quick Start

### CLI (On-Demand)

Run the scanner directly in any Dart or Flutter project without prior
installation:

```bash
dart run cognitive_complexity@
```

_(Requires Dart SDK **3.12.0 or greater**)_.

### `cognitive_complexity` CLI Options

<!-- CLI_README_START cognitive_complexity -->
```console
$ cognitive_complexity --help
Dart & Flutter Cognitive Complexity Calculator

Usage: dart run cognitive_complexity [options] <file_or_directory>

Options:
-h, --help                        Print this usage information.
-t, --threshold                   Minimum complexity score to include in output.
                                  (defaults to "0")
-f, --fail-threshold              Exit with non-zero code if any function score exceeds this value.
-d, --git-diff=<git-ref>          Git reference to compare against. Only evaluates modified files and function complexity deltas.
    --fail-on-increase            When using --git-diff, exit with non-zero code if any function increased in complexity. When --fail-threshold is also set, only increases that exceed the threshold fail.
    --format                      Output format.
                                  [text (default), json, github]
    --comment-output=<path>       With --format=github, also write a standalone report to this path, ordered by significance and capped by --max-comment-rows. Intended for posting as a PR comment while the step summary keeps the full table.
    --max-comment-rows=<count>    Maximum table rows in --comment-output (0 = unlimited). GitHub rejects comment bodies over 65536 characters.
                                  (defaults to "0")
```
<!-- CLI_README_END cognitive_complexity -->

### `data_flow` CLI Options

<!-- CLI_README_START data_flow -->
```console
$ data_flow --help
Dart Data-Flow & Method Extraction Analyzer

Analyzes a target slice of code inside a Dart function and deterministically
calculates required parameters (inputs), modified variables (mutations),
and live return values (outputs) for safe method extraction.

Usage: dart run cognitive_complexity:data_flow [options] <file.dart[:start-end]>

Examples:
  # Analyze lines 45 through 80 of auth.dart (Agent-first JSON default)
  dart run cognitive_complexity:data_flow lib/src/auth.dart:45-80

  # Analyze with explicit flags and custom helper name
  dart run cognitive_complexity:data_flow --lines=45-80 --name=_validateToken lib/src/auth.dart

  # Human-readable terminal output
  dart run cognitive_complexity:data_flow --format=text lib/src/auth.dart:45-80

Options:
-h, --help        Print this usage information.
-l, --lines       Target 1-based line range of the code block to extract (e.g. 45-80).
-n, --name        Name for the proposed extracted helper function.
                  (defaults to "_extracted")
-f, --format      Output format.
                  [json (default), text]
    --sdk-path    Path to the Dart SDK root used for analysis. Defaults to auto-discovery (running VM, DART_SDK environment variable, PATH, FLUTTER_ROOT).
```
<!-- CLI_README_END data_flow -->

### Library API

Add `cognitive_complexity` to your `pubspec.yaml`:

```dart
import 'package:cognitive_complexity/cognitive_complexity.dart';

void main() {
  final analyzer = ComplexityAnalyzer();
  final results = analyzer.analyzePath('lib');

  for (final res in results) {
    print('${res.name}: score is ${res.score} (${res.filePath}:L${res.startLine})');
  }
}
```

### GitHub Actions

Add automated complexity audits to `.github/workflows/complexity.yml`:

```yaml
name: Cognitive Complexity Audit

on:
  pull_request:
    branches: [main]

jobs:
  audit:
    runs-on: ubuntu-latest
    permissions:
      pull-requests: write # Required for sticky PR comment summaries
      contents: read
    steps:
      - name: Checkout Repository
        uses: actions/checkout@v7
        with:
          fetch-depth: 0 # Full history required for diff-base merge-base comparison

      - name: Setup Dart SDK
        uses: dart-lang/setup-dart@v1

      - name: Run Complexity Scanner
        uses: kevmoo/analytica.dart/packages/cognitive_complexity@main
        with:
          diff-base: origin/${{ github.base_ref }}
          fail-threshold: 15
          fail-on-increase: true
```

#### Action Inputs Reference

<!-- mdformat off(prevent table wrapping) -->
| Input | Default | Description |
| :--- | :---: | :--- |
| `targets` | `lib` | Space-separated list of directories or files to scan. |
| `threshold` | `0` | Minimum score required to include a declaration in summary tables. |
| `fail-threshold` | `15` | Maximum complexity ceiling allowed before failing the build. |
| `diff-base` | _Auto_ | Git ref to compare against (e.g. `origin/main`). Auto-detects PR base. |
| `fail-on-increase` | `false` | When `true`, blocks PR merge on complexity increases exceeding `fail-threshold`. |
| `format` | `github` | Output format: `github` (annotations + step summary), `text`, or `json`. |
| `max-comment-rows` | `0` | Maximum table rows in the sticky PR comment (0 = unlimited). |
<!-- mdformat on -->

## 🧠 AI Agent Integration

This repository packages an agent skill (`dart-cognitive-complexity`) to train
AI pair programmers on Cognitive Complexity scoring and refactoring patterns:

```bash
npx skills add kevmoo/analytica.dart --skill dart-cognitive-complexity
```

## 📚 Documentation & Guides

Explore in-depth documentation in the [`doc/`](doc/) directory:

- 📐 [Scoring Model & Specification](doc/scoring.md): Complete scoring table,
  nesting multipliers, and Dart 3 AST nuances.
- 💻 [CLI Reference & CI Ratcheting](doc/cli.md): Command-line options, git diff
  delta evaluation, and exit codes.
- 🔄 [Statement Data-Flow Analysis](doc/data_flow.md): Statement slicing,
  variable lifecycles, and automated method extraction helper.

[whitepaper]: https://www.sonarsource.com/docs/CognitiveComplexity.pdf
