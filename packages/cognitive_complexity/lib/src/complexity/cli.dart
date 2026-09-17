import 'dart:convert';
import 'dart:io';
import 'package:analytica/analytica.dart';
import 'package:args/args.dart';
import 'complexity_analyzer.dart';
import 'delta_analyzer.dart';
import 'github_reporter.dart';

/// Executes the Cognitive Complexity CLI with [args] and returns the exit
/// code.
Future<int> runCli(
  List<String> args, {
  StringSink? out,
  StringSink? err,
}) async {
  final stdoutSink = out ?? stdout;
  final stderrSink = err ?? stderr;

  // Under GitHub Actions, the process is compiled/run from the action's folder.
  // We re-align Directory.current to GITHUB_WORKSPACE so target scanning paths
  // and git commands resolve against the user's project workspace repository.
  final workspace = Platform.environment['GITHUB_WORKSPACE'];
  if (workspace != null && workspace.isNotEmpty) {
    Directory.current = workspace;
  }

  final parser = ArgParser()
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Print this usage information.',
    )
    ..addOption(
      'threshold',
      abbr: 't',
      defaultsTo: '0',
      help: 'Minimum complexity score to include in output.',
    )
    ..addOption(
      'fail-threshold',
      abbr: 'f',
      help: 'Exit with non-zero code if any function score exceeds this value.',
    )
    ..addOption(
      'max-file-lines',
      valueHelp: 'lines',
      help:
          'Opt-in maximum physical line count per source file (0 = disabled). '
          'Exits with non-zero code when exceeded.',
    )
    ..addOption(
      'max-function-lines',
      valueHelp: 'lines',
      help:
          'Opt-in maximum line span per function/method declaration '
          '(0 = disabled). Exits with non-zero code when exceeded.',
    )
    ..addOption(
      'git-diff',
      abbr: 'd',
      valueHelp: 'git-ref',
      help:
          'Git reference to compare against. Only evaluates modified '
          'files and function complexity deltas.',
    )
    ..addFlag(
      'fail-on-increase',
      negatable: false,
      help:
          'When using --git-diff, exit with non-zero code if any function '
          'increased in complexity. When --fail-threshold is also set, only '
          'increases that exceed the threshold fail.',
    )
    ..addOption(
      'format',
      defaultsTo: 'text',
      allowed: ['text', 'json', 'github'],
      help: 'Output format.',
    )
    ..addOption(
      'comment-output',
      valueHelp: 'path',
      help:
          'With --format=github, also write a standalone report to this path, '
          'ordered by significance and capped by --max-comment-rows. Intended '
          'for posting as a PR comment while the step summary keeps the full '
          'table.',
    )
    ..addOption(
      'max-comment-rows',
      defaultsTo: '0',
      valueHelp: 'count',
      help:
          'Maximum table rows in --comment-output (0 = unlimited). GitHub '
          'rejects comment bodies over 65536 characters.',
    )
    ..addPathFilterOptions();

  try {
    final argResults = parser.parse(args);

    if (argResults['help'] as bool) {
      _printUsage(parser, stdoutSink);
      return ExitCode.success.code;
    }

    final targets = argResults.rest.isEmpty ? ['lib'] : argResults.rest;
    final threshold = parseNonNegativeInt(
      argResults['threshold'] as String,
      'threshold',
    );
    int? failThreshold;
    if (argResults['fail-threshold'] != null) {
      failThreshold = parseNonNegativeInt(
        argResults['fail-threshold'] as String,
        'fail-threshold',
      );
    }

    final maxFileLines = _parseOptInPositiveInt(
      argResults['max-file-lines'] as String?,
      'max-file-lines',
    );
    final maxFunctionLines = _parseOptInPositiveInt(
      argResults['max-function-lines'] as String?,
      'max-function-lines',
    );

    final format = argResults['format'] as String;
    final gitDiffBase = argResults['git-diff'] as String?;
    final failOnIncrease = argResults['fail-on-increase'] as bool;
    final commentOutput = argResults['comment-output'] as String?;
    final maxCommentRows = parseNonNegativeInt(
      argResults['max-comment-rows'] as String,
      'max-comment-rows',
    );
    final pathFilter = parsePathFilter(argResults);

    _warnIgnoredFlags(
      failOnIncrease: failOnIncrease,
      commentOutput: commentOutput,
      format: format,
      gitDiffBase: gitDiffBase,
      err: stderrSink,
    );

    if (gitDiffBase != null) {
      if (gitDiffBase.trim().isEmpty) {
        throw const FormatException('Git diff base reference cannot be empty.');
      }
      return await _handleDiffMode(
        gitDiffBase: gitDiffBase,
        targets: targets,
        pathFilter: pathFilter,
        format: format,
        failThreshold: failThreshold,
        maxFileLines: maxFileLines,
        maxFunctionLines: maxFunctionLines,
        failOnIncrease: failOnIncrease,
        commentOutput: commentOutput,
        maxCommentRows: maxCommentRows,
        out: stdoutSink,
        err: stderrSink,
      );
    }

    return _handleRegularMode(
      targets: targets,
      pathFilter: pathFilter,
      threshold: threshold,
      failThreshold: failThreshold,
      maxFileLines: maxFileLines,
      maxFunctionLines: maxFunctionLines,
      format: format,
      out: stdoutSink,
      err: stderrSink,
    );
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

int? _parseOptInPositiveInt(String? raw, String flagName) {
  if (raw == null || raw.trim().isEmpty) return null;
  final parsed = parseNonNegativeInt(raw, flagName);
  return parsed == 0 ? null : parsed;
}

/// Warns about flags that are silently ignored in the current mode.
void _warnIgnoredFlags({
  required bool failOnIncrease,
  required String? commentOutput,
  required String format,
  required String? gitDiffBase,
  required StringSink err,
}) {
  if (failOnIncrease && gitDiffBase == null) {
    err.writeln(
      'Warning: --fail-on-increase has no effect unless --git-diff is '
      'specified.',
    );
  }

  if (commentOutput != null && (format != 'github' || gitDiffBase == null)) {
    err.writeln(
      'Warning: --comment-output has no effect unless --format=github '
      'and --git-diff are both set.',
    );
  }
}

Future<int> _handleDiffMode({
  required String gitDiffBase,
  required List<String> targets,
  required PathFilter pathFilter,
  required String format,
  required int? failThreshold,
  required int? maxFileLines,
  required int? maxFunctionLines,
  required bool failOnIncrease,
  required StringSink out,
  required StringSink err,
  String? commentOutput,
  int maxCommentRows = 0,
}) async {
  final deltaAnalyzer = DeltaAnalyzer(pathFilter: pathFilter);
  final summary = await deltaAnalyzer.computeDeltas(
    gitDiffBase,
    targetPaths: targets,
  );

  if (format == 'json') {
    out.writeln(
      jsonEncode(
        summary.toJson(
          failThreshold: failThreshold,
          maxFileLines: maxFileLines,
          maxFunctionLines: maxFunctionLines,
          failOnIncrease: failOnIncrease,
        ),
      ),
    );
  } else if (format == 'github') {
    final reporter = GitHubReporter(
      stdoutSink: out,
      summaryFile: resolveGitHubSummaryFile(),
      commentFile: commentOutput == null ? null : File(commentOutput),
      maxCommentRows: maxCommentRows,
    );
    reporter.printReport(
      deltaSummary: summary,
      failThreshold: failThreshold,
      maxFileLines: maxFileLines,
      maxFunctionLines: maxFunctionLines,
      failOnIncrease: failOnIncrease,
    );
  } else {
    _printDeltaTextReport(
      summary,
      out,
      failThreshold,
      maxFileLines,
      maxFunctionLines,
      failOnIncrease,
    );
  }

  final violations = summary.countViolations(
    failThreshold: failThreshold,
    maxFileLines: maxFileLines,
    maxFunctionLines: maxFunctionLines,
    failOnIncrease: failOnIncrease,
  );
  if (violations > 0) {
    if (format == 'text') {
      err.writeln(
        '\nError: $violations declaration(s) or file(s) triggered complexity '
        'or line-length threshold violations.',
      );
    }
    return 1;
  }

  return ExitCode.success.code;
}

int _handleRegularMode({
  required List<String> targets,
  required PathFilter pathFilter,
  required int threshold,
  required int? failThreshold,
  required int? maxFileLines,
  required int? maxFunctionLines,
  required String format,
  required StringSink out,
  required StringSink err,
}) {
  final analyzer = ComplexityAnalyzer(pathFilter: pathFilter);
  final allResults = <FunctionComplexity>[];
  final fileMetrics = <FileLineMetric>[];

  for (final target in targets) {
    allResults.addAll(analyzer.analyzePath(target));
    if (maxFileLines != null) {
      fileMetrics.addAll(analyzer.analyzePathFileLines(target));
    }
  }

  allResults.sort((a, b) => b.score.compareTo(a.score));
  final displayed = allResults
      .where(
        (r) =>
            r.score >= threshold ||
            (maxFunctionLines != null && r.lineCount > maxFunctionLines),
      )
      .toList();

  if (format == 'json') {
    out.writeln(jsonEncode(displayed.map((e) => e.toJson()).toList()));
  } else if (format == 'github') {
    final reporter = GitHubReporter(
      stdoutSink: out,
      summaryFile: resolveGitHubSummaryFile(),
    );
    reporter.printReport(
      regularResults: displayed,
      fileMetrics: fileMetrics,
      failThreshold: failThreshold,
      maxFileLines: maxFileLines,
      maxFunctionLines: maxFunctionLines,
    );
  } else {
    _printTextReport(
      displayed,
      fileMetrics,
      threshold,
      out,
      failThreshold,
      maxFileLines,
      maxFunctionLines,
    );
  }

  final hasDeclVio = allResults.any(
    (r) => r.isViolation(
      failThreshold: failThreshold,
      maxFunctionLines: maxFunctionLines,
    ),
  );
  final hasFileVio =
      maxFileLines != null &&
      fileMetrics.any((f) => f.isViolation(maxFileLines: maxFileLines));

  if (hasDeclVio || hasFileVio) {
    if (format == 'text') {
      err.writeln(_formatRegularError(failThreshold));
    }
    return 1;
  }

  return ExitCode.success.code;
}

String _formatRegularError(int? failThreshold) => failThreshold != null
    ? '\nError: One or more functions exceeded the failure threshold '
          '($failThreshold).'
    : '\nError: One or more declarations or files exceeded the configured '
          'line limit.';

void _printUsage(ArgParser parser, StringSink sink) {
  sink.writeln('Dart & Flutter Cognitive Complexity Calculator');
  sink.writeln();
  sink.writeln(
    'Usage: dart run cognitive_complexity [options] <file_or_directory>',
  );
  sink.writeln();
  sink.writeln('Options:');
  sink.writeln(parser.usage);
}

void _printTextReport(
  List<FunctionComplexity> results,
  List<FileLineMetric> fileMetrics,
  int threshold,
  StringSink sink,
  int? failThreshold,
  int? maxFileLines,
  int? maxFunctionLines,
) {
  final violatedFiles = maxFileLines != null
      ? fileMetrics
            .where((f) => f.isViolation(maxFileLines: maxFileLines))
            .toList()
      : const <FileLineMetric>[];

  if (results.isEmpty && violatedFiles.isEmpty) {
    final msg = threshold > 0
        ? 'No declarations found with cognitive complexity >= $threshold.'
        : 'No Dart declarations analyzed.';
    sink.writeln(msg);
    return;
  }

  if (results.isNotEmpty) {
    _printRegularDeclRows(results, failThreshold, maxFunctionLines, sink);
  }
  if (violatedFiles.isNotEmpty) {
    _printRegularFileViolationRows(violatedFiles, maxFileLines!, sink);
  }
}

void _printRegularDeclRows(
  List<FunctionComplexity> results,
  int? failThreshold,
  int? maxFunctionLines,
  StringSink sink,
) {
  var maxNameLen = 'Declaration'.length;
  for (final res in results) {
    if (res.name.length > maxNameLen) maxNameLen = res.name.length;
  }

  final headerScore = 'Score'.padLeft(5);
  final headerName = 'Declaration'.padRight(maxNameLen);
  sink.writeln('$headerScore  $headerName  Location');
  sink.writeln('-' * (5 + 2 + maxNameLen + 2 + 30));

  for (final res in results) {
    final scoreStr = res.score.toString().padLeft(5);
    final nameStr = res.name.padRight(maxNameLen);
    final locStr = '${res.filePath}:L${res.startLine}-${res.endLine}';
    final isVio = res.isViolation(
      failThreshold: failThreshold,
      maxFunctionLines: maxFunctionLines,
    );
    final violationMarker = isVio ? ' [VIOLATION]' : '';
    sink.writeln('$scoreStr  $nameStr  $locStr$violationMarker');
  }
}

void _printRegularFileViolationRows(
  List<FileLineMetric> violatedFiles,
  int maxFileLines,
  StringSink sink,
) {
  sink.writeln();
  sink.writeln('File Line Violations (> $maxFileLines lines):');
  for (final f in violatedFiles) {
    final countStr = f.lineCount.toString().padLeft(5);
    sink.writeln('  $countStr lines  ${f.filePath} [VIOLATION]');
  }
}

void _printDeltaTextReport(
  DeltaSummary summary,
  StringSink sink,
  int? failThreshold,
  int? maxFileLines,
  int? maxFunctionLines,
  bool failOnIncrease,
) {
  final deltas = summary.deltas.where(
    (d) =>
        d.status != DeltaStatus.unchanged ||
        d.isFunctionLineViolation(
          maxFunctionLines: maxFunctionLines,
          failOnIncrease: failOnIncrease,
        ),
  );
  final violatedFiles = maxFileLines != null
      ? summary.fileDeltas
            .where(
              (f) => f.isViolation(
                maxFileLines: maxFileLines,
                failOnIncrease: failOnIncrease,
              ),
            )
            .toList()
      : const <FileLineDelta>[];

  if (deltas.isEmpty && violatedFiles.isEmpty) {
    sink.writeln('No modified or newly added Dart declarations detected.');
    return;
  }

  if (deltas.isNotEmpty) {
    _printDeltaTableSection(
      deltas,
      failThreshold,
      maxFunctionLines,
      failOnIncrease,
      sink,
    );
  }
  if (violatedFiles.isNotEmpty) {
    _printDeltaFileViolations(violatedFiles, maxFileLines!, sink);
  }

  final violations = summary.countViolations(
    failThreshold: failThreshold,
    maxFileLines: maxFileLines,
    maxFunctionLines: maxFunctionLines,
    failOnIncrease: failOnIncrease,
  );
  sink.writeln(
    'Summary: ${summary.countAdded} added, ${summary.countIncreased} '
    'increased, ${summary.countImproved} improved '
    '(Net Delta: ${summary.netDelta} | Violations: $violations)',
  );
}

void _printDeltaTableSection(
  Iterable<ComplexityDelta> deltas,
  int? failThreshold,
  int? maxFunctionLines,
  bool failOnIncrease,
  StringSink sink,
) {
  var maxName = 'Declaration'.length;
  for (final d in deltas) {
    if (d.name.length > maxName) maxName = d.name.length;
  }

  final hdrDelta = 'Delta'.padLeft(6);
  final hdrScore = 'Score'.padRight(10);
  final hdrName = 'Declaration'.padRight(maxName);
  sink.writeln('$hdrDelta  $hdrScore  $hdrName  Location');
  sink.writeln('-' * (6 + 2 + 10 + 2 + maxName + 2 + 30));

  _printDeltaRows(
    deltas,
    maxName,
    failThreshold,
    maxFunctionLines,
    failOnIncrease,
    sink,
  );

  sink.writeln('-' * (6 + 2 + 10 + 2 + maxName + 2 + 30));
}

void _printDeltaFileViolations(
  List<FileLineDelta> violatedFiles,
  int maxFileLines,
  StringSink sink,
) {
  sink.writeln('File Line Violations (> $maxFileLines lines):');
  for (final f in violatedFiles) {
    final deltaStr = (f.delta > 0 ? '+${f.delta}' : '${f.delta}').padLeft(6);
    final oldL = f.oldLines ?? 0;
    sink.writeln(
      '  $deltaStr  $oldL -> ${f.newLines} lines  ${f.filePath} [VIOLATION]',
    );
  }
}

void _printDeltaRows(
  Iterable<ComplexityDelta> deltas,
  int maxName,
  int? failThreshold,
  int? maxFunctionLines,
  bool failOnIncrease,
  StringSink sink,
) {
  for (final d in deltas) {
    final deltaStr = d.delta > 0
        ? '+${d.delta}'
        : (d.oldScore == null ? '+New' : '${d.delta}');
    final scoreStr = d.oldScore != null && d.newScore != null
        ? '${d.oldScore} -> ${d.newScore}'.padRight(10)
        : '${d.newScore ?? "Deleted"}'.padRight(10);
    final nameStr = d.name.padRight(maxName);
    final locStr = '${d.filePath}:L${d.startLine}-${d.endLine}';
    final isVio = d.isViolation(
      failThreshold: failThreshold,
      maxFunctionLines: maxFunctionLines,
      failOnIncrease: failOnIncrease,
    );
    final marker = _formatDeltaMarker(d, isVio);

    sink.writeln('${deltaStr.padLeft(6)}  $scoreStr  $nameStr  $locStr$marker');
  }
}

String _formatDeltaMarker(ComplexityDelta d, bool isViolation) {
  if (isViolation) return ' [VIOLATION]';
  if (d.delta < 0) return ' [IMPROVED]';
  return '';
}
