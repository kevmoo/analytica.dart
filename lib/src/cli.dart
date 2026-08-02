import 'dart:convert';
import 'dart:io';
import 'package:args/args.dart';
import 'package:io/io.dart';
import 'complexity_analyzer.dart';

/// Executes the Cognitive Complexity CLI with [args] and returns the exit
/// code.
Future<int> runCli(
  List<String> args, {
  StringSink? out,
  StringSink? err,
}) async {
  final stdoutSink = out ?? stdout;
  final stderrSink = err ?? stderr;

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
      'format',
      defaultsTo: 'text',
      allowed: ['text', 'json'],
      help: 'Output format.',
    );

  try {
    final argResults = parser.parse(args);

    if (argResults['help'] as bool) {
      _printUsage(parser, stdoutSink);
      return ExitCode.success.code;
    }

    final targets = argResults.rest.isEmpty ? ['lib'] : argResults.rest;

    final threshold = int.tryParse(argResults['threshold'] as String);
    if (threshold == null || threshold < 0) {
      throw FormatException(
        'Invalid threshold: ${argResults['threshold']}. '
        'Must be a non-negative integer.',
      );
    }

    int? failThreshold;
    final failVal = argResults['fail-threshold'] as String?;
    if (failVal != null) {
      failThreshold = int.tryParse(failVal);
      if (failThreshold == null || failThreshold < 0) {
        throw FormatException(
          'Invalid fail-threshold: $failVal. '
          'Must be a non-negative integer.',
        );
      }
    }

    final analyzer = ComplexityAnalyzer();
    final allResults = <FunctionComplexity>[];

    for (final target in targets) {
      allResults.addAll(analyzer.analyzePath(target));
    }

    // Sort descending by complexity
    allResults.sort((a, b) => b.score.compareTo(a.score));

    // Filter by reporting threshold
    final displayedResults = allResults
        .where((r) => r.score >= threshold)
        .toList();

    final format = argResults['format'] as String;
    if (format == 'json') {
      final jsonOutput = jsonEncode(
        displayedResults.map((e) => e.toJson()).toList(),
      );
      stdoutSink.writeln(jsonOutput);
    } else {
      _printTextReport(displayedResults, threshold, stdoutSink, failThreshold);
    }

    if (failThreshold != null &&
        allResults.any((r) => r.score > failThreshold!)) {
      if (format == 'text') {
        stderrSink.writeln(
          '\nError: One or more declarations exceeded the '
          'failure threshold ($failThreshold).',
        );
      }
      return 1; // Non-zero exit code for CI failure
    }

    return ExitCode.success.code;
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
    if (res.name.length > maxNameLen) {
      maxNameLen = res.name.length;
    }
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
    final isViolation = failThreshold != null && res.score > failThreshold;
    final violationMarker = isViolation ? ' [VIOLATION]' : '';
    sink.writeln('$scoreStr  $nameStr  $locStr$violationMarker');
  }
}
