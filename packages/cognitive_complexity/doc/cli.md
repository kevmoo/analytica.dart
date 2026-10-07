# Command-Line Interface (CLI)

The `cognitive_complexity` package provides a high-performance, deterministic
CLI scanner for measuring Cognitive Complexity across Dart and Flutter
codebases.

## Execution Modes

Requires Dart SDK **3.12.0 or greater**.

### 1. On-Demand (Zero Installation)

Run the scanner directly in any Dart or Flutter project using the `@` syntax,
which resolves and executes the latest published version:

```bash
dart run cognitive_complexity@ [options] [targets]
```

### 2. Project Dependency

Add the package to `dev_dependencies` in `pubspec.yaml`:

```yaml
dev_dependencies:
  cognitive_complexity: ^1.0.0
```

Execute locally:

```bash
dart run cognitive_complexity [options] [targets]
```

### 3. Global System Installation

Install globally onto your system PATH:

```bash
dart install cognitive_complexity
cognitive_complexity [options] [targets]
```

## Companion CLI Executables

In addition to `cognitive_complexity`, the package includes three specialized
static-analysis CLIs:

- `dart run cognitive_complexity:data_flow`: Statement-level data-flow and
  method-extraction slice analyzer (`--sdk-path` supported).
- `dart run cognitive_complexity:file_split`: Intra-file dependency graph and
  acyclic file-decomposition advisor (`--sdk-path` supported).
- `dart run cognitive_complexity:shallow`: Single-caller shallow-helper and
  nesting-aware re-inlining advisor.

## Command Options & Flags (`cognitive_complexity`)

| Option / Flag                  | Type     | Default | Description                                                                                                                            |
| :----------------------------- | :------- | :-----: | :------------------------------------------------------------------------------------------------------------------------------------- |
| `-h, --help`                   | `flag`   | `false` | Print usage information and exit.                                                                                                      |
| `-t, --threshold <value>`      | `int`    |   `0`   | Minimum complexity score to include in the report.                                                                                     |
| `-f, --fail-threshold <value>` | `int`    | _None_  | Ceiling score; exits with code `1` if any declaration exceeds this value.                                                              |
| `--max-file-lines <lines>`     | `int`    |   `0`   | Opt-in maximum physical line count per source file (`0` = disabled).                                                                   |
| `--max-function-lines <lines>` | `int`    |   `0`   | Opt-in maximum line span per function/method declaration (`0` = disabled).                                                             |
| `-d, --git-diff <git-ref>`     | `String` | _None_  | Compares current workspace declarations against `<git-ref>`, evaluating complexity deltas (Δ).                                         |
| `--fail-on-increase`           | `flag`   | `false` | With `--git-diff`, fails if any modified function increases in complexity (or exceeds `--fail-threshold` when both are set).           |
| `--format <type>`              | `enum`   | `text`  | Output format: `text` (terminal), `json` (machine-readable), or `github` (GHA annotations).                                            |
| `-v, --verbose`                | `flag`   | `false` | With `--format=text`, adds a `Breakdown` column (`branches`, `nesting`, `boolean_ops`, `max_depth`) and tags `_test.dart` entrypoints. |
| `--comment-output <path>`      | `String` | _None_  | With `--format=github` and `--git-diff`, writes a significance-ordered standalone PR comment report.                                   |
| `--max-comment-rows <count>`   | `int`    |   `0`   | Maximum table rows in `--comment-output` (`0` = unlimited).                                                                            |
| `--exclude <glob>`             | `multi`  | _None_  | Glob patterns of files/directories to exclude (repeatable or comma-separated).                                                         |
| `--[no-]ignore-generated`      | `flag`   | `true`  | Exclude generated files (`*.g.dart`, `*.freezed.dart`, `*.mocks.dart`, etc.).                                                          |

## Target Resolution

Pass one or more file paths or directories as positional arguments:

```bash
# Scan specific directories
dart run cognitive_complexity lib bin

# Scan specific files
dart run cognitive_complexity lib/src/analyzer.dart lib/src/visitor.dart

# Auto-discover lib/ (or workspace members packages/*/lib, pkgs/*/lib)
dart run cognitive_complexity
```

## Git Diff & CI Ratcheting

The `--git-diff` option compares declarations in the working copy against a base
Git ref (such as `origin/main` or a feature branch base).

### Pragmatic Budgeted Gate (Recommended)

When `--fail-on-increase` is specified alongside `--fail-threshold`, a
complexity increase does **not** fail the run as long as the total score remains
below or equal to the `--fail-threshold`. This permits minor additions (e.g.
input validation or error handlers) while enforcing an absolute ceiling:

```bash
dart run cognitive_complexity --git-diff=origin/main --fail-threshold=15 --fail-on-increase
```

### Strict Ratchet Gate

When `--fail-on-increase` is specified **without** `--fail-threshold`, any
complexity increase on a modified function immediately exits with code `1`:

```bash
dart run cognitive_complexity --git-diff=origin/main --fail-on-increase
```

## Exit Codes

- `0`: Scan completed successfully; all thresholds and gates satisfied.
- `1`: Complexity ceiling exceeded, unauthorized complexity increase detected,
  file/function line limit exceeded, or fatal analysis error.
- `64`: Invalid command-line arguments, unknown option, or missing target path.
