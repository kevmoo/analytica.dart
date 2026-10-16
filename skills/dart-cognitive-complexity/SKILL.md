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
- **Stop Rule**: Only declarations scoring **above** the threshold are work
  items. When the max score is `<= threshold`, report "done, nothing required"
  and stop. Further refactors (re-inlining, file splits, style edits) are
  optional and need an explicit user ask.
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
  dart run cognitive_complexity@^2.0.1 --threshold 15 lib/src/auth/
  dart run cognitive_complexity@^2.0.1 --threshold 15 --verbose lib/src/auth/
  ```
  `--verbose` / `-v` adds a `Breakdown` column (`branches`, `nesting`,
  `boolean_ops`, `max_depth`; also in JSON as `composition`) so a flat score-15
  function (Pattern D/E material) is distinguishable from a five-deep pyramid
  (Pattern A/B material). Top-level `main` of a `_test.dart` file is tagged
  `[test entrypoint]`.
- **Scope 2 — Delta (PR, Branch, or Pre-Flight Audit)**:
  ```bash
  dart run cognitive_complexity@^2.0.1 --git-diff origin/main --fail-threshold 15 --fail-on-increase
  ```
- **Scope 3 — Whole-Project (Default Naked Invocation)**: Invoking
  `cognitive_complexity` with zero positional paths automatically discovers
  package roots or workspace members and defaults to analyzing `lib/`:
  ```bash
  dart run cognitive_complexity@^2.0.1 --threshold 15
  dart run cognitive_complexity@^2.0.1 --threshold 40 test/
  ```
  > [!NOTE]
  >
  > **CLI Package Caveat (`lib/ bin/`)**: Zero-argument auto-discovery only
  > inspects `lib/`. For CLI tools and applications with entrypoints in `bin/`
  > (or `tool/`), pass target directories explicitly:
  > `dart run cognitive_complexity@^2.0.1 --threshold 15 lib/ bin/`
- **Optional Review Aid — Shallow Helper Audit (Advisory Only)**:
  ```bash
  dart run cognitive_complexity:shallow@^2.0.1 lib/
  dart run cognitive_complexity:shallow@^2.0.1 lib/ bin/
  ```
  Without positional targets, `shallow` scans `lib/` in the current directory
  (pass `lib/ bin/` or package paths explicitly for CLI tools and monorepos).
  Its findings (like `file_split` plans) are prompts for judgment, never a queue
  to clear or a CI gate; see Section 5.3 before acting on any of them. This
  framing applies to consumer repos: a package may keep its own dogfood
  `--fail-on-safe-inline` CI step (this repo does), and never remove an existing
  CI gate without an explicit ask.

---

## 3. The Triage & Confirmation Protocol (Audit Before Action)

When threshold breaches are detected, **do not mutate code immediately** unless
given an explicit upfront remediation directive or running in an unattended
automated harness (`evalin` / subagent). When there are **no** breaches (max
score `<= threshold`), apply the Stop Rule: report that nothing is required,
make no source edits, and skip Stage 2.

### Stage 1: Read-Only Audit & Reporting (Mandatory Stop)

1. **Mandatory Persistent Artifact**: Create `complexity_triage_report.md` in
   `<appDataDir>/brain/<conversation-id>/` containing:
   - **Core Cognitive Complexity Outliers (`> 15` Prod / `> 40` Test)** — the
     only work items: each flagged function, clickable file path with code
     snippets, current score vs. ceiling (sorted descending by score),
     recommended pattern (A–F), and unit test status.
   - **Optional: Shallow Helper Notes (Advisory, Not Work Items)**: If you ran
     `cognitive_complexity:shallow`, list its findings (`SAFE_INLINE` where
     `CallerCCAfter < 15`, `ZERO_HEADROOM` where `CallerCCAfter == 15`,
     `HIGH_ARITY` / Parameter Record or existing state object,
     `FLATTEN_AND_INLINE` when the caller is itself a work item, and
     `LOAD_BEARING`) as advisory review notes, applying Section 5.3 keep/revert
     heuristics first (see
     [`references/file_split_and_shallow.md`](references/file_split_and_shallow.md#2-stage-1--pattern-g-shallow-helper-audit-shallow-advisory-only)
     for the report table template and classification rules).
2. **Visible Chat Pre-Render**: Render a high-level summary (top complexity
   outliers, plus any advisory shallow notes) and a clickable link to
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
before/after code examples across Patterns A–E and
[`references/file_split_and_shallow.md`](references/file_split_and_shallow.md)
for `file_split` (Pattern F), `shallow` (Pattern G), and the PR provenance
template.

### 5.1 Deep Externally, Pure Internally (No Stateful `_Populator` / `_Runner` Classes)

- **Forbid Single-Use Stateful Helper Classes**: Never decompose complex
  functions by creating single-use stateful private helper classes
  (`_FooPopulator`, `_BarBuilder`, `_BazRunner`) that hold mutable fields across
  methods or mutate caller collections in-place.
- **Require Pure Top-Level / Static Helpers**: Extract **pure file-private
  top-level functions** (`_validateItem(...)`, `_parseHeader(...)`) or `static`
  methods on existing domain types with explicit inputs and immutable return
  values (Dart 3 named records with `<= 3` fields or value types).
- **Forbid Callback Trampolines & Closure-Wrapped Mutable Locals**: Never pass
  callback closures (`String Function(Object?) pp`, `bool Function() isAborted`)
  into extracted helpers to call back into local recursive closures or read
  mutable caller locals, and never slice `try/catch` out of a retry loop with a
  `null` sentinel. Promote the recursive closure itself (or a `const` stateless
  formatter/printer helper) instead.
- **Forbid `.catchError(...)`, Multi-Pass Loop Splitting & `.expand` Gaming**:
  Never replace `try { await ... } catch (e, s)` with `.catchError(...)` in
  `async` functions to dodge `CatchClause` scoring, never introduce fast-path
  allocation regressions, and never split a single loop into multiple sequential
  loops or `.expand((c) => c)` / `.forEach(...)` chains to shed loop nesting.

### 5.2 In-Place Flattening First (Patterns A & B Before `data_flow` Extraction)

**Always apply in-place flattening (Patterns A and B) before extracting any
single-caller helper**—especially for borderline violations (`CC 16–22`), where
eliminating `1–2` levels of nesting drops the score to `<= 15` with zero new
functions and zero parameter plumbing. If a `CC 16–22` function owes its
remaining complexity to a nested loop that cannot be flattened in a **single
pass** using `continue`/`return` guards or `switch` expressions, extract a
cohesive `LOAD_BEARING` helper for the inner loop or validation pass rather than
splitting the loop into two passes:

- **Pattern A (Dart 3 Switch Expressions)**: Replace nested `if-else` ladders
  with exhaustive table-driven `switch` expressions (single base penalty).
- **Pattern B (Guard Clause Inversion & `else` Removal)**: Invert nested
  preconditions into early returns (`if (!cond) return;`), drop `else` after
  `return`/`break`/`continue`/`throw`, merge nested `if` conditions, and
  eliminate redundant post-`try` null checks only when doing so does not widen
  the `try` block around user-supplied callbacks whose exceptions must not be
  caught.

Only when a declaration **still** exceeds `15` after exhausting Patterns A and
B, run the statement-level data-flow analyzer on candidate line slices:

```bash
dart run cognitive_complexity:data_flow@^2.0.1 lib/src/my_file.dart:45-80
```

Inspect the complexity impact (`enclosing_score`, `slice_score_in_place`,
`slice_score_at_root`, `estimated_enclosing_score_after`; see
[`references/file_split_and_shallow.md`](references/file_split_and_shallow.md#1-anti-metric-gaming-guardrails--data_flow-schema-details))
and honor any `extraction_warnings` (`>= 5` inputs, low payoff, or shallow
signature-to-complexity ratio):

- **Pattern C (3-Tier `data_flow` Extraction)**:
  1. **Tier 1 — Pure Functional Decomposition (First Choice)**: For slices with
     `2+` live outputs (`<= 3` record fields), `<= 4` inputs, and
     `slice_score_at_root >= 3`, extract a pure private top-level or `static`
     function returning the synthesized Dart 3 named record
     (`final (:data, :errors) = _step(input);`). Never create single-use
     `_XxxResult` dataclasses or `> 3`-field anonymous return records for
     private slices.
  2. **Tier 2 — Standard Helper Extraction (Second Choice)**: For slices with
     `<= 1` output, `<= 3` inputs, and `slice_score_at_root >= 3`, extract a
     pure private top-level or static helper (never a `void` helper that mutates
     a caller's `Map`/`List` in place for only one of several parallel steps).
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
  `dart run cognitive_complexity:file_split@^2.0.1 lib/src/large_file.dart --target-lines 300`
  for files `> 400` lines and select the library boundary tier (see
  [`references/file_split_and_shallow.md`](references/file_split_and_shallow.md#3-pattern-f-acyclic-file-decomposition-library-boundaries--api_summary)
  for full planner mechanics, JSON schema, and `@override >= 50%` interface
  notes):
  - **Tier 1 (Default — Standalone `lib/src/<topic>.dart`, CLI
    `[Cut N - Tier 1]` / `[Cut N - Tier 2]`)**: Use when extracted helpers form
    a sub-domain (`<= 3` args) without private `_` parent members or class
    modifiers (`[Cut N - Tier 2]` widens `1–3` helpers to `@internal` in
    `lib/src/`).
  - **Tier 2 (`part` / `part of`, CLI `[Cut N - Tier 3]`)**: Use when helpers
    share private `_` fields, `._()` constructors, `sealed`/`final`/`interface`/
    `base` modifiers, or when standalone files risk leaking internal types via
    unscoped `export 'src/...';`.
  - **Model/Enum Back-Edges & Factory Parity**: Move enum/model dispatch methods
    to an `extension` in the surviving file so models extract cleanly into
    `<stem>_models.dart`. Verify with `rg` that every new factory
    (`Foo.fromBar(...)`) is called by the surviving file with no divergent
    inline constructors. Name new files by what they hold (Section 5.3).
- **Pattern G (Advisory Shallow-Helper Review — `shallow`)**: Optionally run
  `dart run cognitive_complexity:shallow@^2.0.1 lib/` to inspect single-caller
  helpers (`HIGH_ARITY`, `MICRO_HELPER`, `SIG_HEAVY`,
  `CROSS_FILE_SINGLE_CALLER`). Consider inlining `SAFE_INLINE` findings only for
  pure plumbing that passes every Section 5.3 check; use Parameter Records or
  existing state objects for `Facts:` (`shared_param_signature_with`,
  `params_subset_of_existing_type`; inline record params count by field count).

### 5.3 Keep / Revert Heuristics

**KEEP** (these reliably improve code):

- De-duplication of repeated logic.
- Guard clauses and flattening (Patterns A/B).
- Named step helpers that turn a long function into a readable sequence.

**DON'T**:

- Inline a helper whose same-shape siblings stay extracted (e.g. inlining
  `_readEnviron` while `_readCmdline` / `_readCwd` remain helpers).
- Inline a helper whose name or doc comment carries meaning the call site would
  lose. Watch for inlined bodies whose early `return` now skips later caller
  logic.
- Make style-only edits to code you are not otherwise fixing.
- Split files without a cohesive name. Name a file by what it holds, put shared
  types in a `models`-style file, and never create import cycles or barrel files
  (`export ... show` re-export lists) when direct imports work.

### 5.4 Hot Loops: Benchmark Before Splitting

For per-element inner loops (pixel, module, byte, or token kernels), splitting
into helpers can cost real throughput even on AOT. Benchmark before and after
any split. Prefer leaving the kernel inline with a declaration-level suppression
on the line immediately preceding the declaration, plus a reason:

```dart
// Hot per-module kernel: splitting into helpers benchmarked slower on AOT.
// cognitive_complexity:ignore
int _scoreModules(List<int> modules, int size) {
  // ...
}
```

---

## 6. Verification & Public API Surface Guardrails

1. **Complexity Check**: Run
   `dart run cognitive_complexity@^2.0.1 --fail-threshold 15 <refactored files>`.
   Optionally run `dart run cognitive_complexity:shallow@^2.0.1 <files>` as a
   review aid (Section 5.3); its findings never block.
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
4. **Blind Self-Review (Diffs `> ~300` Changed Lines)**: Before finishing, have
   a fresh agent or human reviewer, given only the before/after trees and the
   diff (no tool output or scores), judge whether each change is an improvement.
   Revert hunks judged neutral or worse.
5. **PR & Commit Provenance**: In interactive sessions, ask the user before
   appending the standardized Tool Provenance & Complexity Delta block from
   [`references/refactoring_recipes.md`](references/refactoring_recipes.md#3-pull-request--commit-provenance-template).
