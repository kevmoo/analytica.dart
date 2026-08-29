---
name: dart-cognitive-complexity
description: >-
  Evaluates and reduces Cognitive Complexity in Dart and Flutter code using
  deterministic CLI tooling and architectural refactoring patterns (exhaustive
  pattern matching, guard clauses, method decomposition). Use when reviewing
  codebase readability, remediating high-complexity warnings, or analyzing
  structural code health. Don't use for general code formatting, simple
  syntactic lints, or non-Dart/Flutter repositories.
license: Apache-2.0
key_features:
  - Automated CLI evaluation
  - Scoped execution matrix (targeted / delta / full)
  - Interactive refactoring triage
  - Dart 3 pattern matching refactorings
  - Reproducible PR provenance reporting
---

## 1. When to Use This Skill

Use this skill when analyzing Dart and Flutter codebase maintainability,
evaluating function readability, or remediating high-complexity findings during
code review or static analysis audits.

Unlike Cyclomatic Complexity (which linearly counts control flow branching paths
and punishes declarative table switches), Cognitive Complexity measures the
mental friction required for a human engineer to read and simulate control flow.
Rely on deterministic evaluation to target structures matching these indicators:

- **Deeply Nested Control Flow**: Functions exhibiting multiple layers of
  enclosing conditionals (`if`, `for`, `while`), where horizontal indentation
  obscures logic.
- **Convoluted Conditional Trees**: Functions employing verbose `if-else` or
  `else if` chains instead of modern Dart 3 exhaustive pattern matching or
  table-driven switch expressions.
- **Monolithic Method Bodies**: Functions breaching operational threshold
  ceilings.
- **God Classes**: Logic classes exceeding structural line-count targets
  (excluding declarative Flutter `build` methods).

---

## 2. Automated Execution & Scope Resolution

Execute the official package CLI directly in the terminal to retrieve exact
complexity scores deterministically without LLM arithmetic or AST
interpretation.

> **SDK Compatibility Note**: Executing `dart run cognitive_complexity@^0.2.4`
> requires Dart SDK version **3.12.0 or greater** installed in the host
> environment. Verify compatibility via `dart --version` before initiating
> scans.

Select the execution scope based on the user's task instructions:

### Scope 1: Targeted (Specific File, Directory, or Class)

When the user references a discrete component (e.g., "check complexity in
`lib/src/auth/`" or "audit `order_service.dart`"), pass explicit targets:

```bash
dart run cognitive_complexity@^0.2.4 --threshold 15 lib/src/auth/
```

### Scope 2: Delta (Pull Request, Branch, or Pre-flight Audit)

When reviewing a feature branch, active commit stack, or PR, avoid full-project
scanning. Isolate evaluation strictly to modified declarations against trunk:

```bash
dart run cognitive_complexity@^0.2.4 --git-diff origin/main --fail-threshold 15 --fail-on-increase
```

With both flags set, only increases that exceed the threshold fail — healthy
sub-threshold increases (e.g. added error handling) are reported without
blocking. Omit `--fail-threshold` only when a strict any-increase ratchet is
explicitly desired.

### Scope 3: Whole-Project (Default Naked Invocation)

When invoked without targeting parameters ("scan my project for complexity" or
`/cognitive-complexity`), audit the standard source and test roots:

```bash
# Production logic target (threshold 15)
dart run cognitive_complexity@^0.2.4 --threshold 15 lib/

# Test harness target (threshold 40)
dart run cognitive_complexity@^0.2.4 --threshold 40 test/
```

---

## 3. Actionable Thresholds & Calibration

- **Production Logic Functions**: Target score `<= 15`. Functions exceeding 15
  points mandate architectural refactoring.
- **Test Methods (`_test.dart`)**: Target score `<= 40`. Test suites tolerate
  higher setup sequences before decomposition is required.
- **Class Size Ceiling**: Logic classes (services, domain objects, controllers)
  should remain `<= 150` non-comment lines.
- **Flutter UI Calibration**: Do not enforce the 150 LOC class ceiling on
  declarative Flutter `build` methods, as widget wrappers consume vertical space
  without increasing cognitive logic load. Instead, enforce a **Widget Tree
  Nesting Ceiling** of maximum 5 horizontal indentation levels before extracting
  discrete helper widget classes.

---

## 4. The Triage & Confirmation Protocol (Audit Before Action)

Discovering high-complexity functions during an audit does not grant permission
to autonomously refactor the entire repository. To prevent unwanted diff bloat
and preserve historical code stability, adhere to a strict 2-stage workflow:

### Stage 1: Read-Only Audit & Reporting (Mandatory Stop)

When threshold breaches are detected, **do not mutate code immediately**. Output
a ranked Markdown **Complexity Triage Report** directly in chat (or to an
artifact for extensive findings) containing:

- Flagged function name and clickable file local path.
- Current complexity score versus operational ceiling (sorted descending by
  score).
- Recommended refactoring strategy (Pattern A, B, D, E, or a Pattern C tier) and
  unit test status.

### Invariant: Outlier-First Mandate

- **Target the Primary Outlier**: When remediating complexity, prioritize the
  highest-scoring declaration in the report (e.g. Score >= 25 or top outlier)
  to achieve the highest measurable reduction.
- **Prioritize High-Impact Reductions**: Avoid selecting only minor
  sub-threshold helpers while leaving severe complexity outliers unaddressed.
- **Decomposition Target**: Apply Dart 3 pattern matching, guard clauses, and
  method decomposition targeting a post-refactoring score of `<= 15`. For
  massive legacy functions (score > 60), safe phased decomposition across
  isolated PRs is permitted if a single pass would exceed reviewable diff limits.

### Stage 2: Interactive User Selection (Confirmation Gate)

Pause execution and prompt the user (via interactive choice or chat) to select
the desired sequencing:

1. **(Recommended) Refactor Primary Outlier First**: Target the single
   highest-scoring declaration in the report, decompose towards score <= 15,
   verify via unit tests, and present diffs cleanly.
2. **Selective Batch Refactor**: Remediate the top N highest-scoring functions
   in descending order.
3. **Report-Only / Exit**: Acknowledge complexity scores without code mutation.

> **Explicit Bypass & Direct Directives**:
> - **Direct Directives**: Skip Stage 1 triage if given an explicit remediation
>   directive upfront (e.g., "Refactor `processOrder` in `lib/src/order.dart` to
>   fix complexity" or "Refactor the top complexity outlier").
> - **Automated Task Execution**: When explicitly directed to remediate, proceed
>   with Option 1 (Refactor Primary Outlier) after verifying baseline tests pass.

---

## 5. Pre-Refactoring Assessment & Test Coverage Gate

High cognitive complexity strongly correlates with brittle, untested legacy
logic. Before undertaking structural refactoring on flagged functions, enforce
this verification baseline:

1. **Test Harness Mapping**: Confirm an accompanying unit test file exists for
   the target declaration (e.g., `lib/src/foo.dart` -> `test/foo_test.dart`).
2. **Coverage Audit & Execution**:
   - If the **`dart-collect-coverage`** companion skill is available in your
     agent runtime, invoke it to check line and branch coverage on the targeted
     declarations.
   - At minimum, execute the relevant test suite (`dart test test/foo_test.dart`
     or `flutter test test/foo_test.dart`) to confirm a passing green regression
     baseline before touching code.
3. **Low-Coverage Safety Gate**: If tests are missing or coverage around the
   flagged function is inadequate:
   - **Interactive Sessions**: Pause execution and warn the user. Offer options
     to (1) write unit tests first, or (2) proceed with surgical refactoring.
   - **Automated Task Execution**: Log a low-coverage warning and author a
     minimal regression test before modifying complex logic.
   2. Proceed with structural refactoring and verify functionality manually.

---

## 6. Dart Refactoring Patterns

When remediation is required for declarations flagged by the scanner, apply
these Dart-specific architectural refactorings:

### Pattern A: Replace Nested If-Else with Dart 3 Switch Expression

In Dart 3, an entire exhaustive switch expression incurs a single base penalty,
regardless of how many pattern arms it contains. Converting deeply nested
`if-else` trees into declarative tables removes repeated branching penalties and
flattens nesting.

#### Before: Nested Conditional Ladders (Score: 11)

```dart
int resolveTimeout(String protocol, bool isSecure, int retryCount) {
  if (protocol == 'http') {
    if (isSecure) {
      if (retryCount > 3) {
        return 5000;
      } else {
        return 3000;
      }
    } else {
      return 1000;
    }
  } else if (protocol == 'ftp') {
    return isSecure ? 10000 : 2000;
  }
  return 0;
}
```

#### After: Table-Driven Switch Expression (Score: 1)

```dart
int resolveTimeout(String protocol, bool isSecure, int retryCount) =>
    switch ((protocol, isSecure, retryCount)) {
      ('http', true, > 3) => 5000,
      ('http', true, _) => 3000,
      ('http', false, _) => 1000,
      ('ftp', true, _) => 10000,
      ('ftp', false, _) => 2000,
      _ => 0,
    };
```

---

### Pattern B: Guard Clause Inversion (Flattening Nesting Depth)

Invert conditional checks into early guard return statements
(`if (!condition) return;`). Every early exit strips away a layer of nesting
multiplication from subsequent downstream logic.

#### Before: Pyramid of Nesting (Score: 11)

```dart
Future<void> syncPayload(User? user, Payload? data) async {
  if (user != null) {
    if (user.hasPermission) {
      if (data != null && data.isValid) {
        for (final item in data.items) {
          await repository.save(item);
        }
      }
    }
  }
}
```

#### After: Early Exit Guard Clauses (Score: 5)

```dart
Future<void> syncPayload(User? user, Payload? data) async {
  if (user == null || !user.hasPermission) return;
  if (data == null || !data.isValid) return;

  for (final item in data.items) {
    await repository.save(item);
  }
}
```

---

### Pattern C: The 3-Tier Decomposition Rubric (Anti-Goodhart)

**Anti-Goodhart Guardrail**: Do NOT blindly wrap monolithic functions in
single-use runner classes with mutable instance variables just to bring scores
below 15. Reducing the metric must never sacrifice transparent data flow or hide
bugs.

#### Deterministic Tier Selection via `data_flow`

#### Deterministic 3-Tier Selection via `data_flow`

Do not manually estimate or guess which tier a candidate slice belongs to. Run
the companion statement-level data-flow analyzer (on-demand form; same SDK
3.12.0+ requirement as the scanner) on each line slice you intend to extract:

```bash
dart run cognitive_complexity:data_flow@^0.2.4 lib/src/my_file.dart:45-80
```

Its report (`inputs`, `mutations`, live `outputs`, control-flow escapes, and a
synthesized Dart 3 record signature) selects the tier:

1. **Tier 1 — Pure Functional Decomposition (First Choice)**:
   - **Selection**: Cleanly extractable slice with 2+ live outputs.
   - **Idiom**: Extract a static or top-level function returning the synthesized
     Dart 3 named record signature verbatim (`final (:data, :errors) = _stepOne(input);`).
   - **Dataclass Boundary**: Private, file-local slices use named records at ANY
     output count—do not create single-use `_XxxResult` dataclasses for them.
     Reserve dedicated dataclasses only for values that cross public API
     boundaries or require specialized invariants/methods.
   - **State Scoping**: If the helper does not read or mutate class instance
     state (`this`), declare it as a private top-level function (or static
     method) to guarantee referential transparency.

2. **Tier 2 — Standard Helper Extraction (Second Choice)**:
   - **Selection**: Cleanly extractable slice with <= 1 live output and <= 3
     inputs.
   - **Idiom**: Extract a standard private helper method or private top-level
     function returning that single value.

3. **Control-Flow Escapes & Loop Bodies**:
   - Apply natural seams: enlarge the slice to include the entire enclosing loop
     or state machine and re-run `data_flow`.
   - If the loop body itself is the hotspot, extract it with an explicit signal
     return (Pattern E)—never a `shouldBreak` boolean flag.
   - Use guard-clause inversion (Pattern B) when the escape exists only to skip
     nested conditions.

4. **Tier 3 — Encapsulated Method Object (Last Resort)**:
   - **Mutation-Web Check Gate**: Permitted ONLY if `data_flow` reports on at
     least two distinct candidate slices show that the intersection of their
     `mutations` variable names contains 3 or more entries (the same mutable
     variables thread through every candidate extraction).
   - **Mechanics**: Read [references/method-object.md](references/method-object.md)
     for extraction mechanics and mandatory idioms. Do not load or apply it
     speculatively.

**Domain-Modeling Exit**: When the same tightly coupled mutable state keeps
resurfacing across a function (a parser's `buffer` + `cursor`, a traversal's
`queue` + `visited`), the code may be asking to become a real, cohesively
_named_ domain class (`Parser`, `GraphTraversal`) with a public, unit-tested
API. To qualify for the exit, the class MUST have cohesive entity state, more
than one public behavior, and its own dedicated test suite. Single-use private
facades with one `run()` method remain subject to the Tier 3 gate.

---

### Pattern D: Fast-Fail Type Matching & Silent Data Swallowing

When refactoring loops and type checks to reduce branching, **never** replace
explicit type casts with pattern matching that silently drops data.

**Flawed Structure (Silent Failure):**

```dart
for (final raw in rawTasks) {
  // SILENTLY DROPS malformed data if raw is not a Map
  if (raw case final Map<String, dynamic> taskMap) {
    _applyTask(taskMap);
  }
}
```

**Correct Structure (Fast-Fail Preservation):**

```dart
for (final raw in rawTasks) {
  if (raw is! Map<String, dynamic>) {
    errors.add('Malformed task item (expected Map, got ${raw.runtimeType}): $raw');
    continue;
  }
  _applyTask(raw);
}
```

---

### Pattern E: Loop-Body Extraction with Signal Returns

When a loop body must be extracted but contains `break`/`continue` targeting the
loop, never smuggle the control flow through boolean flags (`shouldBreak` soup)
— that raises cognitive load and hides termination conditions. Return an
explicit signal and keep the loop keywords at the loop site:

```dart
enum _ScanAction { proceed, skip, halt }

// Pure, independently testable helper.
_ScanAction _classify(Entry entry, Set<String> seen) {
  if (seen.contains(entry.id)) return _ScanAction.skip;
  if (entry.isTerminal) return _ScanAction.halt;
  return _ScanAction.proceed;
}

outer:
for (final entry in entries) {
  switch (_classify(entry, seen)) {
    case _ScanAction.skip:
      continue;
    case _ScanAction.halt:
      break outer;
    case _ScanAction.proceed:
      process(entry);
  }
}
```

Use a sealed class instead of an enum when the signal must carry a payload.
Asynchronous classification works identically:
`switch (await _classify(entry, seen))`. The exhaustive `switch` keeps every
termination path visible at the loop site. Prefer extracting the _entire loop_
when `data_flow` shows it forms a natural seam; use Pattern E when the loop body
alone is the hotspot.

---

## 7. Verification Guardrails

Run these verification commands before committing refactored code:

1. **Complexity Audit**: Run
   `dart run cognitive_complexity@^0.2.4 --fail-threshold 15 <refactored files>`
   scoped to the files you touched. Pre-existing breaches elsewhere in the
   project do not invalidate the refactor.
2. **Code Presentation**: Run `dart format .` (or `flutter format .`) to
   maintain uniform syntactic styling.
3. **Static Analysis**: Run `dart analyze` (or `flutter analyze`) to ensure zero
   static warnings, lint violations, or un-awaited asynchronous gaps.
4. **Test Fidelity**:
   - Check `pubspec.yaml`: if `sdk: flutter` is declared, run `flutter test`;
     otherwise run `dart test`.
   - In multi-package workspaces, run tests across all dependent packages.

---

## 8. Pull Request & Commit Provenance Protocol

When staging refactored code and preparing a commit message or Pull Request:

### 1. User Confirmation Gate

- **Interactive Sessions**: Before writing the PR description or commit body,
  explicitly prompt the user in chat or via the harness confirmation tool (e.g.
  `ask_question`) whether to include a **Tool Provenance & Complexity Delta
  block**.
- **User Prompt Inclusion**: When the user explicitly requests inclusion (or
  confirms via prompt), append the standardized markdown block below. In
  unattended or automated workflows, output the summary to chat or step
  summaries rather than modifying commit bodies without user confirmation.

### 2. Standardized Provenance Block Format

When confirmed by the user, include the following markdown block in the PR
description or commit body so reviewers understand where the changes originated,
see the quantified readability improvements, and can rerun the audit locally:

````markdown
### 🤖 Tool Provenance & Complexity Delta

This refactoring was guided by
[`cognitive_complexity`](https://pub.dev/packages/cognitive_complexity)
(`v{version}`).

<!-- mdformat off(prevent table wrapping) -->

| Target Declaration                   |   Pre-Score   |   Post-Score   | Operational Ceiling |
| :----------------------------------- | :-----------: | :------------: | :-----------------: |
| `{declaration_name}` (`{file_path}`) | `{pre_score}` | `{post_score}` |   `<={threshold}`   |

<!-- mdformat on -->

To reproduce or re-evaluate cognitive complexity scores:

```bash
{exact_command_line}
```

<!-- If statement data-flow analysis was used during decomposition: -->

```bash
dart run cognitive_complexity:data_flow@^0.2.4 {file}:{start_line}-{end_line}
```
````

### 3. Version Resolution

Determine the package version dynamically:

- Check `pubspec.lock` in the workspace or run
  `dart run cognitive_complexity@^0.2.4 --version`.
- If invoked with a specific version constraint (e.g.
  `cognitive_complexity@^0.2.4`), use that exact version.
