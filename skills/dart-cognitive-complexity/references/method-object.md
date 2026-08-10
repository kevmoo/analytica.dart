# Tier 3 Reference: Encapsulated Method Object

> **GATE**: This is the last-resort tier of the 3-Tier Decomposition Rubric in
> [SKILL.md](../SKILL.md). Apply it ONLY after `data_flow` analysis of the
> candidate slices has demonstrated a dense mutation web — the same 3+ mutable
> variables threading through every candidate extraction ("data
> trampolining"). If Tier 1 (records/`Result` dataclass) or Tier 2 (standard
> private helpers) can express the extraction, use those instead and do not
> apply this pattern.

This is a Dart-specific variation of Martin Fowler's classic refactoring
**"Replace Method with Method Object"**.

## Contraindications (Do NOT apply when...)

* **Simpler refactoring suffices**: State can be cleanly passed via
  parameters without bloating signatures — use standard private helpers.
* **Sequential pipelines & transformations**: Never convert pure linear
  pipelines, simple scripts, or validation routines into runner classes.
  Pass state via arguments; return via Dart 3 records or `Result` classes.
  Encapsulation resolves *shared mutable state* and *nested scope bloat*,
  NOT line length.
* **No dense closure capturing**: If the function lacks inner functions
  capturing heavy shared outer state, a runner class is over-engineering.

## Mechanics

1. **Phase 1 — Method Object Extraction**: Migrate the function's logic into
   a dedicated class. Parameters become constructor arguments, local
   variables become instance fields, inner functions become instance
   methods.
2. **Phase 2 — Facade Delegation**: Make the runner class **private**
   (`_`-prefixed). The original public function remains as a one-line facade
   that instantiates the runner and calls its orchestrator method
   (typically `run()`).

### Workflow

1. **Confirm coverage**: Verify the target has passing tests before touching
   it (see the Pre-Refactoring Assessment gate in SKILL.md).
2. **Analyze scopes**: Inputs → constructor args; locals → instance fields;
   if the outer function is an instance method, pass the enclosing instance
   (`this`) to the runner's constructor.
3. **Draft the private runner**: `_OriginalFunctionNameRunner` (or
   `..._State`), private fields, entry point `run()`.
4. **Port sub-tasks**: Each inner function becomes a private instance
   method; replace closure captures with field access.
5. **Construct the facade**: Replace the original body with a single runner
   call; prefer fat-arrow syntax if it fits on one line.
6. **Verify**: `dart format`, `dart analyze` (zero diagnostics),
   `dart test` — and re-run the complexity scan.

## Pattern A: Basic Bloated Closure

**Before:**
```dart
Result processOrder(Order order, User user, PaymentDetails payment) {
  bool isValidated = false;
  List<String> auditLogs = [];

  void validate() {
    if (order.items.isEmpty) throw Exception("Empty order");
    isValidated = true;
    auditLogs.add("Validated by ${user.id}");
  }

  void charge() {
    if (!isValidated) throw Exception("Must validate first");
    // complex charging logic using payment details...
    auditLogs.add("Charged ${payment.method}");
  }

  validate();
  charge();

  return Result(success: true, logs: auditLogs);
}
```

**After:**
```dart
// The Facade (Original API signature preserved)
Result processOrder(Order order, User user, PaymentDetails payment) =>
    _ProcessOrderRunner(order, user, payment).run();

// The Method Object (Private to the file/library)
class _ProcessOrderRunner {
  final Order _order;
  final User _user;
  final PaymentDetails _payment;

  // Local variables promoted to private instance fields
  bool _isValidated = false;
  final List<String> _auditLogs = [];

  _ProcessOrderRunner(this._order, this._user, this._payment);

  Result run() {
    _validate();
    _charge();
    return Result(success: true, logs: _auditLogs);
  }

  void _validate() {
    if (_order.items.isEmpty) throw Exception("Empty order");
    _isValidated = true;
    _auditLogs.add("Validated by ${_user.id}");
  }

  void _charge() {
    if (!_isValidated) throw Exception("Must validate first");
    // complex charging logic using payment details...
    _auditLogs.add("Charged ${_payment.method}");
  }
}
```

## Pattern B: Outer Instance Binding (Async + Generics)

When the target is an instance method, keep a reference to the enclosing
class so the runner can reach its dependencies:

```dart
class DataProcessor {
  final StorageService storage;
  final Logger logger;

  DataProcessor(this.storage, this.logger);

  // Facade remains identical. Generics map directly to the runner class.
  Future<List<T>> processDataBatch<T>(
    String batchId,
    List<Map<String, dynamic>> items,
    T Function(Map<String, dynamic>) parser,
  ) =>
      _ProcessDataBatchRunner<T>(this, batchId, items, parser).run();
}

class _ProcessDataBatchRunner<T> {
  final DataProcessor _outer; // enclosing instance for deps (logger, storage)
  final String _batchId;
  final List<Map<String, dynamic>> _items;
  final T Function(Map<String, dynamic>) _parser;

  int _successCount = 0;
  final List<T> _results = [];

  _ProcessDataBatchRunner(this._outer, this._batchId, this._items, this._parser);

  Future<List<T>> run() async {
    for (final item in _items) {
      await _processItem(item);
    }
    await _saveBatch();
    return _results;
  }

  // ... ported helpers access _outer.logger / _outer.storage ...
}
```

## Constraints

* **API Footprint Preservation**: The original public signature (parameters,
  return type, annotations, generics) MUST be preserved unchanged.
* **Strict Class Encapsulation**: The runner class MUST be `_`-private.
* **Single-use Execution Scope**: A runner instance represents one
  invocation. Never store it long-term or call `run()` twice.
* **Command-Query Separation**: Lookup/search/resolver methods on the runner
  must be pure. State mutations occur only in orchestrator methods upon
  confirmed resolution success.
* **Testability Demotion**: If a computational or parsing subroutine is
  complex enough to need dedicated unit tests, it must NOT live inside the
  private runner — extract it to a top-level function or public utility
  class, since `_Runner` is inaccessible to external test files.
* **Constructor Purity**: Constructors only map inputs and perform
  lightweight, non-throwing initialization. Logic, async work, and side
  effects live in `run()`.

## Anti-Patterns & Mandatory Idioms

### 🚫 `late final` Constructor Unpacking

When the runner receives a complex input object (`Command`, `ArgResults`),
do NOT mark fields `late final` and unpack them in the constructor body.

**❌ BANNED:**
```dart
final class _ScanRunner {
  final ScanCommand command;

  late final ArgResults results;
  late final String? project;
  late final bool detailed;

  _ScanRunner({required this.command}) {
    results = command.argResults!;
    project = results.option('project');
    detailed = results.flag('detailed');
  }
}
```

**✅ MANDATORY — private generative constructor + factory unpacking:**
```dart
final class _ScanRunner {
  final ArgResults results;
  final String? project;
  final bool detailed;

  const _ScanRunner._({
    required this.results,
    required this.project,
    required this.detailed,
  });

  factory _ScanRunner(ScanCommand command) {
    final results = command.argResults!;
    return _ScanRunner._(
      results: results,
      project: results.option('project'),
      detailed: results.flag('detailed'),
    );
  }
}
```

All fields stay truly `final` (no `LateInitializationError` hazard), and
tests can call `_ScanRunner._(...)` directly with mock primitives.

### 🚫 "Global-in-a-Box" & Parameterless Voids

Never use a Method Object just to avoid passing arguments. A runner must not
become a dumping ground of mutable `this.*` state.

* **The `void` Ban**: Private runner methods should almost never be
  parameterless `void` methods that silently mutate instance fields.
* **Explicit Data Flow**: Subroutines accept explicit parameters and return
  explicit values. Mutate internal state explicitly at the call site
  (e.g. `currentCount = _calculateNewCount(currentCount);`).
