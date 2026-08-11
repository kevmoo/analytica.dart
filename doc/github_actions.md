# GitHub Actions Integration

The `cognitive_complexity` repository includes a composite GitHub Action that
automatically evaluates Cognitive Complexity on pull requests and commits.

It posts inline review annotations, generates markdown summary tables in
workflow summaries, and optionally updates a sticky comment on pull requests.

## PR Delta Audit Workflow Example

This workflow scans files modified in a pull request against the base branch
using `--git-diff`.

Create `.github/workflows/complexity.yml`:

```yaml
name: Cognitive Complexity Audit

on:
  pull_request:
    branches: [main]

jobs:
  audit:
    runs-on: ubuntu-latest
    permissions:
      pull-requests: write # Required to post/update sticky PR comments
      contents: read # Required for actions/checkout
    steps:
      - name: Checkout Repository
        uses: actions/checkout@v4
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

## Action Parameters (`with:`)

<!-- mdformat off(prevent table wrapping) -->

| Parameter          | Default  | Description                                                                                                                  |
| :----------------- | :------: | :--------------------------------------------------------------------------------------------------------------------------- |
| `targets`          |  `lib`   | Space-separated list of directories or files to scan.                                                                        |
| `threshold`        |   `0`    | Minimum score required to include a declaration in summary tables.                                                           |
| `fail-threshold`   |   `15`   | Maximum complexity ceiling allowed before failing the build.                                                                 |
| `diff-base`        | _Empty_  | Git ref to compare against (e.g. `origin/main`). When empty, scans entire files.                                             |
| `fail-on-increase` | `false`  | When `true`, blocks PR merge on complexity increases exceeding `fail-threshold` (or on any increase if no threshold is set). |
| `format`           | `github` | Summary format: `github` (GHA annotations + step summary), `text`, or `json`.                                                |

<!-- mdformat on -->

## Permissions & Security

### PR Comment Permissions

By default, GitHub Actions runs with read-only permissions. To enable posting
and updating the sticky PR comment summary directly on the pull request thread,
grant `pull-requests: write`:

```yaml
permissions:
  pull-requests: write
  contents: read
```

If write permissions are not granted, the action will still generate GitHub
Annotations and Step Summaries, but will gracefully skip posting the sticky
comment without failing the build.

### Fork PR Security

Workflows triggered by pull requests from external forks are executed with
restricted read-only permissions by GitHub. For security reasons, the action
automatically detects fork environments and skips posting PR comments to prevent
permission errors and security risks, while continuing to validate complexity
via check annotations.
