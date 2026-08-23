# lower_bound

Automated Dart dependency lower-bound validator and synthetic runtime isolation engine.

`lower_bound` verifies that a Dart package or monorepo compiles cleanly against the exact minimum declared dependency floors ($L_i$) specified in `pubspec.yaml`.

## ✨ Features

- **Synthetic Runtime Isolation**:
  - Stages `lib/` and `bin/` directories in temporary isolation to prevent source tree mutations.
  - Strips `dev_dependencies` completely to prevent test-tooling dependencies (e.g. `package:test`, `package:lints`) from artificially elevating transitive dependency floors.
  - Strips `resolution: workspace` so published dependencies resolve their declared lower bounds directly from `pub.dev`.
  - Sanitizes `analysis_options.yaml` (stripping dev linter includes).
- **Exact Floor Pinning**:
  - Injects `dependency_overrides` with exact declared lower bounds ($L_i$) of every direct dependency.
  - Two-pass resolution: tries exact floor pinning, and falls back to `pub downgrade` if solver conflicts occur.
- **Unreleased `-wip` Sibling Fallback**:
  - Detects unpublished local monorepo siblings (with `-wip` versions or `publish_to: none`).
  - Automatically links them via local path overrides and emits soft warning annotations (`::warning::`), allowing other external dependencies to be validated against `pub.dev`.
- **Target Resolution Protocol**:
  - Explicit paths: validates specified directories.
  - Current directory (`.`): auto-detects `pubspec.yaml` workspace members or single packages without heuristics.
- **Rich Output Formats**:
  - `text` (human-readable summary table).
  - `github` (GitHub Actions annotations and Step Summary).
  - `json` (machine-readable JSON).
- **Sticky PR Comments**:
  - Supports `--comment-output` and `--max-comment-rows` for paginated, sticky PR comments.

## ⚡ Quick Start

### CLI

Validate the current package or monorepo workspace:

```bash
dart run lower_bound
```

Validate a specific package directory:

```bash
dart run lower_bound path/to/my_package
```

Output results as JSON:

```bash
dart run lower_bound --format=json
```

Generate a sticky PR comment report:

```bash
dart run lower_bound --comment-output=comment.md --max-comment-rows=10
```

### GitHub Action

Add `lower_bound` to your GitHub Actions workflow:

```yaml
- name: Validate Dependency Lower Bounds
  uses: kevmoo/analytica.dart/packages/lower_bound@main
  with:
    format: 'github'
    fail-on-error: 'true'
```
