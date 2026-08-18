# `pkg:undead`: Architecture, Technical Approach & Testing Standards

## 1. Executive Summary & Design Alignment

`pkg:undead` is built as a sibling package in the `analytica.dart` monorepo workspace. It shares core design patterns, dependencies, and testing conventions with `packages/cognitive_complexity`.

---

## 2. Package Dependencies & Standards

### 2.1 Runtime Dependencies
* `analyzer: '>=12.0.0 <15.0.0'`: AST parsing, element model resolution, and call graph analysis.
* `args: ^2.7.0`: Command-line option and flag parsing.
* `path: ^1.9.1`: Cross-platform path normalization.
* `io: ^1.0.5`: Standard exit codes and terminal output.

### 2.2 Testing Dependencies (Aligned with `cognitive_complexity`)
* `checks: ^0.3.1`: Fluent, type-safe assertions (`check(actual)...`).
* `test_descriptor: ^2.0.2`: Ephemeral file system fixtures (`d.dir(...)`, `d.file(...)`) for constructing isolated mock Dart packages during testing.
* `test_process: ^2.1.1`: Subprocess execution (`TestProcess.start(...)`) for CLI integration testing.
* `test: ^1.25.0`: Core test scaffolding.
* `dart_flutter_team_lints: ^3.5.2`: Unified Google Dart/Flutter linter ruleset.

---

## 3. Core Engine Architecture

```
packages/undead/
├── bin/
│   └── undead.dart              # CLI binary entrypoint
├── lib/
│   ├── undead.dart              # Public programmatic API
│   └── src/
│       ├── models.dart          # DeclarationNode, UndeadFinding, OrphanTestSite, UndeadReport
│       ├── root_harvester.dart  # Discovers export roots (lib/**), executables (bin/), tools, examples
│       ├── ast_visitor.dart     # Resolves AST units and extracts element reference edges
│       ├── reachability_engine.dart # Dual-pass BFS graph traversal & classification logic
│       ├── comment_parser.dart  # Parses // undead:ignore directives
│       ├── formatters/
│       │   ├── json_formatter.dart
│       │   └── markdown_formatter.dart
│       └── cli.dart             # ArgParser setup, exit codes, and workflow runner
└── test/
    ├── models_test.dart
    ├── root_harvester_test.dart
    ├── reachability_engine_test.dart
    ├── comment_parser_test.dart
    └── cli_test.dart            # Subprocess end-to-end integration tests
```

---

## 4. Analysis & Graph Traversal Pipeline

### 4.1 Step 1: Context Creation & Root Harvesting
* `AnalysisContextCollection` is created for the target package directory using the host SDK path.
* `RootHarvester` scans the package structure:
  * **Public API Roots**: Extracts all exported symbols from `libraryElement.exportNamespace.definedNames` across all non-`src` files under `lib/`.
  * **Executable Roots**: Finds `main()` functions in `bin/**/*.dart`.
  * **Demonstration Roots**: Harvests all declarations in `example/**/*.dart` (marked as immune from deletion in demonstration mode).
  * **Auxiliary Roots**: Finds `main()` in `tool/`, `benchmark/`, `web/`.
  * **Test Roots**: Finds `main()` in `test/**/*_test.dart`, `integration_test/**`.
  * **Config / Native Roots**: Scans for `build.yaml` builder factories and `@pragma('vm:entry-point')` annotations.

### 4.2 Step 2: AST & Reference Extraction
* `AstVisitor` walks each resolved unit:
  * Records every top-level declaration node (`ClassDeclaration`, `FunctionDeclaration`, `EnumDeclaration`, `MixinDeclaration`, `ExtensionDeclaration`, `ExtensionTypeDeclaration`, `TypeAlias`, `TopLevelVariableDeclaration`).
  * Gathers outbound reference edges by inspecting resolved `Element2` identifiers (ignoring doc comment references).
  * Parses conditional import URIs (`if (dart.library.js_interop)`) to union platform branches.
  * Links direct subtypes of `sealed` classes to preserve pattern match exhaustiveness.

### 4.3 Step 3: Dual-Pass BFS Traversal
* **Pass 1 (Production)**: Traverses the graph from Public API + Executable + Demonstration + Auxiliary roots to produce `PRODUCTION_LIVE`.
* **Pass 2 (Tests)**: Traverses the graph from Test roots to produce `TEST_REACHABLE`.

### 4.4 Step 4: Classification & Hazard Evaluation
* Compares declarations in `lib/src/`:
  * $D \notin \text{PRODUCTION\_LIVE} \land D \notin \text{TEST\_REACHABLE} \implies$ **Pure Zombie** (Delete).
  * $D \notin \text{PRODUCTION\_LIVE} \land D \in \text{TEST\_REACHABLE} \implies$ **Tested Zombie**:
    * If test block contains ONLY dead references $\implies$ Safe to delete test block.
    * If test block co-invokes live and dead code $\implies$ Flag `co_invoked_test_hazard`.

---

## 5. Testing Methodology & Fixtures

### 5.1 Unit Tests with `test_descriptor`
All reachability scenarios are verified using ephemeral in-memory packages created via `package:test_descriptor`:

```dart
test('detects unexported top-level function as pure zombie', () async {
  await d.dir('pkg', [
    d.file('pubspec.yaml', '''
name: sample_pkg
environment:
  sdk: '^3.5.0'
'''),
    d.dir('lib', [
      d.file('sample_pkg.dart', '''
export 'src/live.dart';
'''),
      d.dir('src', [
        d.file('live.dart', 'void liveFunc() {}'),
        d.file('dead.dart', 'void deadFunc() {}'),
      ]),
    ]),
  ]).create();

  final report = await analyzePackage(d.path('pkg'));
  check(report.zombies).single.which((it) => it
    ..name.equals('deadFunc')
    ..classification.equals(UndeadClassification.pureUndead)
  );
});
```

### 5.2 CLI Integration Tests with `test_process`
CLI integration tests launch `bin/undead.dart` via `TestProcess.start(Platform.resolvedExecutable, ...)` to verify:
* `--format=json` payload schema conformance.
* `--format=markdown` table rendering.
* `--example-mode=demonstration` vs `strict`.
* `--fail-on-zombies` exit code handling (0 vs 1).
