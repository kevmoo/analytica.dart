import 'dart:convert';
import 'dart:io';
import 'package:args/args.dart';
import 'package:io/io.dart';
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
          'increased in complexity.',
    )
    ..addOption(
      'format',
      defaultsTo: 'text',
      allowed: ['text', 'json', 'github'],
      help: 'Output format.',
    );

  try {
    final argResults = parser.parse(args);

    if (argResults['help'] as bool) {
      _printUsage(parser, stdoutSink);
      return ExitCode.success.code;
    }

    final targets = argResults.rest.isEmpty ? ['lib'] : argResults.rest;
    final threshold = _parseNonNegativeInt(
      argResults['threshold'] as String,
      'threshold',
    );
    int? failThreshold;
    if (argResults['fail-threshold'] != null) {
      failThreshold = _parseNonNegativeInt(
        argResults['fail-threshold'] as String,
        'fail-threshold',
      );
    }

    final format = argResults['format'] as String;
    final gitDiffBase = argResults['git-diff'] as String?;
    final failOnIncrease = argResults['fail-on-increase'] as bool;

    if (gitDiffBase != null) {
      if (gitDiffBase.trim().isEmpty) {
        throw const FormatException('Git diff base reference cannot be empty.');
      }
      return await _handleDiffMode(
        gitDiffBase: gitDiffBase,
        targets: targets,
        format: format,
        failThreshold: failThreshold,
        failOnIncrease: failOnIncrease,
        out: stdoutSink,
        err: stderrSink,
      );
    }

    return _handleRegularMode(
      targets: targets,
      threshold: threshold,
      failThreshold: failThreshold,
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

int _parseNonNegativeInt(String val, String name) {
  final parsed = int.tryParse(val);
  if (parsed == null || parsed < 0) {
    throw FormatException(
      'Invalid $name: $val. Must be a non-negative integer.',
    );
  }
  return parsed;
}

Future<int> _handleDiffMode({
  required String gitDiffBase,
  required List<String> targets,
  required String format,
  required int? failThreshold,
  required bool failOnIncrease,
  required StringSink out,
  required StringSink err,
}) async {
  final deltaAnalyzer = DeltaAnalyzer();
  final summary = await deltaAnalyzer.computeDeltas(
    gitDiffBase,
    targetPaths: targets,
  );

  if (format == 'json') {
    out.writeln(
      jsonEncode(
        summary.toJson(
          failThreshold: failThreshold,
          failOnIncrease: failOnIncrease,
        ),
      ),
    );
  } else if (format == 'github') {
    final reporter = GitHubReporter(stdoutSink: out);
    reporter.printReport(
      deltaSummary: summary,
      failThreshold: failThreshold,
      failOnIncrease: failOnIncrease,
    );
  } else {
    _printDeltaTextReport(summary, out, failThreshold, failOnIncrease);
  }

  final violations = summary.countViolations(
    failThreshold: failThreshold,
    failOnIncrease: failOnIncrease,
  );
  if (violations > 0) {
    if (format == 'text') {
      err.writeln(
        '\nError: $violations declaration(s) triggered complexity '
        'threshold violations or regressions.',
      );
    }
    return 1;
  }

  return ExitCode.success.code;
}

int _handleRegularMode({
  required List<String> targets,
  required int threshold,
  required int? failThreshold,
  required String format,
  required StringSink out,
  required StringSink err,
}) {
  final analyzer = ComplexityAnalyzer();
  final allResults = <FunctionComplexity>[];

  for (final target in targets) {
    allResults.addAll(analyzer.analyzePath(target));
  }

  allResults.sort((a, b) => b.score.compareTo(a.score));
  final displayed = allResults.where((r) => r.score >= threshold).toList();

  if (format == 'json') {
    out.writeln(jsonEncode(displayed.map((e) => e.toJson()).toList()));
  } else if (format == 'github') {
    final reporter = GitHubReporter(stdoutSink: out);
    reporter.printReport(
      regularResults: displayed,
      failThreshold: failThreshold,
    );
  } else {
    _printTextReport(displayed, threshold, out, failThreshold);
  }

  if (failThreshold != null && allResults.any((r) => r.score > failThreshold)) {
    if (format == 'text') {
      err.writeln(
        '\nError: One or more declarations exceeded the '
        'failure threshold ($failThreshold).',
      );
    }
    return 1;
  }

  return ExitCode.success.code;
}

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
  int threshold,
  StringSink sink,
  int? failThreshold,
) {
  if (results.isEmpty) {
    if (threshold > 0) {
      sink.writeln(
        'No declarations found with cognitive complexity >= $threshold.',
      );
    } else {
      sink.writeln('No Dart declarations analyzed.');
    }
    return;
  }

  var maxNameLen = 'Declaration'.length;
  for (final res in results) {
    if (res.name.length > maxNameLen) maxNameLen = res.name.length;
  }

  final headerScore = 'Score'.padLeft(5);
  final headerName = 'Declaration'.padRight(maxNameLen);
  final headerLoc = 'Location';

  sink.writeln('$headerScore  $headerName  $headerLoc');
  sink.writeln('-' * (5 + 2 + maxNameLen + 2 + 30));

  for (final res in results) {
    final scoreStr = res.score.toString().padLeft(5);
    final nameStr = res.name.padRight(maxNameLen);
    final locStr = '${res.filePath}:L${res.startLine}-${res.endLine}';
    final isVio = failThreshold != null && res.score > failThreshold;
    final violationMarker = isVio ? ' [VIOLATION]' : '';
    sink.writeln('$scoreStr  $nameStr  $locStr$violationMarker');
  }
}

void _printDeltaTextReport(
  DeltaSummary summary,
  StringSink sink,
  int? failThreshold,
  bool failOnIncrease,
) {
  final deltas = summary.deltas.where((d) => d.status != DeltaStatus.unchanged);
  if (deltas.isEmpty) {
    sink.writeln('No modified or newly added Dart declarations detected.');
    return;
  }

  var maxName = 'Declaration'.length;
  for (final d in deltas) {
    if (d.name.length > maxName) maxName = d.name.length;
  }

  final hdrDelta = 'Delta'.padLeft(6);
  final hdrScore = 'Score'.padRight(10);
  final hdrName = 'Declaration'.padRight(maxName);
  final hdrLoc = 'Location';

  sink.writeln('$hdrDelta  $hdrScore  $hdrName  $hdrLoc');
  sink.writeln('-' * (6 + 2 + 10 + 2 + maxName + 2 + 30));

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
      failOnIncrease: failOnIncrease,
    );
    final marker = isVio ? ' [VIOLATION]' : (d.delta < 0 ? ' [IMPROVED]' : '');

    sink.writeln('${deltaStr.padLeft(6)}  $scoreStr  $nameStr  $locStr$marker');
  }

  final violations = summary.countViolations(
    failThreshold: failThreshold,
    failOnIncrease: failOnIncrease,
  );
  sink.writeln('-' * (6 + 2 + 10 + 2 + maxName + 2 + 30));
  sink.writeln(
    'Summary: ${summary.countAdded} added, ${summary.countIncreased} '
    'increased, ${summary.countImproved} improved '
    '(Net Delta: ${summary.netDelta} | Violations: $violations)',
  );
}
