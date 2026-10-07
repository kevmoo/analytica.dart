import 'dart:convert';
import 'dart:io';

import 'package:analytica/analytica.dart';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import '../complexity/git_diff_service.dart';
import 'shallow_analyzer.dart';

/// Executes the `shallow` single-caller helper scanner CLI with [args] and
/// returns the exit code.
Future<int> runShallowCli(
  List<String> args, {
  StringSink? out,
  StringSink? err,
}) async {
  final stdoutSink = out ?? stdout;
  final stderrSink = err ?? stderr;
  final parser = _buildArgParser();

  try {
    final argResults = parser.parse(args);
    if (argResults['help'] as bool) {
      _printUsage(parser, stdoutSink);
      return ExitCode.success.code;
    }
    return await _executeShallowScan(argResults, stdoutSink, stderrSink);
  } on FormatException catch (e) {
    stderrSink.writeln('Error: ${e.message}');
    _printUsage(parser, stderrSink);
    return ExitCode.usage.code;
  } on FileSystemException catch (e) {
    stderrSink.writeln('Error: ${e.message} (${e.path})');
    return ExitCode.usage.code;
  } catch (e) {
    stderrSink.writeln('Fatal error: $e');
    return 1;
  }
}

ArgParser _buildArgParser() => ArgParser()
  ..addFlag(
    'help',
    abbr: 'h',
    negatable: false,
    help: 'Print this usage information.',
  )
  ..addOption(
    'max-caller-cc',
    defaultsTo: '15',
    valueHelp: 'score',
    help:
        'Caller Cognitive Complexity ceiling after inlining. Below it a '
        'candidate is SAFE_INLINE; exactly on it is ZERO_HEADROOM.',
  )
  ..addOption(
    'max-params',
    defaultsTo: '5',
    valueHelp: 'count',
    help:
        'Parameter count threshold at or above which a single-caller function '
        'is flagged as HIGH_ARITY.',
  )
  ..addFlag(
    'only-safe',
    negatable: false,
    help:
        'Only output SAFE_INLINE candidates where inlining keeps caller '
        'complexity below --max-caller-cc.',
  )
  ..addOption(
    'git-diff',
    abbr: 'd',
    valueHelp: 'git-ref',
    help:
        'Git reference to compare against. Only reports shallow helpers in '
        'modified files.',
  )
  ..addFlag(
    'fail-on-safe-inline',
    negatable: false,
    help:
        'Exit with non-zero code if any SAFE_INLINE single-caller shallow '
        'helper is found.',
  )
  ..addOption(
    'format',
    defaultsTo: 'text',
    allowed: ['text', 'json'],
    help: 'Output format (text or json).',
  )
  ..addPathFilterOptions();

Future<int> _executeShallowScan(
  ArgResults argResults,
  StringSink out,
  StringSink err,
) async {
  final targets = argResults.rest.isEmpty ? ['lib'] : argResults.rest;
  final maxCallerCc = parseNonNegativeInt(
    argResults['max-caller-cc'] as String,
    'max-caller-cc',
  );
  final maxParams = parseNonNegativeInt(
    argResults['max-params'] as String,
    'max-params',
  );
  final onlySafe = argResults['only-safe'] as bool;
  final failOnSafeInline = argResults['fail-on-safe-inline'] as bool;
  final format = argResults['format'] as String;
  final gitDiffBase = argResults['git-diff'] as String?;
  final pathFilter = parsePathFilter(argResults);

  Set<String>? modifiedFilesFilter;
  if (gitDiffBase != null) {
    if (gitDiffBase.trim().isEmpty) {
      throw const FormatException('Git diff base reference cannot be empty.');
    }
    const gitService = GitDiffService();
    final repoRoot = await gitService.getRepoRoot();
    final mergeBase = await gitService.getMergeBase(gitDiffBase);
    final modified = await gitService.getModifiedDartFiles(mergeBase);
    modifiedFilesFilter = {
      for (final f in modified) ...[
        p.normalize(p.join(repoRoot, f)),
        p.normalize(p.relative(p.join(repoRoot, f))),
      ],
    };
  }

  final analyzer = ShallowAnalyzer(
    pathFilter: pathFilter,
    maxCallerScore: maxCallerCc,
    maxParams: maxParams,
  );
  final report = analyzer.analyzePaths(
    targets,
    modifiedFilesFilter: modifiedFilesFilter,
  );

  if (format == 'json') {
    out.writeln(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(report.toJson(onlySafe: onlySafe)),
    );
  } else {
    out.write(report.formatText(onlySafe: onlySafe));
  }

  if (failOnSafeInline && report.safeInlineCount > 0) {
    if (format == 'text') {
      err.writeln(
        '\nError: ${report.safeInlineCount} SAFE_INLINE shallow helper(s) '
        'detected (Caller CC < $maxCallerCc after inlining).',
      );
    }
    return 1;
  }

  return ExitCode.success.code;
}

void _printUsage(ArgParser parser, StringSink sink) {
  sink.writeln(
    'Dart Single-Caller Shallow Helper & Inlining Advisor (shallow)',
  );
  sink.writeln();
  sink.writeln(
    'Detects single-caller pass-through helpers, parameter clumps, and '
    'micro-helpers,',
  );
  sink.writeln(
    'and simulates exact caller Cognitive Complexity after re-inlining.',
  );
  sink.writeln();
  sink.writeln(
    'Usage: dart run cognitive_complexity:shallow [options] '
    '[file_or_directory...]',
  );
  sink.writeln();
  sink.writeln('Options:');
  sink.writeln(parser.usage);
}
