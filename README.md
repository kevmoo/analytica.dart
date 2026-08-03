A deterministic, zero-token Cognitive Complexity calculation library, CLI
tool, and GitHub Action for Dart and Flutter repositories.

Unlike Cyclomatic Complexity (which measures control flow branch density),
Cognitive Complexity measures how difficult a method is for a human engineer
to read and understand, following the whitepaper specification by G. Ann
Campbell.

---

## Features

* **Modern Dart 3 AST Support**: Natively parses switch expressions, pattern
  guards (`when` clauses), and collection control flow structures.
* **Deterministic Engine**: Calculates complexity algorithmically without invoking
  LLM calls or external network requests.
* **Git Diff Analysis**: Compares current workspace declarations against a target
  base ref to isolate complexity deltas (Δ) in modified functions.
* **Lightweight GitHub Action**: Exposes workflow annotations and step summaries
  for CI check integration.

---

## Scoring Model

Scores follow the [SonarSource Cognitive Complexity whitepaper][whitepaper]
(G. Ann Campbell, v1.7):

* **Structural (+1, plus current nesting depth)**: `if`, the conditional
  (`?:`) operator, `switch` statements and expressions, `for` (including
  `for-in` and `await for`), `while`, `do-while`, and `catch`. Each also
  deepens nesting for its contents.
* **Hybrid (flat +1, no nesting penalty)**: `else` and `else if`. An
  `else if` chain does not deepen nesting — contents of every branch sit one
  level below the head `if`.
* **Fundamental (flat +1)**: each sequence of like logical operators
  (`a && b && c` is +1) with +1 for each alternation between `&&` and `||`,
  and labeled `break`/`continue`.
* **Nesting only (+0)**: lambdas and local function declarations deepen
  nesting for their contents but add nothing themselves.
* **Free (+0)**: `try`/`finally`, `throw`/`rethrow`, early `return`,
  unlabeled `break`/`continue`, null-aware operators (`??`, `??=`, `?.`),
  `assert`, and `switch` case labels.

Dart-specific interpretations of the spec:

* Pattern `when` guards add +1 (a guard is an extra condition to evaluate).
* Pattern-level combinators (`case 1 || 2:`, `case > 0 && < 10`) are free —
  an or-pattern is the modern spelling of stacked case labels, which the
  spec scores at zero.
* The whitepaper's "+1 for each method in a recursion cycle" is not
  implemented, matching SonarSource's own reference implementation
  (sonar-java), which omits it as well.

[whitepaper]: https://www.sonarsource.com/docs/CognitiveComplexity.pdf

---

## 💻 CLI Usage

You can run the scanner on-demand without installation, locally inside a project, or globally.

### On-Demand (Recommended)

Run the scanner directly in any Dart or Flutter project root using the Dart SDK:

```bash
dart run cognitive_complexity@ [options] [targets]
```

*(Note: The trailing `@` instructs the Dart VM to resolve and execute the latest published version of the package on-demand).*

### Project Dependency

Add the package to your `dev_dependencies` in `pubspec.yaml`:

```yaml
dev_dependencies:
  cognitive_complexity: ^0.1.0
```

And run:

```bash
dart run cognitive_complexity [options] [targets]
```

### Global Installation

To install the scanner globally on your system:

```bash
dart install cognitive_complexity
cognitive_complexity [options] [targets]
```

### Options

* `-t, --threshold <value>`: Minimum score to display in the terminal (default: `0`).
* `-f, --fail-threshold <value>`: Ceilings score. Exits with code `1` if any
  declaration exceeds this value.
* `-d, --git-diff <git-ref>`: Compares current code against a git commit/ref,
  evaluating complexity deltas (Δ) on modified functions.
* `--fail-on-increase`: When using `--git-diff`, exits with code `1` if any
  modified function experienced a complexity score increase.
* `--format <text|json|github>`: Report output formatting (default: `text`).

---

## 📦 Library API Usage

Exposes programmatic analyzers for Dart and Flutter applications.

Add to `pubspec.yaml`:
```yaml
dependencies:
  cognitive_complexity: ^0.1.0-wip
```

### Programmatic Scan Example

```dart
import 'package:cognitive_complexity/cognitive_complexity.dart';

void main() {
  final analyzer = ComplexityAnalyzer();

  // Scan a directory or file path
  final results = analyzer.analyzePath('lib/src');

  for (final res in results) {
    print('${res.name}: score is ${res.score} (${res.filePath}:L${res.startLine})');
  }
}
```

---

## 🤖 GitHub Actions Integration

You can run complexity checks automatically on pull requests using the
integrated composite GitHub Action.

### PR Delta Audit Workflow Example

This workflow scans only the files and functions modified in the pull request. It
injects inline code review warnings directly on modified PR lines and prints a
beautiful markdown transition table to the workflow summary.

Create `.github/workflows/complexity.yml`:

```yaml
name: Cognitive Complexity Audit

on:
  pull_request:
    branches: [ main ]

jobs:
  audit:
    runs-on: ubuntu-latest
    permissions:
      pull-requests: write # Required to post/update sticky PR comments
      contents: read       # Required for actions/checkout
    steps:
      - name: Checkout Repository
        uses: actions/checkout@v7
        with:
          # Fetch full history so merge-base comparison can locate common ancestor
          fetch-depth: 0

      - name: Setup Dart SDK
        uses: dart-lang/setup-dart@v1

      - name: Run Complexity Scanner
        uses: kevmoo/cognitive_complexity.dart@main
        with:
          # Auto-configures pull request merge base comparison
          diff-base: origin/${{ github.base_ref }}
          fail-threshold: 15
          fail-on-increase: true
```

### Action Configuration Parameters (`with:`)

* `targets`: Space-separated directories or files to scan (default: `lib`).
* `threshold`: Minimum score to include in report tables (default: `0`).
* `fail-threshold`: Max complexity ceiling (default: `15`).
* `diff-base`: Git ref to compare against (e.g. `origin/main`). Leave empty
  to compare full repository files.
* `fail-on-increase`: Set `true` to block PR merge if complexity increases.
* `format`: Summary format: `github` (GHA annotations + summary), `text`, or `json`.

### Permissions & Security

By default, GitHub Actions runs with read-only permissions. To enable posting and updating the sticky PR comment summary directly on the PR thread, you must explicitly grant write permissions to `pull-requests`:

```yaml
permissions:
  pull-requests: write
  contents: read
```

If write permissions are not granted, the scanner will execute normally, and output annotations and step summaries, but will skip posting the PR comment without failing the build.

#### Fork PR Security Note
Workflows triggered by pull requests from external forks are executed with restricted read-only permissions by GitHub. For security reasons, the action will gracefully skip posting PR comments on forks to prevent Remote Code Execution (RCE) risks, while still validating code complexity in GHA annotations and build status.
