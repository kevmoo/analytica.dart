import 'dart:convert';
import 'dart:io';

import 'package:analytica/analytica.dart';
import 'package:args/args.dart';

import 'file_split_analyzer.dart';

/// Executes the `file_split` CLI advisor with [args] and returns the exit code.
Future<int> runFileSplitCli(
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
    return await _executeFileSplit(argResults, stdoutSink);
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
    'target-lines',
    defaultsTo: '800',
    valueHelp: 'lines',
    help: 'Target maximum line count per extracted file cluster.',
  )
  ..addOption(
    'min-cluster-lines',
    defaultsTo: '40',
    valueHelp: 'lines',
    help:
        'Minimum line count for a standalone extracted cluster '
        '(prevents micro-fragmentation).',
  )
  ..addOption(
    'format',
    defaultsTo: 'text',
    allowed: ['text', 'json'],
    help: 'Output format (text or json).',
  )
  ..addSdkPathOption();

Future<int> _executeFileSplit(
  ArgResults argResults,
  StringSink stdoutSink,
) async {
  if (argResults.rest.isEmpty) {
    throw const FormatException(
      'Missing target file. '
      'Usage: dart run cognitive_complexity:file_split <file.dart>',
    );
  }

  final targetFile = argResults.rest.first;
  if (!File(targetFile).existsSync()) {
    throw FileSystemException('Target file does not exist', targetFile);
  }

  final targetLines = parseNonNegativeInt(
    argResults['target-lines'] as String,
    'target-lines',
  );
  final minClusterLines = parseNonNegativeInt(
    argResults['min-cluster-lines'] as String,
    'min-cluster-lines',
  );
  final format = argResults['format'] as String;
  final sdkPath = argResults['sdk-path'] as String?;

  final analyzer = FileSplitAnalyzer(sdkPath: sdkPath);
  final report = await analyzer.analyzeFile(
    targetFile,
    targetLines: targetLines == 0 ? 800 : targetLines,
    minClusterLines: minClusterLines,
  );

  if (format == 'json') {
    stdoutSink.writeln(
      const JsonEncoder.withIndent('  ').convert(report.toJson()),
    );
  } else {
    stdoutSink.write(report.formatText());
  }

  return ExitCode.success.code;
}

void _printUsage(ArgParser parser, StringSink sink) {
  sink.writeln(
    'Dart File Decomposition & Acyclic Dependency Cut Advisor (file_split)',
  );
  sink.writeln();
  sink.writeln(
    'Usage: dart run cognitive_complexity:file_split [options] <file.dart>',
  );
  sink.writeln();
  sink.writeln('Options:');
  sink.writeln(parser.usage);
}
