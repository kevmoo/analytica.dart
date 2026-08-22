import 'dart:io';

import 'package:analytica/analytica.dart';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'engine.dart';
import 'formatters/github_reporter.dart';
import 'formatters/json_formatter.dart';
import 'formatters/markdown_formatter.dart';
import 'formatters/text_formatter.dart';
import 'models.dart';

/// Configures and builds the CLI [ArgParser] for `pkg:dedupe`.
ArgParser buildArgParser() {
  return ArgParser()
    ..addFormatOption(
      allowed: ['markdown', 'json', 'github', 'text'],
      defaultsTo: 'markdown',
      help:
          'Output formatting mode for stdout (json for agents/CI, markdown for '
          'humans).',
    )
    ..addOption(
      'json-output',
      valueHelp: 'path/to/report.json',
      help:
          'Write machine-readable JSON analysis report to the specified file '
          '(recommended for CI pipelines alongside human stdout).',
    )
    ..addOption(
      'min-tokens',
      abbr: 'k',
      defaultsTo: '40',
      help: 'Minimum token count for a reported duplicate block.',
    )
    ..addOption(
      'min-lines',
      abbr: 'l',
      defaultsTo: '4',
      help: 'Minimum line count for a reported duplicate block.',
    )
    ..addFlag(
      'ignore-comments',
      defaultsTo: true,
      negatable: true,
      help: 'Ignore single-line and doc comments when comparing tokens.',
    )
    ..addFlag(
      'ignore-literals',
      defaultsTo: true,
      negatable: true,
      help:
          'Normalize string and numeric literals to detect structural clones.',
    )
    ..addFlag(
      'ignore-identifiers',
      defaultsTo: false,
      negatable: true,
      help:
          'Normalize variable and type identifiers to detect parameterized '
          'clones.',
    )
    ..addOption(
      'category',
      defaultsTo: 'all',
      allowed: ['all', 'logic', 'data', 'boilerplate'],
      help: 'Filter displayed clusters by category.',
    )
    ..addOption(
      'bucket',
      defaultsTo: 'all',
      allowed: ['all', 'identical', 'structural', 'parameterized'],
      help: 'Filter displayed clusters by match bucket.',
    )
    ..addOption(
      'top',
      defaultsTo: '0',
      help: 'Limit number of top duplicate clusters to display (0 for all).',
    )
    ..addOption(
      'fail-threshold',
      valueHelp: 'percentage',
      help:
          'Exit with non-zero code (1) if overall duplication percentage (or '
          'diff duplication percentage when --git-diff is set) exceeds this '
          'ceiling.',
    )
    ..addOption(
      'git-diff',
      abbr: 'd',
      valueHelp: 'git-ref',
      help:
          'Git reference (e.g. origin/main or HEAD~1) to compare against '
          'for PR/CL delta evaluation.',
    )
    ..addFlag(
      'only-changed',
      defaultsTo: false,
      negatable: true,
      help:
          'Only report duplicate clusters that intersect modified lines in '
          'the Git diff.',
    )
    ..addOption(
      'exclude',
      valueHelp: 'pattern1,pattern2',
      help: 'Comma-separated glob/wildcard patterns of files to exclude.',
    )
    ..addOption(
      'include',
      valueHelp: 'pattern1,pattern2',
      help: 'Comma-separated glob/wildcard patterns of files to include.',
    )
    ..addFlag(
      'files',
      defaultsTo: true,
      negatable: true,
      help: 'Include per-file duplication metrics table in report.',
    )
    ..addFlag(
      'clusters',
      defaultsTo: true,
      negatable: true,
      help: 'Include duplicate clusters list in report.',
    )
    ..addSdkPathOption()
    ..addHelpFlag()
    ..addVersionFlag(help: 'Print dedupe version.');
}

/// Main CLI runner for `pkg:dedupe`.
class DedupeCliRunner {
  final ArgParser parser;
  final IOSink outSink;
  final IOSink errSink;

  DedupeCliRunner({ArgParser? parser, IOSink? outSink, IOSink? errSink})
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
      errSink.writeln('Usage: dedupe [options] [target_path]');
      errSink.writeln(parser.usage);
      return ExitCode.usage.code;
    }

    if (results.flag('help')) {
      outSink.writeln(
        'dedupe - High-performance code duplication and clone detection '
        'engine for Dart.',
      );
      outSink.writeln();
      outSink.writeln('Usage: dedupe [options] [target_path]');
      outSink.writeln();
      outSink.writeln(parser.usage);
      return ExitCode.success.code;
    }

    if (results.flag('version')) {
      outSink.writeln('dedupe version: $dedupeVersion');
      return ExitCode.success.code;
    }

    final targetPath = results.rest.isNotEmpty ? results.rest.first : '.';
    final normalizedPath = p.normalize(p.absolute(targetPath));

    final targetDir = Directory(normalizedPath);
    if (!targetDir.existsSync() && !File(normalizedPath).existsSync()) {
      errSink.writeln('Error: Target path does not exist: $targetPath');
      return ExitCode.noInput.code;
    }

    final format = OutputFormat.fromString(results.option('format')!);
    final minTokens = parseNonNegativeInt(
      results.option('min-tokens') ?? '40',
      'min-tokens',
    );
    final minLines = parseNonNegativeInt(
      results.option('min-lines') ?? '4',
      'min-lines',
    );
    final ignoreComments = results.flag('ignore-comments');
    final ignoreLiterals = results.flag('ignore-literals');
    final ignoreIdentifiers = results.flag('ignore-identifiers');
    final categoryFilter = results.option('category') ?? 'all';
    final bucketFilter = results.option('bucket') ?? 'all';
    final top = parseNonNegativeInt(results.option('top') ?? '0', 'top');

    double? failThreshold;
    if (results.option('fail-threshold') != null) {
      final parsed = double.tryParse(results.option('fail-threshold')!);
      if (parsed == null || parsed < 0) {
        errSink.writeln(
          'Error: Invalid fail-threshold: ${results.option('fail-threshold')}. '
          'Must be a non-negative number.',
        );
        return ExitCode.usage.code;
      }
      failThreshold = parsed;
    }

    final gitDiffBase = results.option('git-diff');
    final onlyChanged = results.flag('only-changed');
    final jsonOutputPath = results.option('json-output');
    final sdkPath = results.option('sdk-path');
    final includeFileTable = results.flag('files');
    final includeClusters = results.flag('clusters');

    final excludeList = _parseCommaSeparated(results.option('exclude'));
    final includeList = _parseCommaSeparated(results.option('include'));

    final options = DedupeOptions(
      targetPath: normalizedPath,
      targets: results.rest.isNotEmpty ? results.rest : const ['lib'],
      minTokens: minTokens,
      minLines: minLines,
      ignoreComments: ignoreComments,
      ignoreLiterals: ignoreLiterals,
      ignoreIdentifiers: ignoreIdentifiers,
      excludePatterns: [
        if (excludeList.isNotEmpty) ...excludeList,
        if (excludeList.isEmpty) ...const [
          '**/*.g.dart',
          '**/*.freezed.dart',
          '**/*.pb.dart',
          '**/*.pbjson.dart',
          '**/*.pbenum.dart',
          '**/*.pbserver.dart',
        ],
      ],
      includePatterns: includeList.isNotEmpty
          ? includeList
          : const ['**/*.dart'],
      gitDiffBase: gitDiffBase,
      onlyChanged: onlyChanged,
      failThreshold: failThreshold,
      top: top,
      categoryFilter: categoryFilter,
      bucketFilter: bucketFilter,
      format: format,
      jsonOutputPath: jsonOutputPath,
      sdkPath: sdkPath,
      includeFileTable: includeFileTable,
      includeClusters: includeClusters,
    );

    try {
      final engine = DedupeEngine(options);
      final report = await engine.analyze();

      if (jsonOutputPath != null) {
        final jsonOutput = const JsonFormatter().format(report);
        final file = File(jsonOutputPath);
        file.parent.createSync(recursive: true);
        file.writeAsStringSync('$jsonOutput\n');
      }

      switch (format) {
        case OutputFormat.json:
          outSink.writeln(const JsonFormatter().format(report));
        case OutputFormat.markdown:
          final mdFormatter = MarkdownFormatter(
            topCount: top,
            categoryFilter: categoryFilter,
            bucketFilter: bucketFilter,
            includeFileTable: includeFileTable,
            includeClusters: includeClusters,
          );
          outSink.writeln(mdFormatter.format(report));
        case OutputFormat.github:
          final reporter = DedupeGitHubReporter(stdoutSink: outSink);
          reporter.report(report);
        case OutputFormat.text:
          final txtFormatter = TextFormatter(
            topCount: top,
            categoryFilter: categoryFilter,
            bucketFilter: bucketFilter,
          );
          outSink.writeln(txtFormatter.format(report));
      }

      if (failThreshold != null) {
        final effectivePercentage =
            report.summary.diffDuplicationPercentage ??
            report.summary.duplicationPercentage;

        if (effectivePercentage > failThreshold) {
          final effectiveStr = effectivePercentage.toStringAsFixed(1);
          final thresholdStr = failThreshold.toStringAsFixed(1);
          errSink.writeln(
            '\nError: Duplication threshold exceeded: '
            '$effectiveStr% > $thresholdStr%',
          );
          return 1;
        }
      }

      return ExitCode.success.code;
    } on FileSystemException catch (e) {
      errSink.writeln('File System Error: ${e.message} (${e.path})');
      return ExitCode.noInput.code;
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
