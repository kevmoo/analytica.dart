## 0.1.3-wip

- Add repeatable `--entrypoint <path>` CLI option and
  `UndeadOptions.entrypoints` (with `PackageTopology.explicitEntrypoints` and
  `PackageTopology.isExplicitEntrypoint`) to declare alternate Dart/Flutter
  entrypoint files whose top-level `main()` is rooted in reachability analysis
  (#207).
- Add `UndeadReport.possibleEntrypoints` (serialized in JSON when non-empty and
  rendered as a Markdown note) to surface unrooted `main()` functions so users
  and agents can pass `--entrypoint` when appropriate (#207).

## 0.1.2

- Require `analytica` `^0.1.4`.
- Fix false-positive `testedUndead` findings on private helpers and `typedef`s
  transitively referenced by active `@visibleForTesting` / test-support
  declarations.
- Adopt centralized `PathFilter` in `UndeadOptions` and CLI for `--exclude` and
  `--[no-]ignore-generated` file filtering.
- Add `ensure_cli_readme_test.dart` to verify CLI `--help` documentation in
  `README.md`.

## 0.1.1

- Support `--suggest-private` flag to detect unexported top-level declarations
  that can be made library-private (#45).
- Add `suggestPrivate` option to `UndeadOptions`,
  `UndeadReport.privateCandidatesFound`,
  `UndeadClassification.privateCandidate`, and `SuggestedAction.makePrivate`.
- Require `package:analytica ^0.1.1`.

## 0.1.0

- Initial release of reachability and dead/unused declaration analyzer.
- Support for CLI execution, package entrypoint harvesting, and Flutter/test
  framework adapters.
- Deterministic analysis modes: open-world (libraries) and closed-app
  (standalone/executables).
- Custom suppression directives: `// undead:ignore` and
  `// undead:ignore_for_file`.
