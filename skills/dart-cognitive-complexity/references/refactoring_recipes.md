# Dart Cognitive Complexity: Refactoring Recipes & Deep Module Guardrails

This reference accompanies [`SKILL.md`](../SKILL.md) and provides the full
before/after refactoring catalog (Patterns A–F), Ousterhout "Deep Modules"
decomposition rules, library boundary selection (`lib/src/` vs. `part` /
`part of`), the `api_summary` verification workflow, and the PR provenance
template.

---

## 1. Ousterhout "Deep Modules" & Public API Surface Guardrails

Reducing per-function cognitive complexity (`<= 15`) and splitting oversized
files (`> 400` lines) must never create shallow internal helper classes or leak
internal plumbing into a package's public API surface (`lib/<pkg>.dart` /
`api.txt`).

### 1.1 Deep Externally, Pure Internally (No Stateful Single-Use `_Populator` / `_Runner` Classes)

- **Explicit Prohibition**: Never decompose a complex function by creating
  single-use stateful private helper classes (`_FooPopulator`, `_BarBuilder`,
  `_BazRunner`) that hold mutable fields across methods or mutate caller
  collections (`Map`, `Set`, `List`) in-place. Moving local variables into
  mutable class fields hides data flow across parameterless `void _step()` calls
  without reducing actual complexity.
- **Mandatory Requirement**: Extract **pure file-private top-level functions**
  (`_validateItem(...)`, `_parseHeader(...)`) or `static` methods on existing
  domain types with explicit inputs and immutable return values (Dart 3 named
  records or immutable value types).

#### Anti-Pattern: Stateful Single-Use `_Populator` Class (Banned)

```dart
// BANNED: Single-use stateful helper class mutating fields across void methods.
class _OrderSummaryPopulator {
  final List<LineItem> items;
  final Map<String, double> totalsByCategory = {};
  final List<String> warnings = [];

  _OrderSummaryPopulator(this.items);

  void populate() {
    for (final item in items) {
      _accumulateItem(item);
    }
  }

  void _accumulateItem(LineItem item) {
    if (item.price < 0) {
      warnings.add('Negative price on ${item.id}');
      return;
    }
    totalsByCategory.update(
      item.category,
      (v) => v + item.price,
      ifAbsent: () => item.price,
    );
  }
}
```

#### Preferred: Pure File-Private Top-Level Functions Returning Records

```dart
// REQUIRED: Pure file-private top-level functions with explicit inputs and
// immutable record return values.
({Map<String, double> totalsByCategory, List<String> warnings})
_summarizeOrderItems(Iterable<LineItem> items) {
  final totals = <String, double>{};
  final warnings = <String>[];

  for (final item in items) {
    final warning = _validateItem(item);
    if (warning != null) {
      warnings.add(warning);
      continue;
    }
    totals.update(
      item.category,
      (v) => v + item.price,
      ifAbsent: () => item.price,
    );
  }
  return (
    totalsByCategory: Map.unmodifiable(totals),
    warnings: List.unmodifiable(warnings),
  );
}

String? _validateItem(LineItem item) =>
    item.price < 0 ? 'Negative price on ${item.id}' : null;
```

### 1.2 Load-Bearing Library Boundary Rule (`Tier 1` vs. `Tier 2` When Splitting Files)

Prefer the boundary enforced by the Dart compiler (library privacy `_` and class
modifiers) over advisory lint annotations (`@internal`, which still leaks into
`api.txt` when attached to members of exported classes):

- **Tier 1 (Default — Standalone `lib/src/<topic>.dart`)**: Use when extracted
  helpers form a genuine sub-domain with narrow parameter lists (`<= 3` args),
  require **zero** access to private `_` members of the parent class/library,
  and cross **zero** library-scoped class modifier boundaries (`sealed`,
  `final`, `interface`, `base`, or private generative constructors `._()`).
  Re-export only intentional public symbols via explicit
  `export 'src/<topic>.dart' show ...;`—never unscoped `export 'src/...';`.
- **Tier 2 (`part` / `part of`)**: Use when splitting one cohesive domain where
  helpers share private `_` fields, private constructors (`._()`), class
  modifiers (`sealed`, `final`, `interface`, `base`), or internal invariants, OR
  when standalone `lib/src/` files would require widening visibility (e.g.,
  removing `_` or adding `@internal`) and risk leaking internal types via
  unscoped `export 'src/...';` directives.

### 1.3 Mandatory `api_summary` Public API Surface Verification Gate

Whenever a complexity or file-split refactor extracts helpers across files or
touches `lib/` exports in a Dart package, verify that the public API surface did
not accidentally widen:

1. **Ensure package resolution and capture a non-empty baseline before
   refactoring** (without `.dart_tool/package_config.json`, `api_summary`
   silently exits `0` with only the `environment:` header and `0` `package:`
   entries, making a before/after diff tautologically empty):
   ```bash
   test -f .dart_tool/package_config.json || dart pub get
   dart run api_summary@^1.1.0 > /tmp/api_before.txt && rg -q '^package:' /tmp/api_before.txt
   ```
2. **Capture post-refactor surface**:
   ```bash
   dart run api_summary@^1.1.0 > /tmp/api_after.txt && rg -q '^package:' /tmp/api_after.txt
   ```
3. **Verify zero unintended public symbol leaks**:
   ```bash
   diff -u /tmp/api_before.txt /tmp/api_after.txt
   ```
   If `api.txt` is tracked in the repository, also verify `git diff api.txt` is
   empty (or run `dart run api_summary@^1.1.0 --check`).

---

## 2. Dart Refactoring Pattern Catalog

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

Run the companion statement-level data-flow analyzer on each candidate line
slice before extracting:

```bash
dart run cognitive_complexity:data_flow@^0.2.5 lib/src/my_file.dart:45-80
```

Its report (`inputs`, `mutations`, live `outputs`, control-flow escapes,
complexity impact `enclosingScore` / `sliceScoreInPlace` / `sliceScoreAtRoot` /
`estimatedEnclosingScoreAfter`, `extractionWarnings`, and a synthesized Dart 3
record signature) selects the tier. If `extractionWarnings` flags `HIGH_ARITY`
(`>= 5` inputs) or `LOW_COMPLEXITY_PAYOFF`, flatten in place with Patterns A/B
instead of extracting a shallow pass-through helper:

1. **Tier 1 — Pure Functional Decomposition (First Choice)**:
   - **Selection**: Cleanly extractable slice with 2+ live outputs, `<= 4`
     inputs, and `sliceScoreAtRoot >= 3`.
   - **Idiom**: Extract a pure file-private top-level function (`_parseHeader`,
     `_validateItem`) or `static` method returning the synthesized Dart 3 named
     record signature verbatim (`final (:data, :errors) = _stepOne(input);`).
   - **Dataclass Boundary**: Private, file-local slices use named records at ANY
     output count—do not create single-use `_XxxResult` dataclasses for them.
     Reserve dedicated dataclasses only for values that cross public API
     boundaries or require specialized invariants/methods.
   - **State Scoping**: If the helper does not read or mutate class instance
     state (`this`), declare it as a private top-level function (or `static`
     method) to guarantee referential transparency.
2. **Tier 2 — Standard Helper Extraction (Second Choice)**:
   - **Selection**: Cleanly extractable slice with `<= 1` live output, `<= 3`
     inputs, and `sliceScoreAtRoot >= 3`.
   - **Idiom**: Extract a pure private top-level function or private helper
     method returning that single value.
3. **Control-Flow Escapes & Loop Bodies**:
   - Enlarge the slice to include the entire enclosing loop or state machine and
     re-run `data_flow`.
   - If the loop body itself is the hotspot, extract it with an explicit signal
     return (Pattern E)—never a `shouldBreak` boolean flag.
   - Use guard-clause inversion (Pattern B) when the escape exists only to skip
     nested conditions.
4. **Tier 3 — Encapsulated Method Object (Last Resort)**:
   - **Mutation-Web Check Gate**: Permitted ONLY if `data_flow` reports on at
     least two distinct candidate slices show that the intersection of their
     `mutations` variable names contains 3 or more entries (the same mutable
     variables thread through every candidate extraction).
   - **Mechanics**: Read [`method-object.md`](method-object.md) for extraction
     mechanics and mandatory idioms. Do not load or apply it speculatively.
   - **Domain-Modeling Exit**: When the same tightly coupled mutable state keeps
     resurfacing across a function (a parser's `buffer` + `cursor`, a
     traversal's `queue` + `visited`), promote it to a real, cohesively named
     domain class (`Parser`, `GraphTraversal`) with multiple public behaviors
     and its own unit test suite.

---

### Pattern D: Fast-Fail Type Matching & Silent Data Swallowing

When refactoring loops and type checks to reduce branching, **never** replace
explicit type casts with pattern matching that silently drops data.

#### Flawed Structure (Silent Failure)

```dart
for (final raw in rawTasks) {
  // SILENTLY DROPS malformed data if raw is not a Map
  if (raw case final Map<String, dynamic> taskMap) {
    _applyTask(taskMap);
  }
}
```

#### Correct Structure (Fast-Fail Preservation)

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
loop, never smuggle the control flow through boolean flags (`shouldBreak` soup).
Return an explicit signal and keep the loop keywords at the loop site:

```dart
enum _ScanAction { proceed, skip, halt }

// Pure, independently testable top-level helper.
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

Use a `sealed class` instead of an `enum` when the signal must carry a payload.
Prefer extracting the _entire loop_ when `data_flow` shows it forms a natural
seam; use Pattern E when the loop body alone is the hotspot.

---

### Pattern F: Acyclic File Decomposition (`file_split`)

When a Dart file grows beyond `400` lines (enforceable via opt-in
`--max-file-lines 400` and `--max-function-lines 60` on `cognitive_complexity`),
run the deterministic intra-file dependency graph advisor:

```bash
dart run cognitive_complexity:file_split@^0.2.5 lib/src/large_file.dart --target-lines 300
```

Apply the **Load-Bearing Library Boundary Rule** (Section 1.2) when selecting
between a standalone `lib/src/<topic>.dart` file (**Tier 1**) and `part` /
`part of` (**Tier 2**), and always run the `api_summary` verification gate
(Section 1.3) before and after splitting.

---

### Pattern G: Re-Inlining Shallow Single-Caller Helpers (`shallow`)

When over-eager complexity decomposition leaves behind single-caller
micro-helpers or high-arity bucket-brigade functions (`>= 5` parameters), run
the AST shallow helper scanner:

```bash
dart run cognitive_complexity:shallow@^0.2.5 lib/
```

The scanner identifies non-exported helpers with `FanIn == 1` and
`TestFanIn == 0` matching any of 4 structural tags (`HIGH_ARITY`,
`MICRO_HELPER`, `SIG_HEAVY`, `CROSS_FILE_SINGLE_CALLER`) and simulates the exact
caller Cognitive Complexity at the call-site nesting depth after re-inlining:

- **`SAFE_INLINE` (`CallerCCAfter <= 15`)**: Re-inline the helper directly into
  its sole caller and delete the helper declaration.
- **`FLATTEN_AND_INLINE` (`HelperCC <= 4` and `CallerCCAfter > 15`)**: Flatten
  nesting at the call site using Pattern A (`switch` expression) or Pattern B
  (early guard clauses) and inline the helper.
- **`LOAD_BEARING` (`HelperCC >= 5` and `CallerCCAfter > 15`)**: Keep extracted,
  or narrow its parameter list if `HIGH_ARITY`.

---

## 3. Pull Request & Commit Provenance Template

When confirmed by the user in interactive sessions, include this standardized
block in the PR description or commit body:

````markdown
### 🤖 Tool Provenance & Complexity Delta

This refactoring was guided by
[`cognitive_complexity`](https://pub.dev/packages/cognitive_complexity)
(`v{version}`).

| Target Declaration | Pre-Score | Post-Score | Operational Ceiling |
| :--- | :---: | :---: | :---: |
| `{declaration_name}` (`{file_path}`) | `{pre_score}` | `{post_score}` | `<={threshold}` |

To reproduce or re-evaluate cognitive complexity scores:

```bash
{exact_command_line}
```

```bash
dart run cognitive_complexity:data_flow@^0.2.5 {file}:{start_line}-{end_line}
```
````
