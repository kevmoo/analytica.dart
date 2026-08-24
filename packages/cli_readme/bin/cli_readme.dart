import 'dart:io';

import 'package:args/args.dart';
import 'package:cli_readme/cli_readme.dart';

Future<void> main(List<String> rawArgs) async {
  final parser = ArgParser()
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Print this usage information.',
    )
    ..addFlag(
      'check',
      defaultsTo: true,
      help: 'Verify that README is up to date (default: true).',
    )
    ..addFlag(
      'write',
      negatable: true,
      defaultsTo: false,
      help: 'Write updated CLI help to README.',
    )
    ..addOption(
      'package-dir',
      help: 'Path to package directory (defaults to current directory).',
    )
    ..addOption(
      'readme',
      help: 'Path to README.md file (defaults to README.md in package root).',
    );

  final ArgResults args;
  try {
    args = parser.parse(rawArgs);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln();
    stderr.writeln('Usage: cli_readme [options]');
    stderr.writeln(parser.usage);
    exit(64);
  }

  if (args['help'] as bool) {
    print(
      'Test utility and CLI tool to ensure CLI usage in README files is '
      'up-to-date.',
    );
    print('');
    print('Usage: cli_readme [options]');
    print('');
    print(parser.usage);
    exit(0);
  }

  final writeMode = args['write'] as bool;
  final pkgDir = args['package-dir'] as String?;
  final readmeOpt = args['readme'] as String?;

  final syncer = CliReadmeSync.discover(
    workingDir: pkgDir,
    readmePath: readmeOpt,
  );

  if (writeMode) {
    final result = await syncer.update();
    if (result.hasModifications) {
      print('Updated ${result.readmePath}.');
    } else {
      print('${result.readmePath} is already up to date.');
    }
    exit(0);
  }

  // Verification mode
  final result = await syncer.verify();
  if (result.isClean) {
    print('✅ ${result.readmePath} CLI usage documentation is up to date.');
    exit(0);
  }

  stderr.writeln('❌ ${result.readmePath} CLI documentation is out of date:');
  stderr.writeln();

  for (final targetResult in result.staleTargets) {
    final t = targetResult.target;
    stderr.writeln('=== Target: ${t.commandName} (id: "${t.id}") ===');
    if (targetResult.errorMessage != null) {
      stderr.writeln(targetResult.errorMessage);
    }
    if (targetResult.diff != null) {
      stderr.writeln(targetResult.diff);
    }
    stderr.writeln();
  }

  stderr.writeln('Run "dart run cli_readme --write" to update.');
  exit(1);
}
