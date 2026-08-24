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

Modular composite GitHub Actions are maintained and documented in their respective package directories:

* [**Cognitive Complexity Audit**](packages/cognitive_complexity/README.md#github-actions) (`packages/cognitive_complexity`): Calculates Cognitive Complexity scores on pull requests and flags regressions.
* [**Dependency Lower-Bound Validator**](packages/lower_bound/README.md#github-action) (`packages/lower_bound`): Validates that declared dependency lower bounds resolve and build against synthetic minimums.

---

## 🧠 AI Agent Skills

Specialized agent skills are maintained in the [`skills/`](skills/) directory and documented alongside their companion packages:

* [**`dart-cognitive-complexity`**](skills/dart-cognitive-complexity/SKILL.md) (documented in [`cognitive_complexity`](packages/cognitive_complexity/README.md#-ai-agent-integration)): Complexity scoring, triage, and AST pattern matching refactoring.
* [**`dart-dedupe`**](skills/dart-dedupe/SKILL.md) (documented in [`dedupe`](packages/dedupe/README.md#-ai-agent-integration)): Structural code duplication audits, clone triage, and safe deduplication.
* [**`dart-undead`**](skills/dart-undead/SKILL.md) (documented in [`undead`](packages/undead/README.md#-ai-agent-integration)): Deterministic dead code reachability audits and safe declaration pruning.

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



