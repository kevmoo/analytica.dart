# Cognitive Complexity Calculator

A deterministic, zero-token Cognitive Complexity calculation library, CLI
tool, and GitHub Action for Dart and Flutter repositories.

Unlike Cyclomatic Complexity (which measures control flow branch density),
Cognitive Complexity measures how difficult a method is for a human engineer
to read and understand, following the whitepaper specification by G. Ann
Campbell.

---

## Features

* **Modern Dart 3 AST Support**: Natively parses switch expressions, pattern
  guards (`when` clauses), and collection control flow structures.
* **Deterministic Engine**: Calculates complexity algorithmically without invoking
  LLM calls or external network requests.
* **Git Diff Analysis**: Compares current workspace declarations against a target
  base ref to isolate complexity deltas (Δ) in modified functions.
* **Lightweight GitHub Action**: Exposes workflow annotations and step summaries
  for CI check integration.

---

## 💻 CLI Usage

Run the scanner locally in your project root:

```bash
dart run cognitive_complexity [options] [targets]
```

### Options

* `-t, --threshold <value>`: Minimum score to display in the terminal (default: `0`).
* `-f, --fail-threshold <value>`: Ceilings score. Exits with code `1` if any
  declaration exceeds this value.
* `-d, --git-diff <git-ref>`: Compares current code against a git commit/ref,
  evaluating complexity deltas (Δ) on modified functions.
* `--fail-on-increase`: When using `--git-diff`, exits with code `1` if any
  modified function experienced a complexity score increase.
* `--format <text|json|github>`: Report output formatting (default: `text`).

---

## 📦 Library API Usage

Exposes programmatic analyzers for Dart and Flutter applications.

Add to `pubspec.yaml`:
```yaml
dependencies:
  cognitive_complexity: ^0.1.0-wip
```

### Programmatic Scan Example

```dart
import 'package:cognitive_complexity/cognitive_complexity.dart';

void main() {
  final analyzer = ComplexityAnalyzer();

  // Scan a directory or file path
  final results = analyzer.analyzePath('lib/src');

  for (final res in results) {
    print('${res.name}: score is ${res.score} (${res.filePath}:L${res.startLine})');
  }
}
```

---

## 🤖 GitHub Actions Integration

You can run complexity checks automatically on pull requests using the
integrated composite GitHub Action.

### PR Delta Audit Workflow Example

This workflow scans only the files and functions modified in the pull request. It
injects inline code review warnings directly on modified PR lines and prints a
beautiful markdown transition table to the workflow summary.

Create `.github/workflows/complexity.yml`:

```yaml
name: Cognitive Complexity Audit

on:
  pull_request:
    branches: [ main ]

jobs:
  audit:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Repository
        uses: actions/checkout@v4
        with:
          # Fetch full history so merge-base comparison can locate common ancestor
          fetch-depth: 0

      - name: Setup Dart SDK
        uses: dart-lang/setup-dart@v1

      - name: Run Complexity Scanner
        uses: kevmoo/cognitive_complexity.dart@main
        with:
          # Auto-configures pull request merge base comparison
          diff-base: origin/${{ github.base_ref }}
          fail-threshold: 15
          fail-on-increase: true
```

### Action Configuration Parameters (`with:`)

* `targets`: Space-separated directories or files to scan (default: `lib`).
* `threshold`: Minimum score to include in report tables (default: `0`).
* `fail-threshold`: Max complexity ceiling (default: `15`).
* `diff-base`: Git ref to compare against (e.g. `origin/main`). Leave empty
  to compare full repository files.
* `fail-on-increase`: Set `true` to block PR merge if complexity increases.
* `format`: Summary format: `github` (GHA annotations + summary), `text`, or `json`.
