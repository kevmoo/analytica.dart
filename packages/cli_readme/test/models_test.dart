import 'package:checks/checks.dart';
import 'package:cli_readme/cli_readme.dart';
import 'package:cli_readme/src/discover.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

void main() {
  group('CliTarget.executable command name inference', () {
    test('infers command name from POSIX paths', () {
      check(
        CliTarget.executable(executablePath: 'bin/tool.dart').commandName,
      ).equals('tool');
      check(
        CliTarget.executable(
          executablePath: '/usr/local/pkg/bin/my_tool.dart',
        ).commandName,
      ).equals('my_tool');
    });

    test('infers command name from Windows and mixed-separator paths', () {
      check(
        CliTarget.executable(executablePath: r'bin\tool.dart').commandName,
      ).equals('tool');
      check(
        CliTarget.executable(
          executablePath: r'C:\workspace\pkg\bin\win_tool.dart',
        ).commandName,
      ).equals('win_tool');
      check(
        CliTarget.executable(
          executablePath: r'packages/pkg\bin\mixed_tool.dart',
        ).commandName,
      ).equals('mixed_tool');
    });

    test('preserves multi-dot stems when stripping .dart extension', () {
      check(
        CliTarget.executable(
          executablePath: 'bin/my.cool.tool.dart',
        ).commandName,
      ).equals('my.cool.tool');
      check(
        CliTarget.executable(
          executablePath: r'bin\my.cool.tool.dart',
        ).commandName,
      ).equals('my.cool.tool');
    });

    test('preserves non-.dart extensions and extensionless names', () {
      check(
        CliTarget.executable(executablePath: 'bin/tool.sh').commandName,
      ).equals('tool.sh');
      check(
        CliTarget.executable(executablePath: r'bin\tool.bat').commandName,
      ).equals('tool.bat');
      check(
        CliTarget.executable(executablePath: 'bin/tool.dart.js').commandName,
      ).equals('tool.dart.js');
      check(
        CliTarget.executable(executablePath: 'bin/tool').commandName,
      ).equals('tool');
    });

    test('handles bare names, dotfiles, and trailing separators', () {
      check(
        CliTarget.executable(executablePath: 'tool.dart').commandName,
      ).equals('tool');
      check(
        CliTarget.executable(executablePath: 'my.cool.tool.dart').commandName,
      ).equals('my.cool.tool');
      check(
        CliTarget.executable(executablePath: 'bin/.hidden.dart').commandName,
      ).equals('.hidden');
      check(
        CliTarget.executable(executablePath: 'bin/.dart').commandName,
      ).equals('.dart');
      check(
        CliTarget.executable(executablePath: 'bin/tool.dart/').commandName,
      ).equals('tool');
      check(
        CliTarget.executable(executablePath: r'bin\tool.dart\').commandName,
      ).equals('tool');
    });

    test('respects explicit commandName override', () {
      check(
        CliTarget.executable(
          executablePath: 'bin/internal_runner.dart',
          commandName: 'public_cli',
        ).commandName,
      ).equals('public_cli');
    });
  });

  group('PackageContext.discover bin directory scanning', () {
    test('ignores hidden .dart dotfile and non-Dart scripts in bin/', () async {
      await d.dir('bin_scan_pkg', [
        d.file('pubspec.yaml', 'name: bin_scan_pkg\n'),
        d.dir('bin', [
          d.file('.dart', 'ignored dotfile'),
          d.file('helper.sh', '#!/bin/sh'),
          d.file('actual_cli.dart', 'void main() {}'),
        ]),
        d.file('README.md', '# Docs\n'),
      ]).create();

      final context = PackageContext.discover(
        workingDir: d.path('bin_scan_pkg'),
      );
      check(context.defaultTargets).length.equals(1);
      check(context.defaultTargets.single.commandName).equals('bin_scan_pkg');
      check(
        context.defaultTargets.single.executablePath,
      ).equals(p.join('bin', 'actual_cli.dart'));
    });
  });
}
