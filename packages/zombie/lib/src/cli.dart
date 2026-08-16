import 'dart:io';

import 'package:analytica/analytica.dart';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'formatters/json_formatter.dart';
import 'formatters/markdown_formatter.dart';
import 'models.dart';
import 'reachability_engine.dart';

const String zombieVersion = '0.1.0-dev';

/// Configures and parses CLI arguments for `pkg:zombie`.
ArgParser buildArgParser() {
  return ArgParser()
    ..addFormatOption(
      allowed: ['markdown', 'json', 'github'],
      defaultsTo: 'markdown',
      help:
          'Output formatting mode for stdout (json for agents/CI, markdown for humans).',
    )
    ..addOption(
      'json-output',
      valueHelp: 'path/to/report.json',
      help:
          'Write machine-readable JSON analysis report to the specified file '
          '(recommended for agents and CI pipelines alongside human stdout).',
    )
    ..addOption(
      'example-mode',
      help: 'How code in example/ is treated during reachability analysis.',
      allowed: ['demonstration', 'strict', 'skip'],
      defaultsTo: 'demonstration',
    )
    ..addOption(
      'mode',
      abbr: 'm',
      help: 'Package analysis mode.',
      allowed: ['library', 'closedApp'],
      defaultsTo: 'library',
    )
    ..addFlag(
      'include-generated',
      help: 'Include generated files (*.g.dart, *.freezed.dart) in analysis.',
      defaultsTo: false,
    )
    ..addFlag(
      'fail-on-zombies',
      help:
          'Exit with non-zero code (1) if any zombie declaration is detected.',
      defaultsTo: false,
    )
    ..addOption(
      'test-support-patterns',
      help:
          'Comma-separated naming wildcard patterns for test fixtures and '
          'hooks.',
      defaultsTo: 'Fake*,Mock*',
    )
    ..addOption(
      'ignore-name-patterns',
      help:
          'Comma-separated naming wildcard patterns for declaration names to '
          'ignore.',
      defaultsTo: '',
    )
    ..addOption(
      'extra-roots',
      valueHelp: 'dir1,dir2',
      help:
          'Comma-separated list of additional root/test directories or '
          'companion packages to include in reachability analysis.',
      defaultsTo: '',
    )
    ..addFlag(
      'ignore-external-interop',
      help:
          'Ignore unreferenced external JavaScript and Wasm interop '
          'declarations.',
      defaultsTo: false,
    )
    ..addSdkPathOption()
    ..addFlag(
      'pub-get',
      negatable: false,
      help:
          'Automatically run "dart pub get" (or "flutter pub get") if '
          'dependencies are unresolved.',
    )
    ..addHelpFlag()
    ..addVersionFlag(help: 'Print zombie version.');
}

/// Main CLI runner for `pkg:zombie`.
class ZombieCliRunner {
  final ArgParser parser;
  final IOSink outSink;
  final IOSink errSink;

  ZombieCliRunner({ArgParser? parser, IOSink? outSink, IOSink? errSink})
    : parser = parser ?? buildArgParser(),
      outSink = outSink ?? stdout,
      errSink = errSink ?? stderr;

  Future<int> run(List<String> args) async {
    final ArgResults results;
    try {
      results = parser.parse(args);
    } on FormatException catch (e) {
      errSink.writeln('Error: ${e.message}');
      errSink.writeln();
      errSink.writeln('Usage: zombie [options] [target_path]');
      errSink.writeln(parser.usage);
      return ExitCode.usage.code;
    }

    if (results.flag('help')) {
      outSink.writeln(
        'zombie - Reachability and dead declaration analysis for Dart '
        'packages.',
      );
      outSink.writeln();
      outSink.writeln('Usage: zombie [options] [target_path]');
      outSink.writeln();
      outSink.writeln(parser.usage);
      return ExitCode.success.code;
    }

    if (results.flag('version')) {
      outSink.writeln('zombie version: $zombieVersion');
      return ExitCode.success.code;
    }

    final targetPath = results.rest.isNotEmpty ? results.rest.first : '.';
    final normalizedPath = p.normalize(p.absolute(targetPath));

    final targetDir = Directory(normalizedPath);
    if (!targetDir.existsSync()) {
      errSink.writeln('Error: Target directory does not exist: $targetPath');
      return ExitCode.noInput.code;
    }

    final pubspec = File(p.join(normalizedPath, 'pubspec.yaml'));
    if (!pubspec.existsSync()) {
      errSink.writeln(
        'Error: No pubspec.yaml found in target directory: $targetPath',
      );
      return ExitCode.noInput.code;
    }

    final format = OutputFormat.fromString(results.option('format')!);
    final exampleMode = ExampleMode.fromString(results.option('example-mode')!);
    final mode = AnalysisMode.fromString(results.option('mode')!);
    final includeGenerated = results.flag('include-generated');
    final failOnZombies = results.flag('fail-on-zombies');
    final autoPubGet = results.flag('pub-get');
    final ignoreExternalInterop = results.flag('ignore-external-interop');
    final sdkPath = results.option('sdk-path');
    final jsonOutputPath = results.option('json-output');
    final testSupportPatterns = _parseCommaSeparated(
      results.option('test-support-patterns'),
    );
    final ignoreNamePatterns = _parseCommaSeparated(
      results.option('ignore-name-patterns'),
    );
    final extraRoots = _parseCommaSeparated(results.option('extra-roots'));

    final options = ZombieOptions(
      packagePath: normalizedPath,
      format: format,
      exampleMode: exampleMode,
      mode: mode,
      includeGenerated: includeGenerated,
      failOnZombies: failOnZombies,
      autoPubGet: autoPubGet,
      ignoreExternalInterop: ignoreExternalInterop,
      sdkPath: sdkPath,
      jsonOutputPath: jsonOutputPath,
      testSupportPatterns: testSupportPatterns,
      ignoreNamePatterns: ignoreNamePatterns,
      extraRoots: extraRoots,
    );

    try {
      final engine = ZombieEngine(options);
      final report = await engine.analyze();

      if (jsonOutputPath != null) {
        final jsonOutput = const JsonFormatter().format(report);
        final file = File(jsonOutputPath);
        file.parent.createSync(recursive: true);
        file.writeAsStringSync('$jsonOutput\n');
      }

      final output = switch (format) {
        OutputFormat.json => const JsonFormatter().format(report),
        OutputFormat.markdown => const MarkdownFormatter().format(report),
      };

      outSink.writeln(output);

      if (failOnZombies && report.zombies.isNotEmpty) {
        return 1;
      }

      return ExitCode.success.code;
    } on PackageResolutionException catch (e) {
      errSink.writeln('Resolution Error: ${e.message}');
      return ExitCode.config.code;
    } on SdkDiscoveryException catch (e) {
      errSink.writeln('SDK Error: ${e.message}');
      return ExitCode.unavailable.code;
    } catch (e, stack) {
      errSink.writeln('Analysis error: $e');
      errSink.writeln(stack);
      return ExitCode.software.code;
    }
  }
}

List<String> _parseCommaSeparated(String? value) {
  if (value == null || value.trim().isEmpty) return const [];
  return value
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
}
