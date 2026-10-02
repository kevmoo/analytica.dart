---
name: dart-cognitive-complexity
description: >-
  Evaluates and reduces Cognitive Complexity in Dart and Flutter code using
  deterministic CLI tooling, Ousterhout Deep Module boundaries, and
  architectural refactoring patterns (exhaustive pattern matching, guard
  clauses, pure functional decomposition). Use when reviewing codebase
  readability, remediating high-complexity warnings, or analyzing structural
  code health. Don't use for general code formatting, simple syntactic lints, or
  non-Dart/Flutter repositories.
license: Apache-2.0
key_features:
  - Automated CLI evaluation
  - Scoped execution matrix (targeted / delta / full)
  - Interactive refactoring triage
  - Deep Modules & pure internal decomposition
  - Public API surface verification (api_summary)
---

## 1. When to Use This Skill & Threshold Calibration

Use this skill when analyzing Dart and Flutter maintainability, evaluating
function readability, or remediating high-complexity findings during code
review. Cognitive Complexity measures human mental friction rather than flat
branch counts.

- **Production Logic Functions**: Target score `<= 15` (**Target Zone: `8–15`,
  Not `0`**). Functions exceeding 15 points mandate architectural refactoring.
  Once a function reaches `<= 15`, **stop decomposing**—never shred a `12`-point
  function into single-caller pass-through micro-helpers just to chase `0`.
- **Extracted Helper Depth & Parameter Cap**: Pure extracted helpers must take
  `<= 4` parameters (`<= 3` preferred) and carry genuine internal depth
  (`sliceScoreAtRoot >= 3` or reused across `2+` call sites).
- **Test Methods (`_test.dart`)**: Target score `<= 40`.
- **Class & File Size Ceilings**: Logic classes should remain `<= 150`
  non-comment lines; source files should remain `<= 400` lines.
- **Flutter UI Calibration**: Do not enforce the 150 LOC ceiling on declarative
  Flutter `build` methods; instead, enforce a **Widget Tree Nesting Ceiling** of
  at most 5 horizontal indentation levels before extracting helper widgets.

---

## 2. Automated Execution & Scope Resolution

Run the CLI directly (requires Dart SDK **3.12.0+**, verify via
`dart --version`):

- **Scope 1 — Targeted (Specific File or Directory)**:
  ```bash
  dart run cognitive_complexity@^0.2.5 --threshold 15 lib/src/auth/
  ```
- **Scope 2 — Delta (PR, Branch, or Pre-Flight Audit)**:
  ```bash
  dart run cognitive_complexity@^0.2.5 --git-diff origin/main --fail-threshold 15 --fail-on-increase
  ```
- **Scope 3 — Whole-Project (Default Naked Invocation)**:
  ```bash
  dart run cognitive_complexity@^0.2.5 --threshold 15 lib/
  dart run cognitive_complexity@^0.2.5 --threshold 40 test/
  ```
- **Scope 4 — Shallow Helper Audit (Over-Extraction & Re-Inlining)**:
  ```bash
  dart run cognitive_complexity:shallow@^0.2.5 lib/
  dart run cognitive_complexity:shallow@^0.2.5 --git-diff origin/main --fail-on-safe-inline
  ```

---

## 3. The Triage & Confirmation Protocol (Audit Before Action)

When threshold breaches are detected, **do not mutate code immediately** unless
given an explicit upfront remediation directive or running in an unattended
automated harness (`evalin` / subagent).

### Stage 1: Read-Only Audit & Reporting (Mandatory Stop)

1. **Mandatory Persistent Artifact**: Create `complexity_triage_report.md` in
   `<appDataDir>/brain/<conversation-id>/` listing each flagged function,
   clickable file path with code snippets, current score vs. ceiling (sorted
   descending by score), recommended pattern (A–F), and unit test status.
2. **Visible Chat Pre-Render**: Render a high-level summary and a clickable link
   to `complexity_triage_report.md` in visible chat BEFORE invoking the
   confirmation gate.
3. **Outlier-First Mandate**: Prioritize the highest-scoring declaration in the
   report (`Score >= 25` or top outlier) targeting a post-refactoring score of
   `<= 15`.

### Stage 2: Interactive User Selection (Confirmation Gate)

Never call `ask_question` before `complexity_triage_report.md` is written and
linked in chat. Reference `[complexity_triage_report.md](...)` in the prompt and
offer:

1. **(Recommended) Refactor Primary Outlier First**: Target the single
   highest-scoring declaration, decompose to `<= 15`, verify tests, and show
   diffs.
2. **Selective Batch Refactor**: Remediate the top N highest-scoring functions
   in descending order.
3. **Report-Only / Exit**: Acknowledge scores without code mutation.

---

## 4. Pre-Refactoring Assessment, Coverage & Public API Baseline

1. **Test Baseline**: Confirm a unit test exists (`lib/src/foo.dart` ->
   `test/foo_test.dart`), check coverage via `dart-collect-coverage` if
   available, and run `dart test` (or `flutter test`) to verify a green baseline
   before editing. If coverage is missing, warn the user (or add a minimal
   regression test in unattended runs).
2. **Public API Surface Baseline (`api_summary`)**: Whenever a complexity or
   file-split refactor extracts helpers across files or touches `lib/` exports
   in a Dart package, ensure `.dart_tool/package_config.json` exists and capture
   a non-empty pre-refactor public surface (without `package_config.json`,
   `api_summary` exits `0` with `0` `package:` symbols):
   ```bash
   test -f .dart_tool/package_config.json || dart pub get
   dart run api_summary@^1.1.0 > /tmp/api_before.txt && rg -q '^package:' /tmp/api_before.txt
   ```

---

## 5. Deep Modules & Refactoring Patterns

See [`references/refactoring_recipes.md`](references/refactoring_recipes.md) for
complete before/after code examples across Patterns A–F and the PR provenance
template.

### 5.1 Deep Externally, Pure Internally (No Stateful `_Populator` / `_Runner` Classes)

- **Forbid Single-Use Stateful Helper Classes**: Never decompose complex
  functions by creating single-use stateful private helper classes
  (`_FooPopulator`, `_BarBuilder`, `_BazRunner`) that hold mutable fields across
  methods or mutate caller collections in-place.
- **Require Pure Top-Level / Static Helpers**: Extract **pure file-private
  top-level functions** (`_validateItem(...)`, `_parseHeader(...)`) or `static`
  methods on existing domain types with explicit inputs and immutable return
  values (Dart 3 named records or value types).

### 5.2 Deterministic 3-Tier Decomposition (`data_flow`) & Pattern Summary

Run the statement-level data-flow analyzer on candidate line slices:

```bash
dart run cognitive_complexity:data_flow@^0.2.5 lib/src/my_file.dart:45-80
```

Inspect the complexity impact (`enclosingScore`, `sliceScoreInPlace`,
`sliceScoreAtRoot`, `estimatedEnclosingScoreAfter`) and honor any
`extractionWarnings` (`HIGH_ARITY` `>= 5` inputs or `LOW_COMPLEXITY_PAYOFF`) by
flattening in place with Patterns A/B instead of extracting a shallow helper:

- **Pattern A (Dart 3 Switch Expressions)**: Replace nested `if-else` ladders
  with exhaustive table-driven `switch` expressions (single base penalty).
- **Pattern B (Guard Clause Inversion)**: Invert nested preconditions into early
  returns (`if (!cond) return;`).
- **Pattern C (3-Tier `data_flow` Extraction)**:
  1. **Tier 1 — Pure Functional Decomposition (First Choice)**: For slices with
     `2+` live outputs, `<= 4` inputs, and `sliceScoreAtRoot >= 3`, extract a
     pure private top-level or `static` function returning the synthesized Dart
     3 named record (`final (:data, :errors) = _step(input);`). Never create
     single-use `_XxxResult` dataclasses for private slices.
  2. **Tier 2 — Standard Helper Extraction (Second Choice)**: For slices with
     `<= 1` output, `<= 3` inputs, and `sliceScoreAtRoot >= 3`, extract a pure
     private top-level or static helper.
  3. **Tier 3 — Encapsulated Method Object (Last Resort)**: Permitted ONLY when
     `data_flow` on 2+ candidate slices shows `>= 3` intersecting `mutations`
     variables—read [`references/method-object.md`](references/method-object.md)
     before applying. If coupled state represents a cohesive domain concept with
     multiple public behaviors and dedicated tests, promote it to a real public
     domain class instead.
- **Pattern D (Fast-Fail Type Matching)**: Never silently drop malformed items
  with `if (raw case final Map<String, dynamic> m)`; use
  `if (raw is! Map) { ...; continue; }`.
- **Pattern E (Loop-Body Signal Returns)**: Return an explicit `_Action` enum or
  `sealed class` from extracted loop bodies rather than `shouldBreak` boolean
  flags.
- **Pattern F (Acyclic File Decomposition & Load-Bearing Library Boundaries)**:
  Run
  `dart run cognitive_complexity:file_split@^0.2.5 lib/src/large_file.dart --target-lines 300`
  for files `> 400` lines and select the library boundary tier:
  - **Tier 1 (Default — Standalone `lib/src/<topic>.dart`)**: Use when extracted
    helpers form a genuine sub-domain with narrow parameter lists (`<= 3` args)
    and do **not** need private `_` members or library-scoped modifiers of the
    parent class/library.
  - **Tier 2 (`part` / `part of`)**: Use when splitting one cohesive domain
    where helpers share private `_` fields, private constructors (`._()`),
    `sealed`/`final`/`interface`/`base` modifiers, or internal invariants, OR
    when standalone `lib/src/` files would require widening visibility and risk
    leaking internal types via unscoped `export 'src/...';` directives.
- **Pattern G (Re-Inlining Shallow Single-Caller Helpers — `shallow`)**: Run
  `dart run cognitive_complexity:shallow@^0.2.5 lib/` to detect single-caller
  pass-through helpers (`HIGH_ARITY`, `MICRO_HELPER`, `SIG_HEAVY`,
  `CROSS_FILE_SINGLE_CALLER`). Re-inline `SAFE_INLINE` findings
  (`CallerCCAfter <= 15`) directly into their sole caller, and flatten + inline
  `FLATTEN_AND_INLINE` findings using Patterns A/B.

---

## 6. Verification & Public API Surface Guardrails

1. **Complexity & Shallow-Helper Audit**: Run
   `dart run cognitive_complexity@^0.2.5 --fail-threshold 15 <refactored files>`
   and
   `dart run cognitive_complexity:shallow@^0.2.5 --fail-on-safe-inline <refactored files>`.
2. **Mandatory `api_summary` Public API Surface Verification Gate**: Whenever a
   refactor extracts helpers across files or touches `lib/` exports:
   ```bash
   dart run api_summary@^1.1.0 > /tmp/api_after.txt
   diff -u /tmp/api_before.txt /tmp/api_after.txt
   ```
   Require zero unintended public symbol leaks (and if `api.txt` is tracked in
   the repo, verify `git diff api.txt` is empty).
3. **Format, Analyze & Test**: Run `dart format .`, `dart analyze`, and
   `dart test` (or `flutter test`).
4. **PR & Commit Provenance**: In interactive sessions, ask the user before
   appending the standardized Tool Provenance & Complexity Delta block from
   [`references/refactoring_recipes.md`](references/refactoring_recipes.md#3-pull-request--commit-provenance-template).
