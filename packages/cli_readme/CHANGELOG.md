## 0.1.0-wip

- Initial release of `package:cli_readme`:
  - 3-line test contract (`expectReadmeHelpClean`) to verify CLI usage in `README.md`.
  - Standalone CLI runner (`dart run cli_readme --write` / `--check`).
  - In-memory `ArgParser` evaluation for fast zero-subprocess testing.
  - Tagged HTML comment marker support (`<!-- CLI_README_START [id] -->`).
  - Automatic line-by-line whitespace normalization and unified diff generation.
