---
name: dart-cognitive-complexity
description: |-
  Evaluates and reduces Cognitive Complexity in Dart and Flutter code using concrete mathematical scoring rules, exhaustive pattern matching, guard clauses, and method decomposition. Use when reviewing codebase readability, refactoring convoluted methods, or analyzing structural code health. Don't use for general code formatting, simple syntactic lints, or non-Dart/Flutter repositories.
license: Apache-2.0
key_features:
  - Cognitive complexity scoring
  - Dart 3 pattern matching
  - Guard clause refactoring
---

## 1. When to use this skill

Use this skill when analyzing Dart and Flutter codebase maintainability,
evaluating function readability, or remediating high-complexity warning
findings. Unlike traditional Cyclomatic Complexity (which linearly counts
branching paths and punishes clean declarative table switches), Cognitive
Complexity directly measures the comprehension friction required for a
human or reviewing LLM to read and simulate control flow.

Specifically, target methods and classes matching these indicators:
*   **Deeply Nested Control Flow**: Functions exhibiting multiple layers of
    enclosing conditionals (`if`, `for`, `while`), where indentation obscures
    logic.
*   **Convoluted Conditional Trees**: Functions employing verbose `if-else`
    or `else if` chains instead of modern Dart 3 exhaustive pattern matching
    or table-driven switches.
*   **Monolithic Method Bodies**: Functions that breach operational complexity
    thresholds during evaluation or static analysis audits.
*   **God Classes**: Logic classes exceeding structural line-count ceilings
    (excluding declarative Flutter `build` methods).

### Discovery & Evaluation Commands

Run deterministic, zero-token evaluation commands to identify hot-spots and
calculate complexity scores across the repository:

```bash
# Evaluate cognitive complexity across the repository (targets default to lib/)
dart run cognitive_complexity@ --threshold 15

# Audit code review deltas in a branch or PR against main
dart run cognitive_complexity@ --git-diff origin/main --fail-on-increase
```

---

## 2. Algorithmic Scoring Rules for Dart

Calculate Cognitive Complexity algorithmically using three deterministic
scoring rules:

### Rule 1: Benign Shorthand & Switches (+0 Penalty)
No base points or nesting multipliers are added for idiomatic Dart syntax
that consolidates operations into scannable expressions:
*   **Null-Aware Operators & Cascades**: `??`, `?.`, `??=`, null-aware spreads
    (`...?`), null-aware collection elements (`?item`), and cascade notation
    (`..`) cost +0 points.
*   **Dart 3 Switch Statements & Expressions**: An entire exhaustive `switch`
    block costs exactly +1 base point, regardless of whether it evaluates
    3 or 50 `case` or pattern arms. Case labels receive +0 points.

### Rule 2: Flow Interruption (+1 Base)
Add +1 base point whenever execution diverges from linear top-to-bottom
reading flow:
*   **Conditionals & Ternaries**: `if`, `else if`, `else`, and conditional
    expressions (`cond ? x : y`).
*   **Iterators**: `for`, `while`, `do-while`, and collection `for` / `if`
    clauses inside list literals.
*   **Exception Catching**: `catch` / `on` blocks (`try` and `finally` cost +0).
*   **Logical Operator Switches**: Consecutive strings of identical operators
    (`a && b && c`) count as +1 total. Alternating operator families
    (`a && b || c`) adds +1 per alternation.

### Rule 3: The Nesting Multiplier (+D Depth)
Whenever a flow-breaking structure (from Rule 2) is nested inside another
structural block, add its structural nesting depth (D) to the base cost:
*   Top-level `if` (D=0): +1 base = +1 point.
*   `for` loop nested inside that `if` (D=1): +1 base + 1 depth = +2 points.
*   Inner `if` inside the `for` (D=2): +1 base + 2 depth = +3 points.
*   **Flat Multiplicity Exceptions**: Unlike conditional openers and loops,
    `else`, `else if`, and `catch` / `on` structures receive only a flat +1
    base penalty without incurring depth nesting multipliers.

---

## 3. Execution Strategy (Deterministic Evaluation)

Do not waste token bandwidth calculating complexity scores by hand or
delegating manual arithmetic to subagents. Leverage the automated CLI tool:
*   **Automated CLI (Default)**: Always execute `dart run cognitive_complexity@ -t 15`
    in the terminal to retrieve exact complexity scores, file paths, line
    numbers, and breach warnings deterministically with zero token overhead.
*   **Inline Computation (Micro-Scope Only)**: Calculate complexity scores
    manually in chat solely when evaluating temporary code snippets (< 50 lines)
    pasted directly into the conversation before saving them to disk.

---

## 4. Actionable Thresholds & Calibration

*   **Production Logic Functions**: Target score <= 15. Functions exceeding
    15 points mandate architectural refactoring.
*   **Test Methods (`_test.dart`)**: Target score <= 40. Test harnesses
    tolerate higher structural setup sequences before decomposition is required.
*   **Class Size Ceiling**: Logic classes (services, domain objects,
    controllers) should remain <= 150 non-comment lines.
*   **Flutter UI Calibration**: Do not enforce the 150 LOC class ceiling on
    declarative Flutter `build` methods, as widget wrappers consume vertical
    space without increasing cognitive logic load. Instead, enforce a
    **Widget Tree Nesting Ceiling** of maximum 5 horizontal indentation
    levels before extracting discrete helper widget classes.

---

## 5. Refactoring Strategies & Dart Patterns

When remediating functions that breach complexity ceilings, apply these
Dart-specific architectural refactorings:

### Pattern A: Replace Nested If-Else with Dart 3 Switch Expression

#### Before: Deeply Nested Conditionals (Score: 12)
```dart
int resolveTimeout(String protocol, bool isSecure, int retryCount) {
  if (protocol == 'http') {          // D=0 -> +1 (if)
    if (isSecure) {                  // D=1 -> +2 (if + depth 1)
      if (retryCount > 3) {          // D=2 -> +3 (if + depth 2)
        return 5000;
      } else {                       // D=2 -> +1 (else flat)
        return 3000;
      }
    } else {                         // D=1 -> +1 (else flat)
      return 1000;
    }
  } else if (protocol == 'ftp') {    // D=0 -> +1 (else if flat) +3 (nested...)
    return isSecure ? 10000 : 2000;
  }
  return 0;
}
```

#### After: Table-Driven Switch Expression (Score: 1)
```dart
int resolveTimeout(String protocol, bool isSecure, int retryCount) =>
    switch ((protocol, isSecure, retryCount)) {  // D=0 -> +1 (switch expression)
      ('http', true, > 3) => 5000,               // Case arms cost +0
      ('http', true, _) => 3000,
      ('http', false, _) => 1000,
      ('ftp', true, _) => 10000,
      ('ftp', false, _) => 2000,
      _ => 0,
    };                                           // Total complexity reduction: 12 -> 1
```

---

### Pattern B: Guard Clause Inversion (Flattening Nesting Depth)

Invert conditional checks into early guard return statements
(`if (!condition) return;`). Every early exit strips away a layer of nesting
multiplication from subsequent downstream logic.

#### Before: Pyramid of Nesting (Score: 11)
```dart
Future<void> syncPayload(User? user, Payload? data) async {
  if (user != null) {                      // D=0 -> +1
    if (user.hasPermission) {              // D=1 -> +2 (if + depth 1)
      if (data != null && data.isValid) {  // D=2 -> +3 (if + depth 2) +1 (&&)
        for (final item in data.items) {   // D=3 -> +1 (for) + 3 depth = +4
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
  if (user == null || !user.hasPermission) return; // D=0 -> +1 (if) +1 (||) = +2
  if (data == null || !data.isValid) return;       // D=0 -> +1 (if) +1 (||) = +2

  for (final item in data.items) {                 // D=0 -> +1 (for at zero depth)
    await repository.save(item);
  }
}
```

---

### Pattern C: Encapsulated Method Object Extraction

When a monolithic function contains dense closures capturing heavy local
variable state that prevents simple function extraction, migrate the function
body into a dedicated private runner class using the
**`encapsulated-method-object`** skill. Read the `encapsulated-method-object`
skill instructions via `view_file` before applying this refactoring. Promoting
local variables to class instance fields collapses closure nesting penalties
and unlocks focused helper method decomposition.

---

## 6. Verification Guardrails

Run these verification commands before submitting refactored code:

1.  **Code Presentation**: Run `dart format .` to maintain uniform syntactic
    styling.
2.  **Static Analysis**: Run `dart analyze` to ensure zero static warnings,
    lint violations, or un-awaited asynchronous gaps.
3.  **Test Fidelity**: Run `dart test` (or `flutter test`) to verify zero
    behavioral drift across existing test suites.
