import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:analytica/analytica.dart';
import 'package:args/args.dart';

import '../schema_version.dart';
import 'complexity_analyzer.dart';
import 'delta_analyzer.dart';
import 'github_reporter.dart';

/// Executes the Cognitive Complexity CLI with [args] and returns the exit
/// code.
Future<int> runCli(
  List<String> args, {
  StringSink? out,
  StringSink? err,
  Stream<List<int>>? input,
  Map<String, String>? environment,
}) async {
  final stdoutSink = out ?? stdout;
  final stderrSink = err ?? stderr;
  final stdinStream = input ?? stdin;
  final env = environment ?? Platform.environment;

  // Under GitHub Actions, the process is compiled/run from the action's folder.
  // We re-align Directory.current to GITHUB_WORKSPACE so target scanning paths
  // and git commands resolve against the user's project workspace repository.
  final workspace = env['GITHUB_WORKSPACE'];
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
    ..addFlag(
      'verbose',
      abbr: 'v',
      negatable: false,
      help:
          'With --format=text, add a Breakdown column (branches, nesting, '
          'boolean operators, max depth) and tag `_test.dart` entrypoints. '
          'JSON output always includes these fields.',
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
    ..addFlag(
      'comment-on-clean',
      negatable: false,
      help:
          'With --comment-output, also write the report when there are no '
          'violations or complexity regressions.',
    )
    ..addOption(
      'coverage',
      valueHelp: 'lcov.info',
      help:
          'Optional path to an LCOV coverage file (e.g. coverage/lcov.info '
          'from "dart test --coverage-path=coverage/lcov.info" or '
          '"flutter test --coverage") to annotate declarations with line '
          'coverage.',
    )
    ..addPathFilterOptions();

  try {
    final argResults = parser.parse(args);

    if (argResults['help'] as bool) {
      _printUsage(parser, stdoutSink);
      return ExitCode.success.code;
    }

    final targets = argResults.rest.isEmpty
        ? discoverDefaultTargets()
        : argResults.rest;
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
    final verbose = argResults['verbose'] as bool;
    final gitDiffBase = argResults['git-diff'] as String?;
    final failOnIncrease = argResults['fail-on-increase'] as bool;
    final commentOutput = argResults['comment-output'] as String?;
    final maxCommentRows = parseNonNegativeInt(
      argResults['max-comment-rows'] as String,
      'max-comment-rows',
    );
    final commentOnClean = argResults['comment-on-clean'] as bool;
    final coveragePath = argResults['coverage'] as String?;
    final pathFilter = parsePathFilter(argResults);

    _warnIgnoredFlags(
      failOnIncrease: failOnIncrease,
      commentOutput: commentOutput,
      commentOnClean: commentOnClean,
      verbose: verbose,
      format: format,
      gitDiffBase: gitDiffBase,
      coveragePath: coveragePath,
      hasStdinTarget: targets.contains('-'),
      err: stderrSink,
    );

    final stdinTargetCount = targets.where((t) => t == '-').length;
    if (stdinTargetCount > 1) {
      throw const FormatException(
        'Stdin target "-" cannot be specified more than once.',
      );
    }

    final coverage = coveragePath == null
        ? null
        : LcovCoverage.fromFile(coveragePath);

    if (gitDiffBase != null) {
      if (gitDiffBase.trim().isEmpty) {
        throw const FormatException('Git diff base reference cannot be empty.');
      }
      if (stdinTargetCount > 0) {
        throw const FormatException(
          'Cannot combine stdin target "-" with --git-diff.',
        );
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
        coverage: coverage,
        commentOutput: commentOutput,
        maxCommentRows: maxCommentRows,
        commentOnClean: commentOnClean,
        out: stdoutSink,
        err: stderrSink,
        environment: environment,
      );
    }

    return await _handleRegularMode(
      targets: targets,
      pathFilter: pathFilter,
      threshold: threshold,
      failThreshold: failThreshold,
      maxFileLines: maxFileLines,
      maxFunctionLines: maxFunctionLines,
      format: format,
      verbose: verbose,
      coverage: coverage,
      commentOutput: commentOutput,
      maxCommentRows: maxCommentRows,
      commentOnClean: commentOnClean,
      out: stdoutSink,
      err: stderrSink,
      input: stdinStream,
      environment: environment,
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
  required bool commentOnClean,
  required bool verbose,
  required String format,
  required String? gitDiffBase,
  required String? coveragePath,
  required bool hasStdinTarget,
  required StringSink err,
}) {
  if (failOnIncrease && gitDiffBase == null) {
    err.writeln(
      'Warning: --fail-on-increase has no effect unless --git-diff is '
      'specified.',
    );
  }

  if (commentOutput != null && format != 'github') {
    err.writeln(
      'Warning: --comment-output has no effect unless --format=github is set.',
    );
  }

  if (commentOnClean && commentOutput == null) {
    err.writeln(
      'Warning: --comment-on-clean has no effect unless --comment-output is '
      'set.',
    );
  }

  if (verbose && (format != 'text' || gitDiffBase != null)) {
    err.writeln(
      'Warning: --verbose only affects --format=text without --git-diff.',
    );
  }

  if (coveragePath != null && hasStdinTarget) {
    err.writeln('Warning: --coverage is ignored for stdin ("-") targets.');
  }
}

GitHubReporter _createGitHubReporter({
  required StringSink out,
  String? commentOutput,
  int maxCommentRows = 0,
  bool commentOnClean = false,
  Map<String, String>? environment,
}) {
  final summaryPath = environment?['GITHUB_STEP_SUMMARY'];
  final summaryFile = environment == null
      ? resolveGitHubSummaryFile()
      : (summaryPath != null && summaryPath.isNotEmpty
            ? File(summaryPath)
            : null);
  return GitHubReporter(
    stdoutSink: out,
    summaryFile: summaryFile,
    commentFile: commentOutput == null ? null : File(commentOutput),
    maxCommentRows: maxCommentRows,
    commentOnClean: commentOnClean,
  );
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
  LcovCoverage? coverage,
  String? commentOutput,
  int maxCommentRows = 0,
  bool commentOnClean = false,
  Map<String, String>? environment,
}) async {
  final deltaAnalyzer = DeltaAnalyzer(pathFilter: pathFilter);
  final rawSummary = await deltaAnalyzer.computeDeltas(
    gitDiffBase,
    targetPaths: targets,
    failThreshold: failThreshold,
    maxFunctionLines: maxFunctionLines,
    failOnIncrease: failOnIncrease,
  );
  final summary = coverage == null
      ? rawSummary
      : rawSummary.withCoverage(coverage);

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
    final reporter = _createGitHubReporter(
      out: out,
      commentOutput: commentOutput,
      maxCommentRows: maxCommentRows,
      commentOnClean: commentOnClean,
      environment: environment,
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

Future<int> _handleRegularMode({
  required List<String> targets,
  required PathFilter pathFilter,
  required int threshold,
  required int? failThreshold,
  required int? maxFileLines,
  required int? maxFunctionLines,
  required String format,
  required bool verbose,
  required StringSink out,
  required StringSink err,
  required Stream<List<int>> input,
  LcovCoverage? coverage,
  String? commentOutput,
  int maxCommentRows = 0,
  bool commentOnClean = false,
  Map<String, String>? environment,
}) async {
  final analyzer = ComplexityAnalyzer(pathFilter: pathFilter);
  final (
    results: allResults,
    suppressed: allSuppressed,
    :fileMetrics,
  ) = await _collectRegularTargets(
    targets,
    analyzer,
    includeFileLines: maxFileLines != null,
    input: input,
  );

  allResults.sort((a, b) => b.score.compareTo(a.score));
  allSuppressed.sort((a, b) => b.score.compareTo(a.score));
  final rawDisplayed = allResults
      .where(
        (r) =>
            r.score >= threshold ||
            r.isViolation(
              failThreshold: failThreshold,
              maxFunctionLines: maxFunctionLines,
            ),
      )
      .toList();
  final displayed = coverage == null
      ? rawDisplayed
      : coverage.annotateDeclarations(rawDisplayed);

  if (format == 'json') {
    out.writeln(
      jsonEncode(
        _encodeRegularJson(displayed, fileMetrics, allSuppressed, maxFileLines),
      ),
    );
  } else if (format == 'github') {
    final reporter = _createGitHubReporter(
      out: out,
      commentOutput: commentOutput,
      maxCommentRows: maxCommentRows,
      commentOnClean: commentOnClean,
      environment: environment,
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
      suppressed: allSuppressed,
      verbose: verbose,
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
      err.writeln(
        failThreshold != null
            ? '\nError: One or more functions exceeded the failure threshold '
                  '($failThreshold).'
            : '\nError: One or more declarations or files exceeded the '
                  'configured line limit.',
      );
    }
    return 1;
  }

  return ExitCode.success.code;
}

Future<
  ({
    List<FunctionComplexity> results,
    List<SuppressedDeclaration> suppressed,
    List<FileLineMetric> fileMetrics,
  })
>
_collectRegularTargets(
  List<String> targets,
  ComplexityAnalyzer analyzer, {
  required bool includeFileLines,
  required Stream<List<int>> input,
}) async {
  final results = <FunctionComplexity>[];
  final suppressed = <SuppressedDeclaration>[];
  final fileMetrics = <FileLineMetric>[];

  for (final target in targets) {
    if (target == '-') {
      final String code;
      try {
        code = await utf8.decodeStream(input);
      } on FormatException catch (e) {
        throw FileSystemException(
          'Invalid UTF-8 input: ${e.message}',
          '<stdin>',
        );
      }
      results.addAll(analyzer.analyzeCode(code, filePath: '<stdin>'));
      suppressed.addAll(
        analyzer.analyzeCodeSuppressed(code, filePath: '<stdin>'),
      );
      final lineCount = includeFileLines
          ? analyzer.analyzeCodeLineCount(code)
          : null;
      if (lineCount != null) {
        fileMetrics.add(
          FileLineMetric(filePath: '<stdin>', lineCount: lineCount),
        );
      }
      continue;
    }
    results.addAll(analyzer.analyzePath(target));
    suppressed.addAll(analyzer.analyzePathSuppressed(target));
    if (includeFileLines) {
      fileMetrics.addAll(analyzer.analyzePathFileLines(target));
    }
  }

  return (results: results, suppressed: suppressed, fileMetrics: fileMetrics);
}

Object _encodeRegularJson(
  List<FunctionComplexity> displayed,
  List<FileLineMetric> fileMetrics,
  List<SuppressedDeclaration> allSuppressed,
  int? maxFileLines,
) {
  final declarationsJson = displayed.map((e) => e.toJson()).toList();
  if (maxFileLines == null && allSuppressed.isEmpty) {
    return declarationsJson;
  }
  final suppressedByFile = <String, List<Map<String, dynamic>>>{};
  for (final s in allSuppressed) {
    (suppressedByFile[s.filePath] ??= []).add(s.toJson());
  }
  final violatedFiles = maxFileLines == null
      ? const <FileLineMetric>[]
      : fileMetrics
            .where((f) => f.isViolation(maxFileLines: maxFileLines))
            .toList();
  final violatedByPath = {for (final f in violatedFiles) f.filePath: f};
  final filePaths = <String>{...violatedByPath.keys, ...suppressedByFile.keys};
  return {
    'schema_version': reportSchemaVersion,
    'summary': {
      'declarations': declarationsJson.length,
      'suppressedDeclarations': allSuppressed.length,
      'suppressed_declarations': allSuppressed.length,
    },
    'declarations': declarationsJson,
    if (allSuppressed.isNotEmpty)
      'suppressedDeclarations': allSuppressed.map((s) => s.toJson()).toList(),
    'files': [
      for (final path in filePaths)
        {
          if (violatedByPath[path] case final metric?)
            ...metric.toJson(maxFileLines: maxFileLines)
          else
            'file': path,
          'suppressedDeclarations': ?suppressedByFile[path],
        },
    ],
  };
}

void _printUsage(ArgParser parser, StringSink sink) {
  sink.writeln('Dart & Flutter Cognitive Complexity Calculator');
  sink.writeln();
  sink.writeln(
    'Usage: dart run cognitive_complexity [options] [<file_or_directory>...]',
  );
  sink.writeln();
  sink.writeln(
    'Without targets, scans lib/ (or every workspace member and '
    'packages/*/lib, pkgs/*/lib in monorepos).',
  );
  sink.writeln('Pass "-" as a target to read Dart source from stdin.');
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
  int? maxFunctionLines, {
  List<SuppressedDeclaration> suppressed = const [],
  bool verbose = false,
}) {
  final violatedFiles = maxFileLines != null
      ? fileMetrics
            .where((f) => f.isViolation(maxFileLines: maxFileLines))
            .toList()
      : const <FileLineMetric>[];

  if (results.isEmpty && violatedFiles.isEmpty && suppressed.isEmpty) {
    final msg = threshold > 0
        ? 'No declarations found with cognitive complexity >= $threshold.'
        : 'No Dart declarations analyzed.';
    sink.writeln(msg);
    return;
  }

  if (results.isNotEmpty) {
    final showCoverage = results.any((r) => r.coverage != null);
    final layout = (
      maxNameLen: results.fold(
        'Declaration'.length,
        (w, r) => max(w, r.name.length),
      ),
      coverageWidth: showCoverage
          ? results.fold(
              'Coverage'.length,
              (w, r) => max(w, (r.coverage?.formatShort() ?? '—').length),
            )
          : 0,
      breakdownWidth: verbose
          ? results.fold(
              'Breakdown'.length,
              (w, r) => max(w, _formatBreakdown(r.composition).length),
            )
          : 0,
      showLines: maxFunctionLines != null,
      showCoverage: showCoverage,
      verbose: verbose,
    );
    _printRegularHeader(layout, sink);
    for (final res in results) {
      sink.writeln(
        _formatRegularRow(res, layout, failThreshold, maxFunctionLines),
      );
    }
  }
  if (violatedFiles.isNotEmpty) {
    _printRegularFileViolationRows(violatedFiles, maxFileLines!, sink);
  }
  _printSuppressedDeclarations(suppressed, sink);
}

void _printSuppressedDeclarations(
  List<SuppressedDeclaration> suppressed,
  StringSink sink,
) {
  if (suppressed.isEmpty) return;
  sink.writeln();
  sink.writeln('Suppressed declarations (${suppressed.length}):');
  for (final s in suppressed) {
    sink.writeln('  $s');
  }
}

typedef _RegularTableLayout = ({
  int maxNameLen,
  int coverageWidth,
  int breakdownWidth,
  bool showLines,
  bool showCoverage,
  bool verbose,
});

void _printRegularHeader(_RegularTableLayout layout, StringSink sink) {
  final headerLines = layout.showLines ? '  ${'Lines'.padLeft(5)}' : '';
  final headerCoverage = layout.showCoverage
      ? '  ${'Coverage'.padRight(layout.coverageWidth)}'
      : '';
  final headerBreakdown = layout.verbose
      ? '  ${'Breakdown'.padRight(layout.breakdownWidth)}'
      : '';
  final headerName = 'Declaration'.padRight(layout.maxNameLen);
  sink.writeln(
    '${'Score'.padLeft(5)}$headerLines$headerCoverage$headerBreakdown  '
    '$headerName  Location',
  );
  sink.writeln(
    '-' *
        (5 +
            headerLines.length +
            headerCoverage.length +
            headerBreakdown.length +
            2 +
            layout.maxNameLen +
            2 +
            30),
  );
}

String _formatRegularRow(
  FunctionComplexity res,
  _RegularTableLayout layout,
  int? failThreshold,
  int? maxFunctionLines,
) {
  final scoreStr = res.score.toString().padLeft(5);
  final linesStr = layout.showLines ? '  ${'${res.lineCount}'.padLeft(5)}' : '';
  final covLabel = res.coverage?.formatShort() ?? '—';
  final coverageStr = layout.showCoverage
      ? '  ${covLabel.padRight(layout.coverageWidth)}'
      : '';
  final breakdownStr = layout.verbose
      ? '  ${_formatBreakdown(res.composition).padRight(layout.breakdownWidth)}'
      : '';
  final nameStr = res.name.padRight(layout.maxNameLen);
  final locStr = '${res.filePath}:L${res.startLine}-${res.endLine}';
  final uncovered = res.coverage?.formatUncoveredRanges() ?? '';
  final uncoveredStr = uncovered.isEmpty ? '' : ' [uncovered: $uncovered]';
  final marker = _violationMarker([
    if (failThreshold != null && res.score > failThreshold)
      'score > $failThreshold',
    if (maxFunctionLines != null && res.lineCount > maxFunctionLines)
      'lines > $maxFunctionLines',
  ]);
  final entrypoint = layout.verbose && res.isTestEntrypoint
      ? ' [test entrypoint]'
      : '';
  return '$scoreStr$linesStr$coverageStr$breakdownStr  $nameStr  '
      '$locStr$uncoveredStr$marker$entrypoint';
}

/// Renders a [ComplexityComposition] as `br N nest N bool N depth N`.
String _formatBreakdown(ComplexityComposition c) =>
    'br ${c.branches} nest ${c.nesting} bool ${c.booleanOps} '
    'depth ${c.maxDepth}';

/// Renders ` [VIOLATION: <reasons>]` for a non-empty [reasons] list, or an
/// empty string when the declaration is within every configured limit.
String _violationMarker(List<String> reasons) =>
    reasons.isEmpty ? '' : ' [VIOLATION: ${reasons.join(', ')}]';

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
        d.delta != 0 ||
        d.isFunctionLineViolation(maxFunctionLines: maxFunctionLines),
  );
  final violatedFiles = maxFileLines != null
      ? summary.fileDeltas
            .where((f) => f.isViolation(maxFileLines: maxFileLines))
            .toList()
      : const <FileLineDelta>[];

  if (deltas.isEmpty &&
      violatedFiles.isEmpty &&
      summary.suppressedDeclarations.isEmpty) {
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
  _printSuppressedDeclarations(summary.suppressedDeclarations, sink);

  final violations = summary.countViolations(
    failThreshold: failThreshold,
    maxFileLines: maxFileLines,
    maxFunctionLines: maxFunctionLines,
    failOnIncrease: failOnIncrease,
  );
  sink.writeln(
    'Summary: ${summary.countAdded} added, ${summary.countIncreased} '
    'increased, ${summary.countImproved} improved, '
    '${summary.countRemoved} removed '
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
  final deltaList = deltas.toList();
  final maxName = deltaList.fold(
    'Declaration'.length,
    (w, d) => max(w, d.name.length),
  );
  final showCoverage = deltaList.any((d) => d.coverage != null);
  final coverageWidth = showCoverage
      ? deltaList.fold(
          'Coverage'.length,
          (w, d) => max(w, (d.coverage?.formatShort() ?? '—').length),
        )
      : 0;

  final showLines = maxFunctionLines != null;
  final hdrDelta = 'Delta'.padLeft(6);
  final hdrScore = 'Score'.padRight(12);
  final hdrLines = showLines ? '  ${'Lines'.padRight(12)}' : '';
  final hdrCoverage = showCoverage
      ? '  ${'Coverage'.padRight(coverageWidth)}'
      : '';
  final hdrName = 'Declaration'.padRight(maxName);
  sink.writeln('$hdrDelta  $hdrScore$hdrLines$hdrCoverage  $hdrName  Location');
  final rule =
      '-' *
      (6 +
          2 +
          12 +
          hdrLines.length +
          hdrCoverage.length +
          2 +
          maxName +
          2 +
          30);
  sink.writeln(rule);

  for (final d in deltaList) {
    final deltaStr = d.delta > 0 ? '+${d.delta}' : '${d.delta}';
    final (locStr, rawScore) = switch ((d.oldScore, d.newScore)) {
      (final oldS?, final newS?) => (
        '${d.filePath}:L${d.startLine}-${d.endLine}',
        '$oldS -> $newS',
      ),
      (null, final newS?) => (
        '${d.filePath}:L${d.startLine}-${d.endLine}',
        'new -> $newS',
      ),
      (final oldS?, null) => (d.filePath, '$oldS -> del'),
      (null, null) => (d.filePath, 'del'),
    };
    final scoreStr = rawScore.padRight(12);
    final linesStr = showLines
        ? '  ${'${d.oldLines ?? 'new'} -> ${d.newLines ?? 'del'}'.padRight(12)}'
        : '';
    final coverageStr = showCoverage
        ? '  ${(d.coverage?.formatShort() ?? '—').padRight(coverageWidth)}'
        : '';
    final nameStr = d.name.padRight(maxName);
    final uncovered = d.coverage?.formatUncoveredRanges() ?? '';
    final uncoveredStr = uncovered.isEmpty ? '' : ' [uncovered: $uncovered]';
    final marker = _deltaMarker(
      d,
      failThreshold: failThreshold,
      maxFunctionLines: maxFunctionLines,
      failOnIncrease: failOnIncrease,
    );

    sink.writeln(
      '${deltaStr.padLeft(6)}  $scoreStr$linesStr$coverageStr  $nameStr  '
      '$locStr$uncoveredStr$marker',
    );
  }

  sink.writeln(rule);
}

/// Renders ` [VIOLATION: <reasons>]`, ` [IMPROVED]`, or an empty suffix for a
/// `--git-diff` row, deriving each reason from [ComplexityDelta]'s own
/// violation predicates.
String _deltaMarker(
  ComplexityDelta d, {
  required int? failThreshold,
  required int? maxFunctionLines,
  required bool failOnIncrease,
}) {
  final scoreVio = d.isScoreViolation(
    failThreshold: failThreshold,
    failOnIncrease: failOnIncrease,
  );
  final overThreshold =
      failThreshold != null && (d.newScore ?? 0) > failThreshold;
  final marker = _violationMarker([
    if (scoreVio) overThreshold ? 'score > $failThreshold' : 'increased',
    if (d.isFunctionLineViolation(maxFunctionLines: maxFunctionLines))
      'lines > $maxFunctionLines',
  ]);
  if (marker.isNotEmpty) return marker;
  return d.status == DeltaStatus.improved ? ' [IMPROVED]' : '';
}

void _printDeltaFileViolations(
  List<FileLineDelta> violatedFiles,
  int maxFileLines,
  StringSink sink,
) {
  sink.writeln();
  sink.writeln('File Line Violations (> $maxFileLines lines):');
  for (final f in violatedFiles) {
    final deltaStr = (f.delta > 0 ? '+${f.delta}' : '${f.delta}').padLeft(6);
    final oldL = f.oldLines ?? 0;
    sink.writeln(
      '  $deltaStr  $oldL -> ${f.newLines} lines  ${f.filePath} [VIOLATION]',
    );
  }
}
