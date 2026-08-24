import 'dart:io';

import 'package:args/args.dart';
import 'package:checks/checks.dart';
import 'package:cli_readme/cli_readme.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

void main() {
  group('CliReadmeSync.update', () {
    test('updates stale README in-place when requested', () async {
      final parser = ArgParser()
        ..addFlag('help', abbr: 'h', negatable: false, help: 'Print this help.')
        ..addOption('config', abbr: 'c', help: 'Path to config file.');

      const staleReadme = '''
# Application

<!-- CLI_README_START -->
```console
\$ app --help
Usage: app [options]

-h, --help    Old help text.
```
<!-- CLI_README_END -->
''';

      await d.dir('update_pkg', [
        d.file('pubspec.yaml', 'name: app\n'),
        d.file('README.md', staleReadme),
      ]).create();

      final syncer = CliReadmeSync.discover(
        workingDir: d.path('update_pkg'),
        targets: [CliTarget.parser(commandName: 'app', argParser: parser)],
      );

      final result = await syncer.update();
      check(result.hasModifications).isTrue();

      final updatedFile = File(p.join(d.path('update_pkg'), 'README.md'));
      final updatedContent = updatedFile.readAsStringSync();

      check(updatedContent).contains('-c, --config    Path to config file.');
      check(updatedContent).contains('-h, --help      Print this help.');

      // Re-verifying should now pass cleanly
      final reVerify = await syncer.verify();
      check(reVerify.isClean).isTrue();
    });
  });

  group('expectReadmeHelpClean', () {
    test('succeeds on clean README', () async {
      final parser = ArgParser()
        ..addFlag('help', abbr: 'h', negatable: false, help: 'Help.');

      const cleanReadme = '''
# Clean

<!-- CLI_README_START -->
```console
\$ clean --help
Usage: clean [options]

-h, --help    Help.
```
<!-- CLI_README_END -->
''';

      await d.dir('clean_pkg', [
        d.file('pubspec.yaml', 'name: clean\n'),
        d.file('README.md', cleanReadme),
      ]).create();

      await expectReadmeHelpClean(
        packageRelativeDirectory: d.path('clean_pkg'),
        targets: [CliTarget.parser(commandName: 'clean', argParser: parser)],
      );
    });

    test('throws TestFailure on stale README', () async {
      final parser = ArgParser()
        ..addFlag('help', abbr: 'h', negatable: false, help: 'New Help.');

      const staleReadme = '''
# Stale

<!-- CLI_README_START -->
```console
\$ stale --help
Usage: stale [options]

-h, --help    Old Help.
```
<!-- CLI_README_END -->
''';

      await d.dir('stale_pkg', [
        d.file('pubspec.yaml', 'name: stale\n'),
        d.file('README.md', staleReadme),
      ]).create();

      expect(
        () => expectReadmeHelpClean(
          packageRelativeDirectory: d.path('stale_pkg'),
          targets: [CliTarget.parser(commandName: 'stale', argParser: parser)],
        ),
        throwsA(isA<TestFailure>()),
      );
    });
  });
}
