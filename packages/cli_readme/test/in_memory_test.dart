import 'package:args/args.dart';
import 'package:checks/checks.dart';
import 'package:cli_readme/cli_readme.dart';
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

void main() {
  group('In-Memory ArgParser verification', () {
    test('passes when README is identical to ArgParser output', () async {
      final parser = ArgParser()
        ..addFlag('help', abbr: 'h', negatable: false, help: 'Print this help.')
        ..addOption(
          'port',
          abbr: 'p',
          defaultsTo: '8080',
          help: 'Port to bind.',
        );

      const expectedReadme = '''
# Server Package

<!-- CLI_README_START -->
```console
\$ my_server --help
Usage: my_server [options]

-h, --help    Print this help.
-p, --port    Port to bind.
              (defaults to "8080")
```
<!-- CLI_README_END -->
''';

      await d.dir('test_pkg', [
        d.file('pubspec.yaml', 'name: test_pkg\n'),
        d.file('README.md', expectedReadme),
      ]).create();

      final syncer = CliReadmeSync.discover(
        workingDir: d.path('test_pkg'),
        targets: [
          CliTarget.parser(commandName: 'my_server', argParser: parser),
        ],
      );

      final result = await syncer.verify();
      check(result.isClean).isTrue();
    });

    test('fails and reports diff when README options drift', () async {
      final parser = ArgParser()
        ..addFlag('help', abbr: 'h', negatable: false, help: 'Print this help.')
        ..addFlag(
          'verbose',
          abbr: 'v',
          negatable: false,
          help: 'Enable verbose logging.',
        );

      const staleReadme = '''
# My Tool

<!-- CLI_README_START -->
```console
\$ my_tool --help
Usage: my_tool [options]

-h, --help    Print this help.
```
<!-- CLI_README_END -->
''';

      await d.dir('drift_pkg', [
        d.file('pubspec.yaml', 'name: drift_pkg\n'),
        d.file('README.md', staleReadme),
      ]).create();

      final syncer = CliReadmeSync.discover(
        workingDir: d.path('drift_pkg'),
        targets: [CliTarget.parser(commandName: 'my_tool', argParser: parser)],
      );

      final result = await syncer.verify();
      check(result.isClean).isFalse();
      check(result.staleTargets).length.equals(1);
      final stale = result.staleTargets.first;
      check(stale.diff).isNotNull();
      check(stale.diff!).contains('+ -v, --verbose    Enable verbose logging.');
    });
  });
}
