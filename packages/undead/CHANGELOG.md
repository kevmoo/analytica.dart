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

