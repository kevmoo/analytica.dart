# Tier 3 Reference: Encapsulated Method Object

> **GATE**: This is the last-resort tier of the 3-Tier Decomposition Rubric in
> [SKILL.md](../SKILL.md). Apply it ONLY when the mutation-web check has
> passed with recorded evidence: `data_flow` reports on at least two distinct
> candidate slices whose `mutations` variable names intersect in 3 or more
> entries. If Tier 1 (records / `Result` dataclass) or Tier 2 (standard
> private helpers) can express the extraction, use those instead.

This is a Dart-specific variation of Martin Fowler's classic refactoring
**"Replace Method with Method Object"**.

## Contraindications (Do NOT apply when...)

* **The gate did not pass**: fewer than 3 shared mutable variables in the
  intersection, or only a single candidate slice was analyzed.
* **Simpler refactoring suffices**: state can be cleanly passed via
  parameters without bloating signatures — use standard private helpers.
* **Sequential pipelines & transformations**: never convert pure linear
  pipelines, simple scripts, or validation routines into runner classes.
  Pass state via arguments; return via Dart 3 records or `Result` classes.
  Encapsulation resolves *shared mutable state* and *nested scope bloat*,
  NOT line length.

## Mechanics

1. **Phase 1 — Method Object Extraction**: migrate the function's logic into
   a dedicated class. Parameters become constructor arguments, the shared
   mutable locals become instance fields, and inner functions become
   instance methods.
2. **Phase 2 — Facade Delegation**: make the runner class **private**
   (`_`-prefixed). The original public function remains as a one-line facade
   that instantiates the runner and calls its orchestrator method
   (typically `run()`).

### Workflow

1. **Confirm coverage**: verify the target has passing tests before touching
   it (see the Pre-Refactoring Assessment gate in SKILL.md).
2. **Analyze scopes**: inputs → constructor args; shared mutable locals →
   instance fields; if the outer function is an instance method, pass the
   enclosing instance (`this`) to the runner's constructor.
3. **Draft the private runner**: `_OriginalFunctionNameRunner` (or
   `..._State`), private fields, entry point `run()`.
4. **Port sub-tasks**: decision logic becomes *pure query methods* returning
   explicit values; all mutations of instance state happen in `run()` at the
   call sites of those queries (see the example and the void ban below).
5. **Construct the facade**: replace the original body with a single runner
   call; prefer fat-arrow syntax if it fits on one line.
6. **Verify**: `dart format`, `dart analyze` (zero diagnostics),
   `dart test` — and re-run the complexity scan on the refactored file.

## Worked Example: Interleaved Mutation Web

The gate-qualifying smell: 3+ mutable locals shared by multiple inner
functions whose reads and writes interleave, so any standard extraction
would trampoline the same variables through every helper signature.

**Before** (shared mutable web: `applied`, `conflicts`, `warnings`):
```dart
SyncReport reconcileInventory(List<Item> local, List<Item> remote) {
  final applied = <Change>[];
  final conflicts = <Conflict>[];
  final warnings = <String>[];

  void noteConflict(Item mine, Item theirs) {
    conflicts.add(Conflict(mine, theirs));
    warnings.add('local ${mine.id} is newer than remote');
  }

  void apply(Change change) {
    // Reads `conflicts`, writes `applied` and `warnings`.
    if (change.isDestructive && conflicts.isNotEmpty) {
      warnings.add('skipped destructive ${change.id} amid conflicts');
      return;
    }
    applied.add(change);
  }

  for (final mine in local) {
    final theirs = remote.firstWhereOrNull((r) => r.id == mine.id);
    if (theirs == null || mine.revision == theirs.revision) continue;
    if (mine.updatedAt.isAfter(theirs.updatedAt)) {
      noteConflict(mine, theirs);
    } else {
      apply(Change.update(mine.id, theirs));
    }
  }
  return SyncReport(applied, conflicts, warnings);
}
```

**After** — facade + private runner. Note the shape: helpers are *pure
queries*; every mutation of instance state is visible in `run()`:
```dart
// The Facade (original API signature preserved)
SyncReport reconcileInventory(List<Item> local, List<Item> remote) =>
    _ReconcileRunner(local, remote).run();

// The Method Object (private to the library)
class _ReconcileRunner {
  final List<Item> _local;
  final List<Item> _remote;

  // The shared mutable web, promoted to private instance fields.
  final List<Change> _applied = [];
  final List<Conflict> _conflicts = [];
  final List<String> _warnings = [];

  _ReconcileRunner(this._local, this._remote);

  // Orchestrator: the ONLY place instance state is mutated.
  SyncReport run() {
    for (final mine in _local) {
      final theirs = _remote.firstWhereOrNull((r) => r.id == mine.id);
      if (theirs == null || mine.revision == theirs.revision) continue;

      if (mine.updatedAt.isAfter(theirs.updatedAt)) {
        _conflicts.add(Conflict(mine, theirs));
        _warnings.add('local ${mine.id} is newer than remote');
      } else {
        final change = Change.update(mine.id, theirs);
        if (_isSafe(change)) {
          _applied.add(change);
        } else {
          _warnings.add('skipped destructive ${change.id} amid conflicts');
        }
      }
    }
    return SyncReport(_applied, _conflicts, _warnings);
  }

  // Pure query over current state: no mutation, result returned explicitly.
  bool _isSafe(Change change) => !change.isDestructive || _conflicts.isEmpty;
}
```

In a larger gate-qualifying function, decision logic grows into further pure
query methods returning explicit values; mutations stay in `run()`.

## Outer Instance Binding

When the target is an *instance method* (one that has already passed the
gate), the runner needs the enclosing object's dependencies. Bind the
enclosing instance in the constructor; generics map directly onto the
runner class:

```dart
class DataProcessor {
  final StorageService storage;
  final Logger logger;

  DataProcessor(this.storage, this.logger);

  // Facade remains identical.
  Future<List<T>> processBatch<T>(
    String batchId,
    List<Map<String, dynamic>> items,
    T Function(Map<String, dynamic>) parse,
  ) =>
      _ProcessBatchRunner<T>(this, batchId, items, parse).run();
}

class _ProcessBatchRunner<T> {
  // Enclosing instance: helpers reach _outer.logger, _outer.storage.
  final DataProcessor _outer;
  final String _batchId;
  final List<Map<String, dynamic>> _items;
  final T Function(Map<String, dynamic>) _parse;

  _ProcessBatchRunner(this._outer, this._batchId, this._items, this._parse);

  Future<List<T>> run() async {
    // Orchestrator body elided: binding mechanics are the point here. A
    // real target must still exhibit the gate-qualifying mutation web.
    throw UnimplementedError();
  }
}
```

## Constraints

* **API Footprint Preservation**: the original public signature (parameters,
  return type, annotations, generics) MUST be preserved unchanged.
* **Strict Class Encapsulation**: the runner class MUST be `_`-private.
* **Single-use Execution Scope**: a runner instance represents one
  invocation. Never store it long-term or call `run()` twice.
* **Command-Query Separation**: lookup/search/resolver methods on the runner
  must be pure. State mutations occur only in orchestrator methods upon
  confirmed resolution success.
* **Testability Demotion**: if a computational or parsing subroutine is
  complex enough to need dedicated unit tests, it must NOT live inside the
  private runner — extract it to a top-level function or public utility
  class, since `_Runner` is library-private and inaccessible to external
  test files.
* **Constructor Purity**: constructors and factories only map and validate
  inputs (an input-validation throw such as a null-assert is acceptable).
  Logic, async work, and side effects live in `run()`.

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

All fields stay truly `final` (no `late` fields, no
`LateInitializationError` hazard), and initialization order is explicit in
one place.

### 🚫 "Global-in-a-Box" & Parameterless Voids

Never use a Method Object just to avoid passing arguments. A runner must not
become a dumping ground of mutable `this.*` state.

* **The `void` Ban**: private runner methods should almost never be
  parameterless `void` methods that silently mutate instance fields.
* **Explicit Data Flow**: subroutines accept explicit parameters and return
  explicit values. Mutate instance state explicitly at the call site in the
  orchestrator (e.g. `currentCount = _calculateNewCount(currentCount);`).
