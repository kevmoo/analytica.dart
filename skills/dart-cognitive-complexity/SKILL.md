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
  dart run cognitive_complexity@^0.3.0 --threshold 15 lib/src/auth/
  ```
- **Scope 2 — Delta (PR, Branch, or Pre-Flight Audit)**:
  ```bash
  dart run cognitive_complexity@^0.3.0 --git-diff origin/main --fail-threshold 15 --fail-on-increase
  ```
- **Scope 3 — Whole-Project (Default Naked Invocation)**: Invoking
  `cognitive_complexity` with zero positional paths automatically discovers
  package roots or workspace members and defaults to analyzing `lib/`:
  ```bash
  dart run cognitive_complexity@^0.3.0 --threshold 15
  dart run cognitive_complexity@^0.3.0 --threshold 40 test/
  ```
  > [!NOTE]
  >
  > **CLI Package Caveat (`lib/ bin/`)**: Zero-argument auto-discovery only
  > inspects `lib/`. For CLI tools and applications with entrypoints in `bin/`
  > (or `tool/`), pass target directories explicitly:
  > `dart run cognitive_complexity@^0.3.0 --threshold 15 lib/ bin/`
- **Scope 4 — Shallow Helper Audit (Over-Extraction & Re-Inlining)**:
  ```bash
  dart run cognitive_complexity:shallow@^0.3.0 lib/
  dart run cognitive_complexity:shallow@^0.3.0 lib/ bin/
  dart run cognitive_complexity:shallow@^0.3.0 --git-diff origin/main --fail-on-safe-inline
  ```

---

## 3. The Triage & Confirmation Protocol (Audit Before Action)

When threshold breaches are detected, **do not mutate code immediately** unless
given an explicit upfront remediation directive or running in an unattended
automated harness (`evalin` / subagent).

### Stage 1: Read-Only Audit & Reporting (Mandatory Stop)

1. **Mandatory Persistent Artifact**: Create `complexity_triage_report.md` in
   `<appDataDir>/brain/<conversation-id>/` containing two structured audit
   tables:
   - **Core Cognitive Complexity Outliers (`> 15` Prod / `> 40` Test)**: Listing
     each flagged function, clickable file path with code snippets, current
     score vs. ceiling (sorted descending by score), recommended pattern (A–F),
     and unit test status.
   - **Shallow Helpers (Pattern G — Over-Extracted Single-Caller Helpers)**:
     Listing findings from `cognitive_complexity:shallow` (`SAFE_INLINE`,
     `FLATTEN_AND_INLINE`, `LOAD_BEARING`):

     | Classification    | Helper Declaration       | Sole Caller                         | Helper Metrics               | Caller CC (`Before -> After`) | Est. Saved | Recommended Remediation                                                                                             |
     | :---------------- | :----------------------- | :---------------------------------- | :--------------------------- | :---------------------------: | :--------: | :------------------------------------------------------------------------------------------------------------------ |
     | **`SAFE_INLINE`** | [`_helper`](file:///...) | [`caller`](file:///...) (`depth=0`) | `params=6`, `LOC=18`, `CC=2` |   `0 (base 0) -> 2` (`+2`)    |   `~12L`   | **Re-inline (Pattern G)**: Inlining eliminates pass-through plumbing while keeping caller in Target Zone (`<= 15`). |
     - **Guidance on Choosing the Right Shallow Remediation**:
       - **Re-inline (`SAFE_INLINE`)**: Re-inline single-caller helpers directly
         into their sole caller when `CallerCCAfter <= 15` (especially
         `MICRO_HELPER`s or `HIGH_ARITY` helpers where inlining deletes
         parameter plumbing and restores localized reading flow).
       - **Parameter Record**: For sibling helpers sharing high-arity parameter
         clumps (`HIGH_ARITY`), synthesize a shared Dart 3 named record rather
         than passing 5+ separate arguments or packing ad-hoc inline records.
       - **Existing State Object**: If helper parameters are a subset of an
         existing domain model or state object, pass that instance directly.
       - **Flatten & Inline (`FLATTEN_AND_INLINE`)**: Flatten nested
         conditionals in the helper using Patterns A/B before or while inlining.
2. **Visible Chat Pre-Render**: Render a high-level summary (including shallow
   helper counts and top complexity outliers) and a clickable link to
   `complexity_triage_report.md` in visible chat BEFORE invoking the
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
2. **Re-inline Safe Shallow Helpers**: Batch re-inline `SAFE_INLINE` helpers
   into their sole callers (`Pattern G`), deleting pass-through signatures while
   keeping all callers `<= 15`.
3. **Selective Batch Refactor**: Remediate the top N highest-scoring functions
   in descending order.
4. **Report-Only / Exit**: Acknowledge scores without code mutation.

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
dart run cognitive_complexity:data_flow@^0.3.0 lib/src/my_file.dart:45-80
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
  `dart run cognitive_complexity:file_split@^0.3.0 lib/src/large_file.dart --target-lines 300`
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
  `dart run cognitive_complexity:shallow@^0.3.0 lib/` to detect single-caller
  pass-through helpers (`HIGH_ARITY`, `MICRO_HELPER`, `SIG_HEAVY`,
  `CROSS_FILE_SINGLE_CALLER`). Re-inline `SAFE_INLINE` findings
  (`CallerCCAfter <= 15`) directly into their sole caller, and flatten + inline
  `FLATTEN_AND_INLINE` findings using Patterns A/B.

---

## 6. Verification & Public API Surface Guardrails

1. **Complexity & Shallow-Helper Audit**: Run
   `dart run cognitive_complexity@^0.3.0 --fail-threshold 15 <refactored files>`
   and
   `dart run cognitive_complexity:shallow@^0.3.0 --fail-on-safe-inline <refactored files>`.
2. **Mandatory `api_summary` Public API Surface Verification Gate**: Whenever a
   refactor extracts helpers across files or touches `lib/` exports:
   ```bash
   dart run api_summary@^1.1.0 > /tmp/api_after.txt
   diff -u /tmp/api_before.txt /tmp/api_after.txt
   ```
   Require zero unintended public symbol leaks (and if `api.txt` is tracked in
   the repo, verify `git diff api.txt` is empty).
3. **Format, Analyze & Test**: Run `dart format .`,
   `dart analyze --fatal-infos`, and `dart test` (or `flutter test`). Plain
   `dart analyze` exits 0 on `info` diagnostics, but many ecosystem CI pipelines
   run with `--fatal-infos`; extraction commonly leaves `unnecessary_ignore` /
   `duplicate_ignore` (an `// ignore:` copied onto both the caller and the
   extracted helper), `unused_import`, or `directives_ordering` behind, so
   resolve every info before committing.
4. **PR & Commit Provenance**: In interactive sessions, ask the user before
   appending the standardized Tool Provenance & Complexity Delta block from
   [`references/refactoring_recipes.md`](references/refactoring_recipes.md#3-pull-request--commit-provenance-template).
