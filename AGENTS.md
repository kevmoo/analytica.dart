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
- Bump `pubspec.yaml` and `CHANGELOG.md` under `packages/<package_name>/` to
  `-wip` when modifying a released package, but add `CHANGELOG.md` bullets
  **only** for user-visible changes (leave `## <ver>-wip` empty or unchanged for
  internal refactorings, complexity reductions, file splits, and tests).
- **Red-Team Policy for Heuristics**: Before merging any heuristic PR, perform
  an adversarial probe pass (~20 min of writing probe fixtures to break the
  heuristic). Every confirmed probe must become a test case.

## Skill / Package Synchronization Invariant

- **Strict Gating for Skill Updates**: Never commit or deploy updates to
  `skills/*/SKILL.md` (or external skill repositories) that reference new CLI
  flags, changed argument schemas, or bumped version constraints until the
  corresponding package release has been published and is resolvable on
  `pub.dev`.
- **Pinned Version Formats in Skills**: Always format remote execution commands
  in `SKILL.md` with explicit SemVer constraints matching published versions
  (e.g. `dart run cognitive_complexity@^2.0.0`, `dart run dedupe@^0.1.1`,
  `dart run undead@^0.1.2`).

## Releasing a Package

- Follow [`doc/release.md`](doc/release.md). In short: drop `-wip` in
  `pubspec.yaml` and `CHANGELOG.md`, run
  `dart run tool/bin/release_check.dart --fix` to bump every skill pin and run
  the `tool/` test gate in one step, open a `release(<pkg>)` PR, then run
  `gh release create <pkg>-vX.Y.Z` after merge to create the GitHub Release and
  trigger publishing.
