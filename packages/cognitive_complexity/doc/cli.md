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
  cognitive_complexity: ^0.2.3
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

## Command Options & Flags

<!-- mdformat off(prevent table wrapping) -->

| Option / Flag                  | Type     | Default | Description                                                                                    |
| :----------------------------- | :------- | :-----: | :--------------------------------------------------------------------------------------------- |
| `-t, --threshold <value>`      | `int`    |   `0`   | Minimum score required to display a declaration in the report.                                 |
| `-f, --fail-threshold <value>` | `int`    | _None_  | Ceilings score. Exits with code `1` if any declaration exceeds this value.                     |
| `-d, --git-diff <git-ref>`     | `String` | _None_  | Compares current workspace declarations against `<git-ref>`, evaluating complexity deltas (Δ). |
| `--fail-on-increase`           | `flag`   | `false` | When using `--git-diff`, fails if any modified function increases in complexity.               |
| `--format <type>`              | `enum`   | `text`  | Output format: `text` (terminal), `json` (machine-readable), or `github` (GHA annotations).    |
| `--exclude <glob>`             | `glob`   | _empty_ | Skip files matching glob patterns. Comma-separated or repeated. Useful for generated sources.  |
| `--sdk-path <path>`            | `String` | _Auto_  | Overrides automated Dart/Flutter SDK location discovery.                                       |

<!-- mdformat on -->

## Target Resolution

Pass one or more file paths or directories as positional arguments:

```bash
# Scan specific directories
dart run cognitive_complexity lib bin

# Scan specific files
dart run cognitive_complexity lib/src/analyzer.dart lib/src/visitor.dart

# Scan current working directory (defaults to lib if omitted)
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
  or fatal analysis error.
