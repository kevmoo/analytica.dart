## 0.2.2-wip

- Introduce `data_flow` analysis tool and library (`package:cognitive_complexity/data_flow.dart`):
  - Added `DataFlowAnalyzer` to extract reaching definitions (inputs), variable mutations, and live outputs for arbitrary statement slices.
  - Added `SignatureSynthesizer` to automatically generate Dart 3 Record method signatures (`({TypeA a, TypeB b})`).
  - Added `data_flow` CLI with agent-first JSON formatting by default and formatted text reports.

## 0.2.1

- Broaden `analyzer` compatibility to support versions `12.x` through `14.x`.

## 0.2.0

Scoring fixes aligning with the SonarSource Cognitive Complexity whitepaper
(v1.7) and its reference implementation (sonar-java):

- `else if` chains no longer deepen nesting: branch contents sit one level
  below the head `if` (previously each chain link added an extra level).
- `switch` statements/expressions and `catch` clauses now receive the
  standard nesting increment when nested (previously flat +1).
- Local function declarations no longer add a structural +1; like lambdas,
  they only deepen nesting.

Analyzer coverage and CLI fixes:

- Constructor initializers and parameter default values are now scored.
- Top-level functions named with pseudo-keywords (`show`, `on`, ...) are no
  longer skipped.
- Top-level getters/setters are reported with a `get `/`set ` prefix,
  matching class members.
- `--fail-on-increase` no longer flags newly added declarations (they have
  no baseline); they are governed by `--fail-threshold` alone.
- Directory exclusion (`.git`, `.dart_tool`, `build`) now matches whole path
  segments, so `.github/` and similar directories are scanned correctly.

## 0.1.0

- Initial version.
