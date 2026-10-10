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
  dart run cognitive_complexity@^1.0.0 --threshold 15 lib/src/auth/
  dart run cognitive_complexity@^1.0.0 --threshold 15 --verbose lib/src/auth/
  ```
  `--verbose` / `-v` adds a `Breakdown` column (`branches`, `nesting`,
  `boolean_ops`, `max_depth`; also in JSON as `composition`) so a flat score-15
  function (Pattern D/E material) is distinguishable from a five-deep pyramid
  (Pattern A/B material). Top-level `main` of a `_test.dart` file is tagged
  `[test entrypoint]`.
- **Scope 2 — Delta (PR, Branch, or Pre-Flight Audit)**:
  ```bash
  dart run cognitive_complexity@^1.0.0 --git-diff origin/main --fail-threshold 15 --fail-on-increase
  ```
- **Scope 3 — Whole-Project (Default Naked Invocation)**: Invoking
  `cognitive_complexity` with zero positional paths automatically discovers
  package roots or workspace members and defaults to analyzing `lib/`:
  ```bash
  dart run cognitive_complexity@^1.0.0 --threshold 15
  dart run cognitive_complexity@^1.0.0 --threshold 40 test/
  ```
  > [!NOTE]
  >
  > **CLI Package Caveat (`lib/ bin/`)**: Zero-argument auto-discovery only
  > inspects `lib/`. For CLI tools and applications with entrypoints in `bin/`
  > (or `tool/`), pass target directories explicitly:
  > `dart run cognitive_complexity@^1.0.0 --threshold 15 lib/ bin/`
- **Optional Review Aid — Shallow Helper Audit (Advisory Only)**:
  ```bash
  dart run cognitive_complexity:shallow@^1.0.0 lib/
  dart run cognitive_complexity:shallow@^1.0.0 lib/ bin/
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
     `cognitive_complexity:shallow`, list its findings (`SAFE_INLINE`,
     `ZERO_HEADROOM`, `FLATTEN_AND_INLINE`, `LOAD_BEARING`) for review:

     | Classification    | Helper Declaration       | Sole Caller                         | Helper Metrics               | Caller CC (`Before -> After`) | Suggested Review                                                                                                           |
     | :---------------- | :----------------------- | :---------------------------------- | :--------------------------- | :---------------------------: | :------------------------------------------------------------------------------------------------------------------------- |
     | **`SAFE_INLINE`** | [`_helper`](file:///...) | [`caller`](file:///...) (`depth=0`) | `params=6`, `LOC=18`, `CC=2` |   `0 (base 0) -> 2` (`+2`)    | **Review: consider re-inlining if** the helper is pure plumbing, has no same-shape siblings, and its name adds no meaning. |
     - **Reading Shallow Classifications**:
       - **`SAFE_INLINE`** (`CallerCCAfter < 15`): Inlining is _possible_
         without breaching the caller's budget. It is not a recommendation;
         apply the Section 5.3 keep/revert heuristics first.
       - **`ZERO_HEADROOM`** (`CallerCCAfter == 15`): Inlining would leave the
         caller no budget; leave extracted.
       - **`HIGH_ARITY` / Parameter Record**: For sibling helpers sharing
         high-arity parameter clumps, a shared Dart 3 named record (or an
         existing domain/state object that already holds those values) usually
         beats inlining.
       - **`FLATTEN_AND_INLINE`**: Only relevant when the caller is itself a
         work item; flatten with Patterns A/B as part of that fix.
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
  values (Dart 3 named records with `<= 3` fields or value types).
- **Forbid Callback Trampolines & Closure-Wrapped Mutable Locals**: Never
  extract a helper that accepts a callback closure
  (`String Function(Object?) pp` or `bool Function() isAborted`) just to call
  back into a local recursive function or read a mutable local variable in the
  caller, and never slice a `try/catch` out of a retry loop with a `null`
  sentinel return. If a function relies on a nested recursive closure, promote
  the recursive closure itself (or a stateless private formatter/printer helper
  with `const` configuration fields) rather than passing recursion trampolines
  into extracted branch helpers.
- **Forbid `.catchError(...)` Metric Gaming in `async` Functions**: Never
  replace idiomatic `try { await ... } catch (e, s)` with `.catchError(...)`
  inside an `async` function solely to dodge `CatchClause` scoring, and never
  preserve or introduce zero-allocation fast-path regressions (e.g., allocating
  a new collection before an early-return fast path).

### 5.2 In-Place Flattening First (Patterns A & B Before `data_flow` Extraction)

**Always apply in-place flattening (Patterns A and B) before extracting any
single-caller helper**—especially for borderline violations (`CC 16–22`), where
eliminating `1–2` levels of nesting drops the score to `<= 15` with zero new
functions and zero parameter plumbing:

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
dart run cognitive_complexity:data_flow@^1.0.0 lib/src/my_file.dart:45-80
```

Inspect the complexity impact (`enclosing_score`, `slice_score_in_place`,
`slice_score_at_root`, `estimated_enclosing_score_after` in JSON;
`DataFlowResult.enclosingScore`, `sliceScoreInPlace`, `sliceScoreAtRoot`,
`estimatedEnclosingScoreAfter` in Dart) and honor any `extraction_warnings`
(high parameter count `>= 5` inputs, low complexity payoff, or shallow
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
  `dart run cognitive_complexity:file_split@^1.0.0 lib/src/large_file.dart --target-lines 300`
  for files `> 400` lines and select the library boundary tier. `--target-lines`
  is a physical-line budget for the surviving file; the planner cuts disjoint
  islands first, then sub-cone leaf groups out of the dominant island, names
  each cut after its dominant public declaration, and skips Tier-3 `part`
  fallback cuts that would leave `< 25%` of the pre-fallback file behind. The
  header reports `largest resulting file: N lines` (appending
  `(target M not met)` when `N > M`; `largest_resulting_file_lines` and
  `meets_target` in `--format json`, which always emits an array of one report
  per analyzed file). Oversized-declaration notes
  (`implements X (n/m members are @override)`, static-promotion hints,
  embedded-asset hints, and coupled-SCC vs. cohesive-island summaries) appear on
  both `Move Declarations` in extracted cuts and `Surviving Declarations` — when
  `>= 50%` of a class's members are `@override`, its size is bound by the
  interface surface, so narrow the interface or split behind a delegate rather
  than promoting statics.
  - **Tier 1 (Default — Standalone `lib/src/<topic>.dart`, CLI
    `[Cut N - Tier 1]`)**: Use when extracted helpers form a genuine sub-domain
    with narrow parameter lists (`<= 3` args) and do **not** need private `_`
    members or library-scoped modifiers of the parent class/library
    (`[Cut N - Tier 2]` in `file_split` indicates a one-way acyclic cut that
    requires widening `1–3` internal `_` helpers to `@internal` inside
    `lib/src/`).
  - **Tier 2 (`part` / `part of`, CLI `[Cut N - Tier 3]`)**: Use when splitting
    one cohesive domain where helpers share private `_` fields, private
    constructors (`._()`), `sealed`/`final`/`interface`/`base` modifiers, or
    internal invariants, OR when standalone `lib/src/` files would require
    widening visibility and risk leaking internal types via unscoped
    `export 'src/...';` directives.
  - `file_split` plans are advisory: the cuts are dependency-correct, but the
    suggested file name follows one declaration. Name each new file by what it
    actually holds (Section 5.3).
- **Pattern G (Advisory Shallow-Helper Review — `shallow`)**: Optionally run
  `dart run cognitive_complexity:shallow@^1.0.0 lib/` to list single-caller
  helpers (`HIGH_ARITY`, `MICRO_HELPER`, `SIG_HEAVY`,
  `CROSS_FILE_SINGLE_CALLER`). A `SAFE_INLINE` finding means inlining would not
  breach the caller's budget, not that it should happen; most well-named helpers
  should stay. Consider inlining only pure plumbing that passes every Section
  5.3 check. A `Facts:` line (`shared_param_signature_with`,
  `params_subset_of_existing_type` in JSON) points at a Parameter Record or
  Existing State Object remedy instead of inlining; `HIGH_ARITY` counts inline
  record parameters by field count, so packing arguments into an ad-hoc record
  is not an escape.

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
   `dart run cognitive_complexity@^1.0.0 --fail-threshold 15 <refactored files>`.
   Optionally run `dart run cognitive_complexity:shallow@^1.0.0 <files>` as a
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
