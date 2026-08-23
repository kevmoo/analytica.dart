# Analytica

[![CI](https://github.com/kevmoo/analytica.dart/actions/workflows/ci.yml/badge.svg)](https://github.com/kevmoo/analytica.dart/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

A unified suite of high-performance static analysis engines, CLI tools, GitHub Actions, and AI Agent Skills for Dart and Flutter repositories.

---

## 📦 Published Packages

<!-- mdformat off(prevent table wrapping) -->
| Package | Pub | Description |
| :--- | :---: | :--- |
| [`cognitive_complexity`](packages/cognitive_complexity/) | [![pub package](https://img.shields.io/pub/v/cognitive_complexity.svg)](https://pub.dev/packages/cognitive_complexity) | Algorithmic Cognitive Complexity calculation and AST data-flow analysis library and CLI. |
| [`dedupe`](packages/dedupe/) | [![pub package](https://img.shields.io/pub/v/dedupe.svg)](https://pub.dev/packages/dedupe) | High-performance token, structural, and parameterized code clone detection engine and CLI. |
| [`undead`](packages/undead/) | [![pub package](https://img.shields.io/pub/v/undead.svg)](https://pub.dev/packages/undead) | Whole-program reachability and dead declaration analysis for packages and closed apps. |
| [`lower_bound`](packages/lower_bound/) | [![pub package](https://img.shields.io/pub/v/lower_bound.svg)](https://pub.dev/packages/lower_bound) | Automated Dart dependency lower-bound validator and synthetic runtime isolation engine. |
| [`analytica`](packages/analytica/) | [![pub package](https://img.shields.io/pub/v/analytica.svg)](https://pub.dev/packages/analytica) | Shared SDK discovery, AST analyzer extensions, Git diff utilities, and CI reporting. |
<!-- mdformat on -->

---

## 🚀 GitHub Actions

Modular composite actions to automate code quality, complexity ceilings, and dependency checks in your CI workflows:

### 1. Cognitive Complexity Audit

Calculates Cognitive Complexity scores on pull requests and prevents complexity regressions:

```yaml
- name: Run Complexity Scanner
  uses: kevmoo/analytica.dart/packages/cognitive_complexity@main
  with:
    diff-base: origin/${{ github.base_ref }}
    fail-threshold: 15
    fail-on-increase: true
```

👉 [Cognitive Complexity Action Documentation & Inputs Reference](packages/cognitive_complexity/action.yml)

### 2. Dependency Lower-Bound Validator

Validates that declared dependency lower bounds resolve and build against synthetic minimums:

```yaml
- name: Validate Dependency Lower Bounds
  uses: kevmoo/analytica.dart/packages/lower_bound@main
  with:
    fail-on-error: true
```

👉 [Lower-Bound Action Documentation & Inputs Reference](packages/lower_bound/action.yml)

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

# Validate dependency lower bounds
dart run lower_bound@
```



