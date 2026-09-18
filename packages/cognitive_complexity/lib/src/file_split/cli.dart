import 'dart:convert';
import 'dart:io';

import 'package:analytica/analytica.dart';
import 'package:args/args.dart';

import 'file_split_analyzer.dart';
import 'models.dart';

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
  ..addFlag(
    'use-parts',
    defaultsTo: null,
    help:
        'Allow or prefer `part` / `part of` directives when decomposing '
        'oversized classes or tightly coupled SCCs (defaults to auto-detect '
        'with user confirmation prompt).',
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

  final rawTarget = parseNonNegativeInt(
    argResults['target-lines'] as String,
    'target-lines',
  );
  final targetLines = rawTarget == 0 ? 800 : rawTarget;
  final minClusterLines = parseNonNegativeInt(
    argResults['min-cluster-lines'] as String,
    'min-cluster-lines',
  );
  final useParts = argResults.wasParsed('use-parts')
      ? argResults['use-parts'] as bool
      : null;
  final format = argResults['format'] as String;
  final sdkPath = argResults['sdk-path'] as String?;

  final targetFiles = _expandTargetFiles(argResults.rest, targetLines);
  final analyzer = FileSplitAnalyzer(sdkPath: sdkPath);
  final reports = await analyzer.analyzeFiles(
    targetFiles,
    targetLines: targetLines,
    minClusterLines: minClusterLines,
    useParts: useParts,
  );

  _writeReports(reports, format, stdoutSink);
  return ExitCode.success.code;
}

List<String> _expandTargetFiles(List<String> inputs, int targetLines) {
  final resolved = <String>[];
  for (final input in inputs) {
    if (FileSystemEntity.isDirectorySync(input)) {
      resolved.addAll(
        _findOversizedDartFilesInDir(Directory(input), targetLines),
      );
    } else if (File(input).existsSync()) {
      resolved.add(input);
    } else {
      throw FileSystemException('Target file does not exist', input);
    }
  }
  return resolved;
}

List<String> _findOversizedDartFilesInDir(Directory dir, int targetLines) {
  final matches = <({String path, int lines})>[];
  for (final entity in dir.listSync(recursive: true, followLinks: false)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      final lineCount = entity.readAsLinesSync().length;
      if (lineCount > targetLines) {
        matches.add((path: entity.path, lines: lineCount));
      }
    }
  }
  matches.sort((a, b) => b.lines.compareTo(a.lines));
  return [for (final m in matches) m.path];
}

void _writeReports(
  List<FileSplitReport> reports,
  String format,
  StringSink stdoutSink,
) {
  if (format == 'json') {
    final payload = reports.length == 1
        ? reports.single.toJson()
        : [for (final r in reports) r.toJson()];
    stdoutSink.writeln(const JsonEncoder.withIndent('  ').convert(payload));
    return;
  }
  for (var i = 0; i < reports.length; i++) {
    if (i > 0) stdoutSink.writeln('=' * 42);
    stdoutSink.write(reports[i].formatText());
  }
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
