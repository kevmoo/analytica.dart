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
      'allow-local-siblings',
      defaultsTo: false,
      help: 'Allow unreleased local sibling packages via path overrides.',
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

  return _runValidationSuite(results, packagePaths, out, err, cwd);
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
    final expanded = _expandExplicitPath(rawPath, err);
    if (expanded == null) return null;
    paths.addAll(expanded);
  }
  return paths;
}

List<String>? _expandExplicitPath(String rawPath, StringSink err) {
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

  try {
    final parsed = parsePubspec(dir.path);
    if (parsed.isWorkspaceRoot) {
      return _expandWorkspaceMembers(dir.path, parsed.workspace!);
    }
    return [dir.path];
  } catch (e) {
    err.writeln('Failed to parse pubspec in $rawPath: $e');
    return null;
  }
}

List<String> _expandWorkspaceMembers(String rootPath, List<String> members) {
  final paths = <String>[];
  for (final member in members) {
    final memberDir = Directory(p.join(rootPath, member));
    if (memberDir.existsSync()) {
      paths.add(memberDir.path);
    }
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

  final paths = _expandWorkspaceMembers(cwd, parsed.workspace!);
  return paths.isEmpty ? null : paths;
}

Future<int> _runValidationSuite(
  ArgResults results,
  List<String> packagePaths,
  StringSink out,
  StringSink err,
  String cwd,
) async {
  final targets = _parseTargets(results.multiOption('targets'));
  final allowLocalSiblings = results.flag('allow-local-siblings');
  final keepTemp = results.flag('keep-temp');
  final failOnError = results.flag('fail-on-error');
  final format = results.option('format') ?? 'text';
  final commentOutput = results.option('comment-output');
  final maxCommentRows =
      int.tryParse(results.option('max-comment-rows') ?? '0') ?? 0;
  final sdkRaw = results.option('sdk');

  final Version? sdkOverride;
  if (sdkRaw != null && sdkRaw.isNotEmpty) {
    try {
      sdkOverride = Version.parse(sdkRaw);
    } on FormatException {
      err.writeln('Error: Invalid --sdk version string \'$sdkRaw\'.');
      return ExitCode.usage.code;
    }
  } else {
    sdkOverride = null;
  }

  final validationResults = <LowerBoundValidationResult>[];
  var allClean = true;
  final isJson = format == 'json';

  for (final packagePath in packagePaths) {
    final isClean = await _runSinglePackage(
      packagePath: packagePath,
      targets: targets,
      allowLocalSiblings: allowLocalSiblings,
      keepTemp: keepTemp,
      sdkOverride: sdkOverride,
      isJson: isJson,
      out: out,
      err: err,
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
    errSink: err,
    commentOutput: commentOutput,
    maxCommentRows: maxCommentRows,
    workspaceRoot: cwd,
  );

  if (failOnError && !allClean) {
    return ExitCode.software.code;
  }
  return ExitCode.success.code;
}

List<String> _parseTargets(List<String> rawTargets) {
  final result = <String>[];
  for (final t in rawTargets) {
    for (final part in t.split(RegExp(r'[,\s]+'))) {
      final trimmed = part.trim();
      if (trimmed.isNotEmpty) {
        result.add(trimmed);
      }
    }
  }
  return result.isEmpty ? const ['lib', 'bin'] : result;
}

Future<bool> _runSinglePackage({
  required String packagePath,
  required List<String> targets,
  required bool allowLocalSiblings,
  required bool keepTemp,
  required Version? sdkOverride,
  required bool isJson,
  required StringSink out,
  required StringSink err,
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
      allowLocalSiblings: allowLocalSiblings,
      sdkOverride: sdkOverride,
      errSink: err,
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
    err.writeln('Validation error for $packageName: $e');
    results.add(
      LowerBoundValidationResult(
        packageName: packageName,
        packagePath: packagePath,
        minSdk: sdkOverride ?? Version(0, 0, 0),
        dependencies: const [],
        resolvedVersions: const {},
        pubGetSuccess: false,
        pubGetError: e.toString(),
        analyzeSuccess: false,
        warnings: [e.toString()],
      ),
    );
    return false;
  }
}

void _renderResults({
  required String format,
  required List<LowerBoundValidationResult> results,
  required StringSink sink,
  required StringSink errSink,
  required String? commentOutput,
  required int maxCommentRows,
  required String workspaceRoot,
}) {
  if (commentOutput != null && commentOutput.isNotEmpty) {
    final commentReport = buildMarkdownReport(
      results,
      maxCommentRows: maxCommentRows,
    );
    _writeCommentFile(commentOutput, commentReport, errSink);
  }

  switch (format) {
    case 'json':
      renderJson(results, sink);
      break;
    case 'github':
      renderGitHub(results, sink, workspaceRoot: workspaceRoot);
      break;
    case 'text':
    default:
      renderText(results, sink);
      break;
  }
}

void _writeCommentFile(String filePath, String content, StringSink errSink) {
  try {
    final file = File(filePath);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  } catch (e) {
    errSink.writeln('Warning: Failed to write comment file \'$filePath\': $e');
  }
}
