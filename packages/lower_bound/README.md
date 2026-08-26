# lower_bound

Automated Dart dependency lower-bound validator and synthetic runtime isolation
engine.

`lower_bound` verifies that a Dart package or monorepo compiles cleanly against
the minimal satisfiable dependency floors specified in `pubspec.yaml`.

## ✨ Features

- **Synthetic Runtime Isolation**:
  - Stages `lib/` and `bin/` directories in temporary isolation to prevent
    source tree mutations.
  - Strips `dev_dependencies` completely to prevent test-tooling dependencies
    (e.g. `package:test`, `package:lints`) from artificially elevating
    transitive dependency floors.
  - Strips `resolution: workspace` so published dependencies resolve their
    declared lower bounds directly from `pub.dev`.
  - Sanitizes `analysis_options.yaml` (stripping all dev/relative includes).
- **Minimal Satisfiable Floor Resolution**:
  - Executes `pub downgrade` within the isolated staging sandbox to compute the
    lowest jointly satisfiable dependency versions allowed by all declared
    version constraints.
- **Opt-in Local Sibling Overrides**:
  - When `--allow-local-siblings` is passed, unpublished local monorepo siblings
    (with `-wip` versions or `publish_to: none`) are linked via local path
    overrides.
  - By default (`--no-allow-local-siblings`), external dependencies must be
    published on `pub.dev` to verify genuine consumer installability.
- **Target Resolution Protocol**:
  - Explicit paths: validates specified directories, automatically expanding
    workspace members if pointed at a workspace root.
  - Current directory (`.`): auto-detects `pubspec.yaml` workspace members or
    single packages without heuristics.
- **Rich Output Formats**:
  - `text` (human-readable summary table with warnings and diagnostics).
  - `github` (GitHub Actions line annotations and Step Summary).
  - `json` (machine-readable structured JSON).
- **Sticky PR Comments**:
  - Supports `--comment-output` and `--max-comment-rows` for paginated, sticky
    PR comments.

## ⚡ Quick Start

### CLI

Validate the current package or monorepo workspace:

```bash
dart run lower_bound
```

Validate a specific package directory or monorepo root (workspace members are
automatically expanded):

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
name: Dependency Lower-Bound Validation

on:
  pull_request:

jobs:
  validate:
    runs-on: ubuntu-latest
    permissions:
      pull-requests: write # Required for sticky PR comment summaries
      contents: read
    steps:
      - name: Checkout Codebase
        uses: actions/checkout@v7

      - name: Setup Dart SDK
        uses: dart-lang/setup-dart@v1

      - name: Validate Dependency Lower Bounds
        uses: kevmoo/analytica.dart/packages/lower_bound@main
        with:
          format: "github"
          fail-on-error: "true"
```

#### Action Inputs Reference

<!-- mdformat off(prevent table wrapping) -->

| Input                  |  Default  | Description                                                               |
| :--------------------- | :-------: | :------------------------------------------------------------------------ |
| `package-path`         |    `.`    | Path to target package or workspace root to validate.                     |
| `targets`              | `lib,bin` | Comma-separated list of target directories or files to analyze.           |
| `allow-local-siblings` |  `false`  | Allow unreleased local sibling packages via path overrides.               |
| `sdk`                  |  _None_   | Simulate specific Dart SDK version during pub resolution.                 |
| `fail-on-error`        |  `true`   | Exit with non-zero status if lower bound validation fails.                |
| `format`               | `github`  | Output format: `github` (summary table + annotations), `text`, or `json`. |
| `max-comment-rows`     |    `0`    | Maximum table rows in the sticky PR comment (0 = unlimited).              |

<!-- mdformat on -->
