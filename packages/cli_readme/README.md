Test utility and CLI tool to ensure command-line usage and help documentation in
`README.md` files are accurate and up-to-date.

Inspired by [`package:build_verify`](https://pub.dev/packages/build_verify),
`cli_readme` gives you a **3-line test** to guarantee your CLI arguments and
usage examples never drift from the real executable output.

## ✨ Features

- **3-Line Test Contract**: Add `test('readme', expectReadmeHelpClean);` to your
  test suite.
- **In-Place Synchronization**: Run `dart run cli_readme --write` to
  automatically update your README when options or descriptions change.
- **Zero-Process Fast Mode**: Validate in-memory `ArgParser` objects directly
  without spawning Dart VM subprocesses.
- **Robust Normalization**: Automatically strips trailing whitespace (a common
  quirk of `ArgParser.usage`), normalizes CRLF line endings, and ignores ANSI
  color escape codes.
- **Multiple Targets**: Document multiple commands, subcommands, or binaries in
  a single `README.md`.

## ⚡ Quick Start

### 1. Tag Your `README.md`

Add HTML comment markers around the CLI output in your `README.md`:

<!-- CLI_README_START -->

```console
$ cli_readme --help
Test utility and CLI tool to ensure CLI usage in README files is up-to-date.

Usage: cli_readme [options]

-h, --help           Print this usage information.
    --[no-]check     Verify that README is up to date (default: true).
                     (defaults to on)
    --[no-]write     Write updated CLI help to README.
    --package-dir    Path to package directory (defaults to current directory).
    --readme         Path to README.md file (defaults to README.md in package root).
```

<!-- CLI_README_END -->

### 2. Add the Test

Create `test/ensure_cli_readme_test.dart`:

```dart
import 'package:cli_readme/cli_readme.dart';
import 'package:test/test.dart';

void main() {
  test('ensure_cli_readme', expectReadmeHelpClean);
}
```

### 3. Update Automatically

When you change your flags or help messages, update your `README.md` in one
command:

```bash
dart run cli_readme --write
```

## 🛠️ Advanced Usage

### In-Memory Parser (Zero Subprocess Latency)

For large test suites where spawning a Dart subprocess is undesirable, pass a
`CliTarget` with your `ArgParser`:

```dart
import 'package:args/args.dart';
import 'package:cli_readme/cli_readme.dart';
import 'package:my_package/src/options.dart';
import 'package:test/test.dart';

void main() {
  test('readme', () => expectReadmeHelpClean(
    targets: [
      CliTarget(
        id: 'main',
        commandName: 'my_tool',
        argParser: buildArgParser(),
        description: 'My awesome command line tool.',
      ),
    ],
  ));
}
```

### Multiple Binaries or Subcommands

Specify target IDs to map multiple sections in your `README.md`:

````markdown
### Server CLI

<!-- CLI_README_START server -->

```console
$ my_server --help
...
```

<!-- CLI_README_END server -->

### Client CLI

<!-- CLI_README_START client -->

```console
$ my_client --help
...
```

<!-- CLI_README_END client -->
````

```dart
test('readme', () => expectReadmeHelpClean(
  targets: [
    CliTarget.executable(id: 'server', executablePath: 'bin/server.dart', commandName: 'my_server'),
    CliTarget.executable(id: 'client', executablePath: 'bin/client.dart', commandName: 'my_client'),
  ],
));
```
