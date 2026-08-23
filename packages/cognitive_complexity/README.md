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
