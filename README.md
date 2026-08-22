# Analytica

Monorepo workspace for Dart static analysis, Cognitive Complexity metrics, data-flow refactoring, dead code detection, and structural duplicate code detection.

---

## 🚀 GitHub Action: Dart Cognitive Complexity Audit

Automated Cognitive Complexity calculator and Git diff regression scanner for Dart and Flutter repositories.

### Quick Start Workflow

Add `.github/workflows/complexity.yml` to your repository:

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
          fetch-depth: 0 # Full history required for diff-base comparison

      - name: Setup Dart SDK
        uses: dart-lang/setup-dart@v1

      - name: Run Complexity Scanner
        uses: kevmoo/analytica.dart@main
        with:
          diff-base: origin/${{ github.base_ref }}
          fail-threshold: 15
          fail-on-increase: true
```

### Action Inputs Reference

<!-- mdformat off(prevent table wrapping) -->

| Input | Default | Description |
| :--- | :---: | :--- |
| `targets` | `lib` | Space-separated list of directories or files to scan. |
| `threshold` | `0` | Minimum score required to include a declaration in summary tables. |
| `fail-threshold` | `15` | Maximum complexity ceiling allowed before failing the build. |
| `diff-base` | _Auto_ | Git ref to compare against (e.g. `origin/main`). Auto-detects PR base. |
| `fail-on-increase` | `false` | When `true`, blocks PR merge on complexity increases exceeding `fail-threshold`. |
| `format` | `github` | Output format: `github` (annotations + step summary), `text`, or `json`. |

<!-- mdformat on -->

---

## 📦 Workspace Packages

* [`cognitive_complexity`](packages/cognitive_complexity/): Algorithmic Cognitive Complexity scoring engine, CLI tool, and data-flow analyzer.
* [`dedupe`](packages/dedupe/): High-performance code duplication and clone detection engine and CLI tool.
* [`undead`](packages/undead/): Whole-program dead declaration and reachability analysis engine and CLI tool.
* [`analytica`](packages/analytica/): Shared CLI utilities, SDK discovery, AST analyzer extensions, and Git diff utilities.

---

## 🧠 AI Agent Skills

* [`dart-cognitive-complexity`](skills/dart-cognitive-complexity/): Agent skill for automated complexity triage, pattern-matching refactoring, and method extraction.
* [`dart-dedupe`](skills/dart-dedupe/): Agent skill for structural code duplication audits, clone triage, and safe deduplication refactoring.
* [`dart-undead`](skills/dart-undead/): Agent skill for deterministic dead code audits, reachability analysis, and safe deletion protocols.



