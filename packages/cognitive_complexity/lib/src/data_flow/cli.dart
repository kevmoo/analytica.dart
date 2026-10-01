import 'dart:convert';
import 'dart:io';

import 'package:analytica/analytica.dart';
import 'package:args/args.dart';

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

    final (:filePath, :linesString) = resolveTargetFileAndLines(
      argResults.rest.first,
      explicitLines: argResults['lines'] as String?,
    );
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
      sdkPath: argResults['sdk-path'] as String?,
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
  } on SdkDiscoveryException catch (e) {
    stderrSink.writeln('Error: $e');
    return ExitCode.config.code;
  } catch (e) {
    stderrSink.writeln('Fatal error: $e');
    return 1;
  }
}

ArgParser _buildParser() => ArgParser()
  ..addHelpFlag(help: 'Print this usage information.')
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
  )
  ..addSdkPathOption(
    help:
        'Path to the Dart SDK root used for analysis. Defaults to '
        'auto-discovery (running VM, DART_SDK environment variable, PATH, '
        'FLUTTER_ROOT).',
  );

Future<void> _executeAnalysis({
  required String filePath,
  required String linesString,
  required String methodName,
  required String format,
  required String? sdkPath,
  required StringSink stdoutSink,
}) async {
  final (startLine, endLine) = parseLineBounds(linesString);
  final analyzer = DataFlowAnalyzer(sdkPath: sdkPath);
  final result = await analyzer.analyzeFile(
    filePath: filePath,
    startLine: startLine,
    endLine: endLine,
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
  sink.writeln(
    'Enclosing: ${result.enclosingDeclaration} '
    '(Score: ${result.enclosingScore} -> '
    '${result.estimatedEnclosingScoreAfter} after extraction | '
    'Extracted Helper Score: ${result.sliceScoreAtRoot})',
  );
  sink.writeln();

  _printInputs(sink, result);
  _printMutations(sink, result);
  _printOutputs(sink, result);
  _printEscapes(result, sink);

  if (result.extractionWarnings.isNotEmpty) {
    sink.writeln('⚠️ Shallow Extraction Warnings:');
    for (final warning in result.extractionWarnings) {
      sink.writeln('  • $warning');
    }
    sink.writeln();
  }

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
