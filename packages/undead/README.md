Deterministic reachability and dead/unused declaration analysis for Dart and
Flutter packages.

`undead` performs whole-package AST analysis using `package:analyzer` to build a
reachability graph from known entrypoints to all internal declarations,
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

### CLI Options

<!-- CLI_README_START -->

```console
$ undead --help
undead - Reachability and dead declaration analysis for Dart packages.

Usage: undead [options] [target_path]

-f, --format                               Output formatting mode for stdout (json for agents/CI, markdown for humans).
                                           [markdown (default), json, github]
    --json-output=<path/to/report.json>    Write machine-readable JSON analysis report to the specified file (recommended for agents and CI pipelines alongside human stdout).
    --example-mode                         How code in example/ is treated during reachability analysis.
                                           [demonstration (default), strict, skip]
-m, --mode                                 Package analysis mode.
                                           [library (default), closed-app]
    --exclude=<glob>                       Glob patterns of files/directories to exclude (repeatable or comma-separated).
    --[no-]ignore-generated                Exclude generated files (*.g.dart, *.freezed.dart, *.mocks.dart, etc.).
                                           (defaults to on)
    --[no-]fail-on-undead                  Exit with non-zero code (1) if any undead declaration is detected.
    --test-support-patterns                Comma-separated naming wildcard patterns for test fixtures and hooks.
                                           (defaults to "Fake*,Mock*")
    --ignore-name-patterns                 Comma-separated naming wildcard patterns for declaration names to ignore.
                                           (defaults to "")
    --extra-roots=<dir1,dir2>              Comma-separated list of additional root/test directories or companion packages to include in reachability analysis.
                                           (defaults to "")
    --[no-]ignore-external-bindings        Ignore unreferenced external platform and FFI/interop facade declarations.
    --[no-]workspace-discovery             Automatically discover and ingest consumer roots from sibling packages in the enclosing workspace.
                                           (defaults to on)
    --[no-]suggest-private                 Detect and suggest making internal lib/src declarations private if only used within their declaring library.
    --sdk-path                             Path to the Dart SDK root (overrides auto-discovery).
    --pub-get                              Automatically run "dart pub get" (or "flutter pub get") if dependencies are unresolved.
-h, --help                                 Print usage information.
    --version                              Print undead version.
```

<!-- CLI_README_END -->

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

## 🧠 AI Agent Integration

This repository packages an agent skill (`dart-undead`) to train AI pair
programmers on dead code audits, reachability analysis, and safe deletion
protocols:

```bash
npx skills add kevmoo/analytica.dart --skill dart-undead
```
