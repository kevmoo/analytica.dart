Deterministic reachability and dead/unused declaration analysis for Dart and
Flutter packages.

`undead` performs whole-package AST analysis using `package:analyzer` to build
a reachability graph from known entrypoints to all internal declarations,
identifying unused top-level declarations, classes, functions, and variables.

## ✨ Features

- **Dual Analysis Modes**:
  - **Open-World** (Default): Treats all non-`src` `lib/**` exports as public
    API roots. Ideal for reusable libraries and packages.
  - **Closed-App** (`--mode=closed-app`): Traces execution strictly from
    executable entrypoints (`bin/**`, `lib/main.dart`, `lib/main_*.dart`).
- **Framework Adapters**:
  - **Flutter**: Discovers entrypoints, widget main targets, and
    `@pragma('vm:entry-point')` annotations.
  - **Build Runner**: Harvests builder factories and generator entrypoints from
    `build.yaml`.
  - **Package Test**: Identifies test suites and test runner entrypoints.
  - **JS Interop**: Preserves external JS interop bindings (`@JS()`).
- **Co-Invoked Test Hazard Protection**:
  - Distinguishes isolated dead tests from tests that co-invoke both live and
    dead code, preventing false-positive test deletions.
- **Sealed Hierarchy Awareness**:
  - Preserves subtypes of live `sealed` classes to maintain Dart 3 pattern match
    exhaustiveness.
- **Granular Suppressions**:
  - Supports `// undead:ignore` (declaration-level) and
    `// undead:ignore_for_file` (file-level) directives.

## ⚡ Quick Start

### CLI

Run the analyzer directly in any Dart or Flutter project:

```bash
dart run undead@
```

Analyze a closed standalone application:

```bash
dart run undead@ --mode=closed-app
```

Output results as JSON or Markdown:

```bash
dart run undead@ --format=json
dart run undead@ --format=markdown
```

### Library API

```dart
import 'package:undead/undead.dart';

void main() async {
  final options = UndeadOptions(
    packagePath: '.',
    mode: AnalysisMode.library,
  );
  final engine = UndeadEngine(options);
  final report = await engine.analyze();

  for (final finding in report.undead) {
    print('Unused: ${finding.name} (${finding.file}:L${finding.line})');
  }
}
```
