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
  - Dart 3 pattern matching refactorings
  - Guard clause depth inversion
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

## 2. Automated Execution Strategy

Execute the official package CLI directly in the terminal to retrieve exact
complexity scores, file paths, line numbers, and breach warnings deterministically,
without consuming token bandwidth on manual AST interpretation or arithmetic:

```bash
# Display declarations with scores at or above the threshold (default target: lib/)
dart run cognitive_complexity@ --threshold 15

# Enforce strict build guardrails by failing (exit code 1) on threshold breaches
dart run cognitive_complexity@ --fail-threshold 15

# Audit code review deltas against main and fail on any score increase
dart run cognitive_complexity@ --git-diff origin/main --fail-on-increase
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

## 4. Dart Refactoring Patterns

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

### Pattern C: Encapsulated Method Object Extraction

When a monolithic function contains dense closures capturing heavy local variable
state that prevents simple function extraction, migrate the function body into a
dedicated private runner class. Promoting local variables to class instance fields
collapses closure nesting penalties and unlocks focused helper method
decomposition.

#### Refactoring Workflow
1. Create a private class (e.g., `_PayloadProcessor`) accepting required state
   through its constructor.
2. Store mutable local variables as instance fields on the private class.
3. Replace the original monolithic function body with a single instantiation and
   method invocation on the runner object (`_PayloadProcessor(args).execute()`).
4. Deconstruct the inner execution body into small, focused instance methods.

---

## 5. Verification Guardrails

Run these verification commands before committing refactored code:

1. **Complexity Audit**: Run `dart run cognitive_complexity@ --fail-threshold 15`
   to verify zero declarations exceed operational ceilings.
2. **Code Presentation**: Run `dart format .` to maintain uniform syntactic
   styling.
3. **Static Analysis**: Run `dart analyze` to ensure zero static warnings, lint
   violations, or un-awaited asynchronous gaps.
4. **Test Fidelity**: Run `dart test` (or `flutter test`) to confirm zero
   behavioral drift across existing test suites.
