# Analytica

[![CI](https://github.com/kevmoo/analytica.dart/actions/workflows/ci.yml/badge.svg)](https://github.com/kevmoo/analytica.dart/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A unified suite of high-performance static analysis engines, CLI tools, GitHub Actions, and AI Agent Skills for Dart and Flutter repositories.

---

## 📦 Published Packages

<!-- mdformat off(prevent table wrapping) -->
| Package | Pub | Description |
| :--- | :---: | :--- |
| [`cognitive_complexity`](packages/cognitive_complexity/) | [![pub package](https://img.shields.io/pub/v/cognitive_complexity.svg)](https://pub.dev/packages/cognitive_complexity) | Algorithmic Cognitive Complexity calculation and AST data-flow analysis library and CLI. |
| [`dedupe`](packages/dedupe/) | [![pub package](https://img.shields.io/pub/v/dedupe.svg)](https://pub.dev/packages/dedupe) | High-performance token, structural, and parameterized code clone detection engine and CLI. |
| [`undead`](packages/undead/) | [![pub package](https://img.shields.io/pub/v/undead.svg)](https://pub.dev/packages/undead) | Whole-program reachability and dead declaration analysis for packages and closed apps. |
| [`analytica`](packages/analytica/) | [![pub package](https://img.shields.io/pub/v/analytica.svg)](https://pub.dev/packages/analytica) | Shared SDK discovery, AST analyzer extensions, Git diff utilities, and CI reporting. |
<!-- mdformat on -->

### 🚧 In Development

<!-- mdformat off(prevent table wrapping) -->
| Package | Version | Description |
| :--- | :---: | :--- |
| [`lower_bound`](packages/lower_bound/) | `0.1.0-wip` | Automated Dart dependency lower-bound validator and synthetic runtime isolation engine. |
<!-- mdformat on -->

---

## 🚀 GitHub Actions

Modular composite actions to automate code quality, complexity ceilings, and dependency validation in CI workflows:

### 1. Cognitive Complexity Audit

Calculates Cognitive Complexity scores on pull requests and prevents complexity regressions.

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

👉 [Cognitive Complexity Action Inputs Reference & Documentation](packages/cognitive_complexity/README.md#action-inputs-reference)

### 2. Dependency Lower-Bound Validator

Validates that declared dependency lower bounds resolve and build against synthetic minimums.

Add `.github/workflows/lower_bound.yml` to your repository:

```yaml
name: Dependency Lower-Bound Validation

on:
  pull_request:

jobs:
  validate:
    runs-on: ubuntu-latest
    permissions:
      pull-requests: write # Required for sticky PR comment summaries
      contents: read
    steps:
      - name: Checkout Codebase
        uses: actions/checkout@v7

      - name: Setup Dart SDK
        uses: dart-lang/setup-dart@v1

      - name: Validate Dependency Lower Bounds
        uses: kevmoo/analytica.dart/packages/lower_bound@main
        with:
          format: 'github'
          fail-on-error: 'true'
```

👉 [Lower-Bound Action Inputs Reference & Documentation](packages/lower_bound/README.md#action-inputs-reference)

---

## 🧠 AI Agent Skills

Specialized agent skills and protocols for AI coding assistants (Cursor, Claude Code, Gemini CLI, Jetski):

Install via `npx skills`:

```bash
# Cognitive Complexity triage, pattern-matching refactoring, and method extraction
npx skills add kevmoo/analytica.dart --skill dart-cognitive-complexity

# Structural code duplication audits, clone triage, and safe deduplication
npx skills add kevmoo/analytica.dart --skill dart-dedupe

# Deterministic dead code reachability audits and safe declaration pruning
npx skills add kevmoo/analytica.dart --skill dart-undead
```

Or run `npx skills add kevmoo/analytica.dart` for an interactive selection menu.

---

## ⚡ CLI Quick Run

Execute any tool on-demand without global installation via `dart run <package>@`:

```bash
# Evaluate cognitive complexity
dart run cognitive_complexity@ --threshold 15 lib/

# Audit structural code duplication
dart run dedupe@ --git-diff=origin/main

# Scan for unreachable / dead declarations
dart run undead@
```



