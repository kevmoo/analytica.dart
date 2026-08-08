import 'dart:convert';
import 'dart:io';
import 'package:args/args.dart';
import 'package:io/io.dart';
import 'data_flow_analyzer.dart';
import 'models.dart';

/// Executes the Data-Flow CLI with [args] and returns the exit code.
Future<int> runCli(
  List<String> args, {
  StringSink? out,
  StringSink? err,
}) async {
  final stdoutSink = out ?? stdout;
  final stderrSink = err ?? stderr;
  final parser = _buildParser();

  try {
    if (args.contains('-h') || args.contains('--help')) {
      _printUsage(parser, stdoutSink);
      return ExitCode.success.code;
    }

    final argResults = parser.parse(args);
    if (argResults['help'] as bool) {
      _printUsage(parser, stdoutSink);
      return ExitCode.success.code;
    }

    if (argResults.rest.isEmpty) {
      stderrSink.writeln('Error: Missing target file.');
      _printUsage(parser, stderrSink);
      return ExitCode.usage.code;
    }

    final (:filePath, :linesString) = _resolveTarget(argResults);
    if (linesString == null || linesString.trim().isEmpty) {
      stderrSink.writeln(
        'Error: Target line range is required '
        '(e.g. --lines=45-80 or file.dart:45-80).',
      );
      _printUsage(parser, stderrSink);
      return ExitCode.usage.code;
    }

    await _executeAnalysis(
      filePath: filePath,
      linesString: linesString,
      methodName: argResults['name'] as String,
      format: argResults['format'] as String,
      stdoutSink: stdoutSink,
    );

    return ExitCode.success.code;
  } on FormatException catch (e) {
    stderrSink.writeln('Error: ${e.message}');
    _printUsage(parser, stderrSink);
    return ExitCode.usage.code;
  } on FileSystemException catch (e) {
    stderrSink.writeln('Error: ${e.message} (${e.path})');
    return ExitCode.noInput.code;
  } catch (e) {
    stderrSink.writeln('Fatal error: $e');
    return 1;
  }
}

ArgParser _buildParser() => ArgParser()
  ..addFlag(
    'help',
    abbr: 'h',
    negatable: false,
    help: 'Print this usage information.',
  )
  ..addOption(
    'lines',
    abbr: 'l',
    help:
        'Target 1-based line range of the code block to extract '
        '(e.g. 45-80).',
  )
  ..addOption(
    'name',
    abbr: 'n',
    defaultsTo: '_extracted',
    help: 'Name for the proposed extracted helper function.',
  )
  ..addOption(
    'format',
    abbr: 'f',
    defaultsTo: 'json',
    allowed: ['json', 'text'],
    help: 'Output format.',
  );

({String filePath, String? linesString}) _resolveTarget(ArgResults argResults) {
  final rawTarget = argResults.rest.first;
  var filePath = rawTarget;
  var linesString = argResults['lines'] as String?;

  if (rawTarget.contains(':')) {
    final parts = rawTarget.split(':');
    if (parts.length == 2 && parts[1].contains('-')) {
      if (linesString != null) {
        throw const FormatException(
          'Target lines specified both via --lines and file path.',
        );
      }
      filePath = parts[0];
      linesString = parts[1];
    }
  }

  return (filePath: filePath, linesString: linesString);
}

Future<void> _executeAnalysis({
  required String filePath,
  required String linesString,
  required String methodName,
  required String format,
  required StringSink stdoutSink,
}) async {
  final lineBounds = _parseLineBounds(linesString);
  const analyzer = DataFlowAnalyzer();
  final result = await analyzer.analyzeFile(
    filePath: filePath,
    startLine: lineBounds.$1,
    endLine: lineBounds.$2,
    methodName: methodName,
  );

  if (format == 'json') {
    stdoutSink.writeln(
      const JsonEncoder.withIndent('  ').convert(result.toJson()),
    );
  } else {
    _printTextReport(result, stdoutSink);
  }
}

(int, int) _parseLineBounds(String lines) {
  final parts = lines.split('-');
  if (parts.length != 2) {
    throw FormatException(
      'Invalid lines format "$lines". Expected <start>-<end> (e.g. 45-80).',
    );
  }

  final start = int.tryParse(parts[0].trim());
  final end = int.tryParse(parts[1].trim());

  if (start == null || start < 1) {
    throw FormatException('Invalid start line: "${parts[0]}". Must be >= 1.');
  }
  if (end == null || end < start) {
    throw FormatException(
      'Invalid end line: "${parts[1]}". Must be >= start line ($start).',
    );
  }

  return (start, end);
}

void _printUsage(ArgParser parser, StringSink sink) {
  sink.writeln('Dart Data-Flow & Method Extraction Analyzer');
  sink.writeln();
  sink.writeln(
    'Analyzes a target slice of code inside a Dart function and '
    'deterministically',
  );
  sink.writeln(
    'calculates required parameters (inputs), modified variables (mutations),',
  );
  sink.writeln('and live return values (outputs) for safe method extraction.');
  sink.writeln();
  sink.writeln(
    'Usage: dart run cognitive_complexity:data_flow [options] '
    '<file.dart[:start-end]>',
  );
  sink.writeln();
  sink.writeln('Examples:');
  sink.writeln(
    '  # Analyze lines 45 through 80 of auth.dart (Agent-first JSON default)',
  );
  sink.writeln(
    '  dart run cognitive_complexity:data_flow lib/src/auth.dart:45-80',
  );
  sink.writeln();
  sink.writeln('  # Analyze with explicit flags and custom helper name');
  sink.writeln(
    '  dart run cognitive_complexity:data_flow --lines=45-80 '
    '--name=_validateToken lib/src/auth.dart',
  );
  sink.writeln();
  sink.writeln('  # Human-readable terminal output');
  sink.writeln(
    '  dart run cognitive_complexity:data_flow --format=text '
    'lib/src/auth.dart:45-80',
  );
  sink.writeln();
  sink.writeln('Options:');
  sink.writeln(parser.usage);
}

void _printTextReport(DataFlowResult result, StringSink sink) {
  sink.writeln(
    'Data-Flow Extraction Analysis: ${result.filePath} '
    '(Lines ${result.startLine}-${result.endLine})',
  );
  sink.writeln('Enclosing: ${result.enclosingDeclaration}');
  sink.writeln();

  _printInputs(sink, result);
  _printMutations(sink, result);
  _printOutputs(sink, result);
  _printEscapes(result, sink);

  sink.writeln('Suggested Signature:');
  sink.writeln('  ${result.suggestedSignature}');
  sink.writeln();

  final status = result.isCleanlyExtractable
      ? '✅ Cleanly Extractable'
      : '❌ Extraction Blocked by Control Flow Escapes';
  sink.writeln('Status: $status');
}

void _printInputs(StringSink sink, DataFlowResult result) {
  sink.writeln('Inbound Parameters (Inputs):');
  if (result.inputs.isEmpty) {
    sink.writeln('  • None');
  } else {
    for (final input in result.inputs) {
      final mutTag = input.isMutated ? ' (mutated)' : ' (read-only)';
      sink.writeln('  • ${input.type} ${input.name}$mutTag');
    }
  }
  sink.writeln();
}

void _printMutations(StringSink sink, DataFlowResult result) {
  sink.writeln('Mutations (Modified Variables):');
  if (result.mutations.isEmpty) {
    sink.writeln('  • None');
  } else {
    for (final mut in result.mutations) {
      final lineInfo = mut.firstMutationLine != null
          ? ' (reassigned at L${mut.firstMutationLine})'
          : '';
      sink.writeln('  • ${mut.type} ${mut.name}$lineInfo');
    }
  }
  sink.writeln();
}

void _printOutputs(StringSink sink, DataFlowResult result) {
  sink.writeln('Outbound Returns (Outputs):');
  if (result.outputs.isEmpty) {
    sink.writeln('  • None');
  } else {
    for (final out in result.outputs) {
      sink.writeln('  • ${out.type} ${out.name}');
    }
  }
  sink.writeln();
}

void _printEscapes(DataFlowResult result, StringSink sink) {
  if (result.escapes.isNotEmpty) {
    sink.writeln('⚠️ Control Flow Escapes Detected:');
    for (final escape in result.escapes) {
      sink.writeln('  • [L${escape.line}] ${escape.description}');
    }
    sink.writeln();
  }
}
