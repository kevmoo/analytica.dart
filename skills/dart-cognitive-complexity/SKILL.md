---
name: dart-cognitive-complexity
description: >-
  Evaluates and reduces Cognitive Complexity in Dart and Flutter code using
  deterministic CLI tooling and architectural refactoring patterns (exhaustive
  pattern matching, guard clauses, method decomposition). Use when reviewing
  codebase readability, remediating high-complexity warnings, or analyzing
  structural code health. Don't use for general code formatting, simple syntactic
  lints, or non-Dart/Flutter repositories.
license: Apache-2.0
key_features:
  - Automated CLI evaluation
  - 3-tier execution scope matrix
  - Interactive refactoring triage
  - Dart 3 pattern matching refactorings
---

## 1. When to Use This Skill

Use this skill when analyzing Dart and Flutter codebase maintainability,
evaluating function readability, or remediating high-complexity findings during
code review or static analysis audits.

Unlike Cyclomatic Complexity (which linearly counts control flow branching paths
and punishes declarative table switches), Cognitive Complexity measures the
mental friction required for a human engineer to read and simulate control flow.
Rely on deterministic evaluation to target structures matching these indicators:

* **Deeply Nested Control Flow**: Functions exhibiting multiple layers of enclosing
  conditionals (`if`, `for`, `while`), where horizontal indentation obscures logic.
* **Convoluted Conditional Trees**: Functions employing verbose `if-else` or
  `else if` chains instead of modern Dart 3 exhaustive pattern matching or
  table-driven switch expressions.
* **Monolithic Method Bodies**: Functions breaching operational threshold ceilings.
* **God Classes**: Logic classes exceeding structural line-count targets
  (excluding declarative Flutter `build` methods).

---

## 2. Automated Execution & Scope Resolution

Execute the official package CLI directly in the terminal to retrieve exact
complexity scores deterministically without LLM arithmetic or AST interpretation.

> **SDK Compatibility Note**: Executing `dart run cognitive_complexity@` requires
> Dart SDK version **3.12.0 or greater** installed in the host environment. Verify
> compatibility via `dart --version` before initiating scans.

Select the execution scope based on the user's task instructions:

### Tier 1: Targeted Scope (Specific File, Directory, or Class)
When the user references a discrete component (e.g., "check complexity in
`lib/src/auth/`" or "audit `order_service.dart`"), pass explicit targets:

```bash
dart run cognitive_complexity@ --threshold 15 lib/src/auth/
```

### Tier 2: Delta Scope (Pull Request, Branch, or Pre-flight Audit)
When reviewing a feature branch, active commit stack, or PR, avoid full-project
scanning. Isolate evaluation strictly to modified declarations against trunk:

```bash
dart run cognitive_complexity@ --git-diff origin/main --fail-on-increase
```

### Tier 3: Whole-Project Scope (Default Naked Invocation)
When invoked without targeting parameters ("scan my project for complexity" or
`/cognitive-complexity`), audit the standard source and test roots:

```bash
# Production logic target (threshold 15)
dart run cognitive_complexity@ --threshold 15 lib/

# Test harness target (threshold 40)
dart run cognitive_complexity@ --threshold 40 test/
```

---

## 3. Actionable Thresholds & Calibration

* **Production Logic Functions**: Target score `<= 15`. Functions exceeding 15 points
  mandate architectural refactoring.
* **Test Methods (`_test.dart`)**: Target score `<= 40`. Test suites tolerate higher
  setup sequences before decomposition is required.
* **Class Size Ceiling**: Logic classes (services, domain objects, controllers)
  should remain `<= 150` non-comment lines.
* **Flutter UI Calibration**: Do not enforce the 150 LOC class ceiling on
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
When threshold breaches are detected, **do not mutate code immediately**.
Output a ranked Markdown **Complexity Triage Report** directly in chat (or to an
artifact for extensive findings) containing:
* Flagged function name and clickable file local path.
* Current complexity score versus operational ceiling.
* Recommended refactoring strategy (Pattern A, B, or C) and unit test status.

### Stage 2: Interactive User Selection (Confirmation Gate)
Pause execution and prompt the user (via interactive choice or chat) to select
the desired sequencing:
1. **(Recommended) Refactor Top Hotspot Only**: Target the single highest-scoring
   declaration first, verify via unit tests, and present diffs cleanly.
2. **Selective Batch Refactor**: Remediate a user-specified subset of functions.
3. **Report-Only / Exit**: Acknowledge complexity scores without code mutation.

> **Explicit Bypass Exception**: Skip Stage 1 triage only when the user provides
> an explicit remediation directive upfront (e.g., "Refactor `processOrder` in
> `lib/src/order.dart` to fix complexity").

---

## 5. Pre-Refactoring Assessment & Test Coverage Gate

High cognitive complexity strongly correlates with brittle, untested legacy logic.
Before undertaking structural refactoring on flagged functions, enforce this
verification baseline:

1. **Test Harness Mapping**: Confirm an accompanying unit test file exists for
   the target declaration (e.g., `lib/src/foo.dart` -> `test/foo_test.dart`).
2. **Coverage Audit & Execution**:
   * If the **`dart-collect-coverage`** companion skill is available in your
     agent runtime, invoke it to check line and branch coverage on the targeted
     declarations.
   * At minimum, execute the relevant test suite (`dart test test/foo_test.dart`)
     to confirm a passing green regression baseline before touching code.
3. **Low-Coverage Safety Gate**: If tests are missing or coverage around the
   flagged function is inadequate, pause execution and explicitly warn the user:
   > ⚠️ **Low Test Coverage Warning**: Function `<name>` in `<path>` lacks unit
   > test coverage. Structural refactoring risks silent behavioral regression.
   
   Offer clear remediation paths:
   1. **(Recommended)** Write unit tests to lock in baseline behavior first.
   2. Proceed with structural refactoring and verify functionality manually.

---

## 6. Dart Refactoring Patterns

When remediation is required for declarations flagged by the scanner, apply these
Dart-specific architectural refactorings:

### Pattern A: Replace Nested If-Else with Dart 3 Switch Expression

In Dart 3, an entire exhaustive switch expression incurs a single base penalty,
regardless of how many pattern arms it contains. Converting deeply nested `if-else`
trees into declarative tables removes repeated branching penalties and flattens
nesting.

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

**Anti-Goodhart Guardrail**: Do NOT blindly wrap monolithic functions in single-use runner classes with mutable instance variables just to bring scores below 15. Reducing the metric must never sacrifice transparent data flow or hide bugs. 

When choosing how to reduce complexity on a large Dart function, follow this **3-Tier Decision Hierarchy**:

1. **Tier 1 (First Choice - Pure Functional Decomposition)**:
   - For sequential workflows, data pipelines, and validation suites.
   - Extract static or top-level functions using Dart 3 records (`final (:data, :errors) = _stepOne(input);`). 
   - *Soft Cap*: Limit record returns to 3 simple values. If the pipeline yields 4+ distinct variables, mandate a dedicated `Result` or `Response` dataclass instead of a massive tuple to preserve schema readability.
2. **Tier 2 (Second Choice - Standard Extract Method)**:
   - For sub-routines requiring $\le3$ arguments without duplicating state. Extract standard private helper methods.
3. **Tier 3 (Third Choice - Encapsulated Method Object / Runner Class)**:
   - Reserved strictly for excessive "data trampolining"—when extracting standard methods would require passing the same 3+ mutable variables tightly coupled across multiple mutually recursive callbacks.
   - > **Companion Skill Hint**: If the **`encapsulated-method-object`** companion skill is installed, rely on its strict rules banning stateless runner classes.

---

### Pattern D: Fast-Fail Type Matching & Silent Data Swallowing

When refactoring loops and type checks to reduce branching, **never** replace explicit type casts with pattern matching that silently drops data.

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

## 7. Verification Guardrails

Run these verification commands before committing refactored code:

1. **Complexity Audit**: Run `dart run cognitive_complexity@ --fail-threshold 15`
   to verify zero declarations exceed operational ceilings.
2. **Code Presentation**: Run `dart format .` to maintain uniform syntactic
   styling.
3. **Static Analysis**: Run `dart analyze` to ensure zero static warnings, lint
   violations, or un-awaited asynchronous gaps.
4. **Test Fidelity**: Run `dart test` (or `flutter test`) to confirm zero
   behavioral drift across existing test suites.
