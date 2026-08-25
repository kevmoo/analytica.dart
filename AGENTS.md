# Repository Agent Guidelines

## Workspace Structure

- This repository is a Dart pub workspace monorepo containing multiple packages
  under `packages/`:
  - `packages/analytica`
  - `packages/cognitive_complexity`
  - `packages/dedupe`
  - `packages/undead`

## Testing Instructions

- Leverage multi-core execution by running package test suites concurrently in
  parallel across all packages:
  ```bash
  pids=(); for pkg in packages/*; do [ -d "$pkg/test" ] && (echo "Starting $pkg..." && cd "$pkg" && dart test) & pids+=($!); done; status=0; for pid in "${pids[@]}"; do wait "$pid" || status=1; done; exit $status
  ```
- To run tests for an individual package:
  `(cd packages/<package_name> && dart test)`.

## Code Quality & Verification

- Run `dart format --output=none --set-exit-if-changed .` before committing.
- Run `dart analyze --fatal-infos` across the workspace.
- Update `CHANGELOG.md` in the affected package under
  `packages/<package_name>/CHANGELOG.md` before landing.

## Skill / Package Synchronization Invariant

- **Strict Gating for Skill Updates**: Never commit or deploy updates to
  `skills/*/SKILL.md` (or external skill repositories) that reference new CLI
  flags, changed argument schemas, or bumped version constraints until the
  corresponding package release has been published and is resolvable on
  `pub.dev`.
- **Pinned Version Formats in Skills**: Always format remote execution commands
  in `SKILL.md` with explicit SemVer constraints matching published versions
  (e.g. `dart run cognitive_complexity@^0.2.4`, `dart run dedupe@^0.1.0`,
  `dart run undead@^0.1.1`).
