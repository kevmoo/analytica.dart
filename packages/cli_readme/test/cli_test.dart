import 'dart:io';

import 'package:analytica/testing.dart';
import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;
import 'package:test_process/test_process.dart';

void main() {
  late String binPath;

  setUpAll(() async {
    binPath = await resolvePackageExecutable(
      'package:cli_readme/cli_readme.dart',
    );
  });

  test('CLI --help prints usage and exits 0', () async {
    final proc = await TestProcess.start(Platform.resolvedExecutable, [
      binPath,
      '--help',
    ]);

    final stdout = await proc.stdoutStream().join('\n');
    await proc.shouldExit(0);

    check(stdout).contains('Usage: cli_readme [options]');
    check(stdout).contains('--[no-]write');
    check(stdout).contains('--[no-]check');
  });

  test('CLI --write updates README in target package', () async {
    await d.dir('cli_pkg', [
      d.file('pubspec.yaml', 'name: cli_pkg\nexecutables:\n  cli_pkg:\n'),
      d.dir('bin', [
        d.file('cli_pkg.dart', '''
void main(List<String> args) {
  print('Usage: cli_pkg [options]\\n\\n--special    Special flag.');
}
'''),
      ]),
      d.file('README.md', '''
# CLI Pkg

<!-- CLI_README_START -->
OLD DOCS
<!-- CLI_README_END -->
'''),
    ]).create();

    final proc = await TestProcess.start(Platform.resolvedExecutable, [
      binPath,
      '--write',
      '--package-dir',
      d.path('cli_pkg'),
    ]);

    await proc.shouldExit(0);

    final readme = File(
      p.join(d.path('cli_pkg'), 'README.md'),
    ).readAsStringSync();
    check(readme).contains('--special    Special flag.');
    check(readme).contains('```console');
  });
}
