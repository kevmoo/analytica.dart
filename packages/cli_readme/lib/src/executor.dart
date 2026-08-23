import 'dart:io';

import 'package:path/path.dart' as p;

import 'models.dart';
import 'normalizer.dart';

/// Evaluates or executes a [CliTarget] to produce expected output text.
Future<String> executeTarget(
  CliTarget target, {
  required String workingDirectory,
}) async {
  if (target.argParser != null) {
    return _evaluateArgParser(target);
  }

  if (target.executablePath != null) {
    return _runSubprocess(target, workingDirectory: workingDirectory);
  }

  throw ArgumentError(
    'Target "${target.commandName}" has neither an in-memory argParser nor '
    'an executablePath.',
  );
}

String _evaluateArgParser(CliTarget target) {
  final buffer = StringBuffer();
  if (target.description != null && target.description!.isNotEmpty) {
    buffer.writeln(target.description!.trimRight());
    buffer.writeln();
  }
  buffer.writeln('Usage: ${target.commandName} [options]');
  buffer.writeln();
  buffer.write(target.argParser!.usage);
  return normalizeText(buffer.toString());
}

Future<String> _runSubprocess(
  CliTarget target, {
  required String workingDirectory,
}) async {
  final scriptPath = p.isAbsolute(target.executablePath!)
      ? target.executablePath!
      : p.join(workingDirectory, target.executablePath!);

  if (!File(scriptPath).existsSync()) {
    throw FileSystemException(
      'Target executable does not exist at "$scriptPath".',
      scriptPath,
    );
  }

  final result = await Process.run(Platform.resolvedExecutable, [
    scriptPath,
    ...target.args,
  ], workingDirectory: workingDirectory);

  if (result.exitCode != 0 && (result.stdout as String).trim().isEmpty) {
    throw ProcessException(
      Platform.resolvedExecutable,
      [scriptPath, ...target.args],
      'Command exited with code ${result.exitCode}.\nStderr:\n${result.stderr}',
      result.exitCode,
    );
  }

  final rawOutput = (result.stdout as String).isNotEmpty
      ? (result.stdout as String)
      : (result.stderr as String);

  return normalizeText(rawOutput);
}
