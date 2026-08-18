Shared utilities, SDK discovery, Git diff integration, and AST analysis
helpers for Dart CLI tools and analyzers.

> [!NOTE]
> This package provides foundational infrastructure for tools in the
> [`analytica.dart`](https://github.com/kevmoo/analytica.dart) monorepo (such as
> [`pkg:cognitive_complexity`](https://pub.dev/packages/cognitive_complexity) and
> `pkg:undead`). APIs are primarily tailored for internal tool composition and
> may evolve with tool requirements.

## ✨ Features

- **SDK & Tool Discovery (`package:analytica/sdk_discovery.dart`)**:
  - Resolves Dart SDK and Flutter SDK installation roots deterministically.
  - Locates `dart` / `flutter` executables across system paths, Flutter caches,
    and AOT snapshot runtimes.
  - Discovers `.dart_tool/package_config.json` across parent directories and
    Pub Workspaces.
- **AST & Analysis Utilities (`package:analytica/analyzer.dart`)**:
  - `AnalysisContextHelper`: Lightweight setup for `package:analyzer` analysis
    contexts.
  - `CommentDirectiveParser`: Parses file-level and declaration-level ignore
    directives.
  - `AstHelpers`: Traversal utilities for enclosing declarations and token spans.
  - `WildcardPattern`: Zero-dependency glob-like pattern matcher (`*`, `?`).
- **Git Integration (`package:analytica/git.dart`)**:
  - `GitDiffService`: Executes `git diff` against base refs.
  - `DiffParser`: Parses unified diffs into structured file/hunk models.
  - `AstLineMapper`: Maps AST declaration node line ranges to modified diff lines.
- **CLI & CI Utilities (`package:analytica/cli.dart`, `package:analytica/analytica.dart`)**:
  - Standardized console formatting, color utilities, and error handling.
  - GitHub Actions workflow command integration (error/warning annotations).

## ⚡ Usage

### SDK Discovery

```dart
import 'package:analytica/sdk_discovery.dart';

void main() {
  final sdkPath = findSdkPath();
  final dartExec = findDartExecutable(sdkPath: sdkPath);
  print('Dart SDK: $sdkPath');
  print('Dart Binary: $dartExec');
}
```

### Git Diff Parsing & AST Mapping

```dart
import 'package:analytica/git.dart';

void main() async {
  final diffs = await GitDiffService().getParsedDiff('origin/main');

  for (final fileDiff in diffs) {
    print('Modified file: ${fileDiff.path}');
    print('Changed ranges: ${fileDiff.addedOrModifiedLineRanges}');
  }
}
```
