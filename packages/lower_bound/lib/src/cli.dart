import 'dart:io';

import 'package:args/args.dart';
import 'package:io/io.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import 'models.dart';
import 'pubspec_helper.dart';
import 'reporter.dart';
import 'runner.dart';

/// Builds the CLI argument parser for pkg:lower_bound.
ArgParser buildLowerBoundArgParser() {
  return ArgParser()
    ..addMultiOption(
      'targets',
      abbr: 't',
      defaultsTo: ['lib', 'bin'],
      help: 'Directory or file targets to analyze in staging.',
    )
    ..addFlag(
      'pin',
      defaultsTo: true,
      help: 'Pin direct runtime dependencies to their exact declared floor.',
    )
    ..addOption(
      'sdk',
      help: 'Simulate specific Dart SDK version during pub resolution.',
    )
    ..addOption(
      'format',
      abbr: 'f',
      allowed: ['text', 'github', 'json'],
      defaultsTo: 'text',
      help: 'Output reporting format.',
    )
    ..addOption(
      'comment-output',
      help: 'File path to write sticky PR comment markdown.',
    )
    ..addOption(
      'max-comment-rows',
      defaultsTo: '0',
      help: 'Maximum table rows in sticky PR comment (0 = unlimited).',
    )
    ..addFlag(
      'keep-temp',
      defaultsTo: false,
      negatable: false,
      help: 'Preserve synthetic staging directory on disk for inspection.',
    )
    ..addFlag(
      'fail-on-error',
      defaultsTo: true,
      help: 'Exit with non-zero status if lower bound validation fails.',
    )
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Show usage information.',
    );
}

/// Runs the CLI with [args] and returns an integer exit code.
Future<int> runLowerBoundCli(
  List<String> args, {
  StringSink? stdoutSink,
  StringSink? stderrSink,
  String? workingDirectory,
}) async {
  final out = stdoutSink ?? stdout;
  final err = stderrSink ?? stderr;
  final parser = buildLowerBoundArgParser();

  final ArgResults results;
  try {
    results = parser.parse(args);
  } on FormatException catch (e) {
    err.writeln('Error: ${e.message}');
    err.writeln(parser.usage);
    return ExitCode.usage.code;
  }

  if (results.flag('help')) {
    _printUsage(parser, out);
    return ExitCode.success.code;
  }

  final cwd = workingDirectory ?? Directory.current.path;
  final packagePaths = _resolvePackagePaths(results.rest, cwd, err);
  if (packagePaths == null) {
    return ExitCode.noInput.code;
  }

  return _runValidationSuite(results, packagePaths, out);
}

void _printUsage(ArgParser parser, StringSink out) {
  out.writeln(
    'Validate Dart package compilation against dependency lower bounds.',
  );
  out.writeln();
  out.writeln('Usage: lower_bound [options] [package_path]');
  out.writeln();
  out.writeln(parser.usage);
}

List<String>? _resolvePackagePaths(
  List<String> rawPaths,
  String cwd,
  StringSink err,
) {
  if (rawPaths.isNotEmpty) {
    return _resolveExplicitPaths(rawPaths, err);
  }
  return _resolveCwdWorkspace(cwd, err);
}

List<String>? _resolveExplicitPaths(List<String> rawPaths, StringSink err) {
  final paths = <String>[];
  for (final rawPath in rawPaths) {
    final dir = Directory(rawPath);
    if (!dir.existsSync()) {
      err.writeln('Directory does not exist: $rawPath');
      return null;
    }
    final pubspecFile = File(p.join(dir.path, 'pubspec.yaml'));
    if (!pubspecFile.existsSync()) {
      err.writeln('No pubspec.yaml found in $rawPath');
      return null;
    }
    paths.add(dir.path);
  }
  return paths;
}

List<String>? _resolveCwdWorkspace(String cwd, StringSink err) {
  final pubspecFile = File(p.join(cwd, 'pubspec.yaml'));
  if (!pubspecFile.existsSync()) {
    err.writeln('No pubspec.yaml found in current directory: $cwd');
    return null;
  }

  final parsed = parsePubspec(cwd);
  if (!parsed.isWorkspaceRoot) {
    return [cwd];
  }

  final paths = <String>[];
  for (final member in parsed.workspace!) {
    final memberDir = Directory(p.join(cwd, member));
    if (memberDir.existsSync()) {
      paths.add(memberDir.path);
    }
  }
  return paths.isEmpty ? null : paths;
}

Future<int> _runValidationSuite(
  ArgResults results,
  List<String> packagePaths,
  StringSink out,
) async {
  final targets = results.multiOption('targets');
  final pin = results.flag('pin');
  final keepTemp = results.flag('keep-temp');
  final failOnError = results.flag('fail-on-error');
  final format = results.option('format') ?? 'text';
  final commentOutput = results.option('comment-output');
  final maxCommentRows =
      int.tryParse(results.option('max-comment-rows') ?? '0') ?? 0;
  final sdkRaw = results.option('sdk');
  final sdkOverride = sdkRaw != null ? Version.parse(sdkRaw) : null;

  final validationResults = <LowerBoundValidationResult>[];
  var allClean = true;
  final isJson = format == 'json';

  for (final packagePath in packagePaths) {
    final isClean = await _runSinglePackage(
      packagePath: packagePath,
      targets: targets,
      pin: pin,
      keepTemp: keepTemp,
      sdkOverride: sdkOverride,
      isJson: isJson,
      out: out,
      results: validationResults,
    );
    if (!isClean) {
      allClean = false;
    }
  }

  if (!isJson) {
    out.writeln();
  }

  _renderResults(
    format: format,
    results: validationResults,
    sink: out,
    commentOutput: commentOutput,
    maxCommentRows: maxCommentRows,
  );

  if (failOnError && !allClean) {
    return ExitCode.software.code;
  }
  return ExitCode.success.code;
}

Future<bool> _runSinglePackage({
  required String packagePath,
  required List<String> targets,
  required bool pin,
  required bool keepTemp,
  required Version? sdkOverride,
  required bool isJson,
  required StringSink out,
  required List<LowerBoundValidationResult> results,
}) async {
  final packageName = p.basename(packagePath);
  if (!isJson) {
    out.write('Validating lower bounds for $packageName... ');
  }

  try {
    final res = await validatePackageLowerBounds(
      packagePath: packagePath,
      targets: targets,
      keepTemp: keepTemp,
      pinExactFloors: pin,
      sdkOverride: sdkOverride,
    );

    results.add(res);
    if (!isJson) {
      out.writeln(res.isClean ? '✓ PASS' : '✗ FAIL');
    }
    return res.isClean;
  } catch (e) {
    if (!isJson) {
      out.writeln('✗ ERROR: $e');
    }
    return false;
  }
}

void _renderResults({
  required String format,
  required List<LowerBoundValidationResult> results,
  required StringSink sink,
  required String? commentOutput,
  required int maxCommentRows,
}) {
  if (commentOutput != null && commentOutput.isNotEmpty) {
    final commentReport = buildMarkdownReport(
      results,
      maxCommentRows: maxCommentRows,
    );
    try {
      File(commentOutput).writeAsStringSync(commentReport);
    } catch (_) {}
  }

  switch (format) {
    case 'json':
      renderJson(results, sink);
      break;
    case 'github':
      renderGitHub(
        results,
        sink,
        commentOutputFile: commentOutput,
        maxCommentRows: maxCommentRows,
      );
      break;
    case 'text':
    default:
      renderText(results, sink);
      break;
  }
}
