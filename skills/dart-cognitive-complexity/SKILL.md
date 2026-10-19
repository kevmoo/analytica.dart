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

Use this skill when analyzing Dart and Flutter maintainability or remediating
high-complexity findings (Cognitive Complexity measures human mental friction):

- **Production Logic Functions**: Target score `<= 15` (**Target Zone: `8–15`,
  Not `0`**; see Section 5.4 exception for hot inner kernels). Once a function
  reaches `<= 15`, **stop decomposing**—never shred a `12`-point function into
  single-caller micro-helpers just to chase `0`.
- **Stop Rule**: Only declarations scoring **above** the threshold are work
  items. When max score `<= threshold`, report "done, nothing required" and
  stop; re-inlining, file splits, and style edits need an explicit user ask.
- **Extracted Helper Depth & Parameter Cap**: Pure extracted helpers must take
  `<= 4` parameters (`<= 3` preferred) and carry genuine internal depth
  (`sliceScoreAtRoot >= 3` or reused across `2+` call sites).
- **Test, Class, File & Flutter UI Ceilings**: Test methods (`_test.dart`)
  `<= 40`; logic classes `<= 150` non-comment lines; source files `<= 400`
  lines; Flutter `build` methods enforce a **Widget Tree Nesting Ceiling** of at
  most 5 horizontal indentation levels.

---

## 2. Automated Execution & Scope Resolution

Run the CLI directly (requires Dart SDK **3.12.0+**, verify via
`dart --version`):

- **Scope 1 — Targeted (`--verbose` / `-v` adds `Breakdown`: `branches`,
  `nesting`, `boolean_ops`, `max_depth`, and tags `_test.dart` `main` as
  `[test entrypoint]`) & Scope 2 — Delta**:
  ```bash
  dart run cognitive_complexity@^2.0.1 --threshold 15 lib/src/auth/
  dart run cognitive_complexity@^2.0.1 --threshold 15 --verbose lib/src/auth/
  dart run cognitive_complexity@^2.0.1 --git-diff origin/main --fail-threshold 15 --fail-on-increase
  ```
- **Scope 3 — Whole-Project & Optional Advisory `shallow` Review**: Zero
  positional paths auto-discovers `lib/` (pass `lib/ bin/` explicitly for CLI
  packages). `shallow` findings (like `file_split` plans) are advisory prompts
  for judgment, never a queue to clear or a CI gate (preserve existing repo
  dogfood `--fail-on-safe-inline` CI steps unless asked):
  ```bash
  dart run cognitive_complexity@^2.0.1 --threshold 15
  dart run cognitive_complexity@^2.0.1 --threshold 40 test/
  dart run cognitive_complexity@^2.0.1 --threshold 15 lib/ bin/
  dart run cognitive_complexity:shallow@^2.0.1 lib/
  dart run cognitive_complexity:shallow@^2.0.1 lib/ bin/
  ```

---

## 3. The Triage & Confirmation Protocol (Audit Before Action)

When threshold breaches are detected, **do not mutate code immediately** unless
given an explicit upfront remediation directive or running in an unattended
automated harness (eval or subagent). When max score `<= threshold`, apply the
Stop Rule: report that nothing is required, make no edits, and skip Stage 2.

### Stage 1: Read-Only Audit & Reporting (Mandatory Stop)

1. **Mandatory Persistent Artifact**: Create `complexity_triage_report.md` in
   `<appDataDir>/brain/<conversation-id>/` containing:
   - **Core Cognitive Complexity Outliers (`> 15` Prod / `> 40` Test)** — the
     only work items: each flagged function, clickable file path with code
     snippets, current score vs. ceiling (sorted descending by score),
     recommended pattern (A–F or Section 5.4 hot-loop suppression), and unit
     test status.
   - **Optional: Shallow Helper Notes (Advisory, Not Work Items)**: If you ran
     `cognitive_complexity:shallow`, list findings (`SAFE_INLINE` where
     `CallerCCAfter < 15`, `ZERO_HEADROOM` where `CallerCCAfter == 15`,
     `HIGH_ARITY`, `FLATTEN_AND_INLINE`, `LOAD_BEARING`) as review notes—never
     as work items to batch-inline.
2. **Visible Chat Pre-Render & Outlier-First Mandate**: Render a high-level
   summary and a clickable link to `complexity_triage_report.md` in visible chat
   BEFORE invoking `ask_question`, prioritizing the highest-scoring declaration
   (`Score >= 25` or top outlier) first.

### Stage 2: Interactive User Selection (Confirmation Gate)

Reference `[complexity_triage_report.md](...)` in `ask_question` and offer: (1)
**(Recommended) Refactor Primary Outlier First** (target top outlier, decompose
to `<= 15`, verify tests, show diffs), (2) **Selective Batch Refactor** (top N
outliers descending), or (3) **Report-Only / Exit**.

---

## 4. Pre-Refactoring Assessment, Coverage & Public API Baseline

1. **Test Baseline**: Confirm a unit test exists (`lib/src/foo.dart` ->
   `test/foo_test.dart`), check `dart-collect-coverage` if available, and run
   `dart test` (or `flutter test`) for a green baseline.
2. **Public API Surface Baseline (`api_summary`)**: When extracting across files
   or touching `lib/` exports, capture a non-empty baseline:
   ```bash
   test -f .dart_tool/package_config.json || dart pub get
   dart run api_summary@^1.1.0 > /tmp/api_before.txt && rg -q '^package:' /tmp/api_before.txt
   ```

---

## 5. Deep Modules & Refactoring Patterns

Consult [`references/refactoring_recipes.md`](references/refactoring_recipes.md)
for full before/after examples across Patterns A–H and the PR provenance
template.

### 5.1 Deep Externally, Pure Internally (No Stateful `_Populator` / `_Runner` Classes)

- **Forbid Single-Use Stateful Helper Classes**: Never create single-use
  stateful private helper classes (`_FooPopulator`, `_BarBuilder`, `_BazRunner`)
  that hold mutable fields across methods or mutate caller collections in-place.
- **Require Pure Top-Level / Static Helpers**: Extract **pure file-private
  top-level functions** or `static` methods with explicit inputs (`<= 4` params)
  and immutable return values (Dart 3 named records with `<= 3` fields or value
  types).
- **Forbid Callback Trampolines, Retry `null` Sentinels, `.catchError(...)` &
  Multi-Pass Loop Gaming**: Never pass recursion trampolines
  (`String Function(Object?) pp`) or closure-wrapped mutable locals
  (`bool Function() isAborted`) into helpers, never pass a caller's mutable
  state flag (`bool isAborted`) by value into a helper that mutates it, and
  **never slice a `try/catch` out of a retry loop with a `null` sentinel
  return**; never replace `try/await` with `.catchError(...)` in `async`
  functions; never split one loop into multiple passes or chain
  `.expand((c) => c)` / `.forEach(...)` to shed depth.

### 5.2 In-Place Flattening & 5-Step Pre-Extraction Checklist (`CC 16–22`)

Apply **Pattern A** (Dart 3 exhaustive `switch` expressions) and **Pattern B**
(early-return guard clauses, `else` removal after `return`/`break`/`continue`/
`throw`, merged conditions) first.

**5-Step Pre-Extraction Simplification Checklist for Borderline Functions
(`CC 16–22`)**: When a function is just over the threshold (`CC 16–22`, needing
`-1` to `-7` points), you MUST exhaust all 5 in-place and cross-method
simplifications before extracting ANY single-caller helper:

1. **Cross-Method Deduplication (`FanIn >= 2`)**: Scan sibling methods in the
   same class/file for repeated logic (`3+` branches) and extract a shared
   helper called by `2+` methods.
2. **Multi-Branch Local Closure Promotion**: If a function passes an inline
   callback/closure (e.g. `onValue: (x) { ... }`) containing `3+` branches
   (`if`/`switch`/`&&`), every branch inside that closure pays an extra `+1`
   closure nesting penalty. Promote the closure to a named private method first.
3. **Identical-Return Coalescing, Exception/Loop Guard Flattening & Tautological
   Guard Removal**: Merge `if` branches or `switch` cases returning the same
   value (`if (a || b) return x;` / `case A || B:`); coalesce
   `on Ex { rethrow; } catch (e, s) { if (...) rethrow; }` into
   `catch (e, s) { if (e is Ex || ...) rethrow; }`; hoist pre-loop null-reader
   checks (`if (reader == null) return ...;`) and replace
   `while (true) { ... if (!hasListener) break; }` with `while (hasListener)`;
   remove redundant null/type checks and `.toList()` after `.cast<T>()`.
4. **Twin-Block Loop Folding & Loop-Invariant Hoisting**: Fold two consecutive
   blocks performing the same check on two values (e.g. `inputType` and
   `outputType`, or `serializeConfig` and `deserializeConfig`) into a 2-element
   collection loop (`for (final item in [?first, ?second])` or
   `for (final t in {typeA, typeB})`). Hoist per-item loops over class-wide or
   outer-scope metadata to the outer orchestrator.
5. **Zero-Nesting-Gain & Asymmetric Extraction Ban**: Never extract a
   single-caller helper at `callNestingDepth == 0` out of a borderline
   `CC 16–22` function when `sliceScoreInPlace == sliceScoreAtRoot` (`0` net
   file CC reduction), and never asymmetrically extract one arm of a peer
   `Map`/`Iterable` or `switch` dispatch while leaving its twin inline.

Only when a non-hot-loop declaration **still** exceeds `15` after exhausting
Patterns A/B and all 5 checklist steps (and is not a Section 5.4 hot inner
kernel), run `data_flow` on candidate slices (see
[`references/refactoring_recipes.md`](references/refactoring_recipes.md)):

```bash
dart run cognitive_complexity:data_flow@^2.0.1 lib/src/my_file.dart:45-80
dart run cognitive_complexity:file_split@^2.0.1 lib/src/large_file.dart --target-lines 300
dart run cognitive_complexity:shallow@^2.0.1 lib/
```

- **Pattern C (`data_flow` 3-Tier Extraction)**: Honor `extraction_warnings`
  (including `[ZERO_NESTING_GAIN]`). Tier 1: pure function returning a `<= 3`
  field Dart 3 named record (`slice_score_at_root >= 3`, `<= 4` inputs). Tier 2:
  single-output pure helper (`<= 3` inputs, `slice_score_at_root >= 3`). Tier 3:
  Method Object only when 2+ slices share `>= 3` mutated variables (read
  [`references/method-object.md`](references/method-object.md)).
- **Patterns D, E, F & G**: Fast-fail `if (raw is! Map)` checks (never silent
  `if (raw case ...)` drops); explicit `_Action` enum/`sealed class` returns for
  loop bodies; **Load-Bearing Library Boundary Rule** (**Tier 1** standalone
  `lib/src/<topic>.dart` `<= 3` args, zero `_` access vs. **Tier 2** `part` /
  `part of` for shared `_` fields, `._()`, `sealed`/`final`/`base`/`interface`,
  or avoiding `@internal` leaks; break enum/model dispatch back-edges via
  `extension`s and verify every new factory is called).

### 5.3 Keep / Revert Heuristics

- **KEEP**: De-duplication (`FanIn >= 2`), Patterns A/B flattening, and cohesive
  named step helpers.
- **DON'T**: Inline a helper whose same-shape siblings stay extracted (e.g.
  `_readEnviron` while `_readCmdline` / `_readCwd` remain helpers); inline a
  helper whose name, doc comment, or early `return` carries meaning; make
  style-only edits outside refactored outliers; or create import cycles/barrels.

### 5.4 Hot Loops: Never Split Per-Cell/Per-Element Kernels (`// cognitive_complexity:ignore`)

For tight nested inner loops—**2D matrix/grid `row`/`col` scans**, neighbor or
penalty scoring kernels (e.g. `_scoreModules`), pixel buffers, module grids, or
byte/token kernels—you **MUST NOT** extract per-element or per-cell helpers
inside the loop (per-cell function calls add call overhead and defeat AOT loop
optimizations). Instead, you **MUST** keep the hot kernel inline and suppress it
with `// cognitive_complexity:ignore <reason>` on the line immediately preceding
the declaration:

```dart
// cognitive_complexity:ignore Hot 2D matrix neighbor-scoring kernel; keep inline to avoid per-cell call overhead.
int _scoreModules(List<int> modules, int size) { ... }
```

---

## 6. Verification & Public API Surface Guardrails

1. **Complexity, API Surface, Format, Analyze & Test**:
   ```bash
   dart run cognitive_complexity@^2.0.1 --fail-threshold 15 <refactored files>
   dart run api_summary@^1.1.0 > /tmp/api_after.txt && diff -u /tmp/api_before.txt /tmp/api_after.txt
   ```
   Verify zero public symbol leaks (`git diff api.txt` empty), then run
   `dart format .`, `dart analyze --fatal-infos`, and `dart test`.
2. **Blind Self-Review & Provenance**: On diffs `> ~300` lines, have a fresh
   reviewer judge before/after without tool scores and revert neutral/worse
   hunks. Ask before appending the provenance block from
   [`references/refactoring_recipes.md`](references/refactoring_recipes.md#3-pull-request--commit-provenance-template).
