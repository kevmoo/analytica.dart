import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:io/io.dart';
import 'package:lower_bound/lower_bound.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

const String _commentMarker = '<!-- lower-bound-comment-marker -->';

Future<void> main(List<String> args) async {
  final parser = ArgParser()
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

  final ArgResults results;
  try {
    results = parser.parse(args);
  } on FormatException catch (e) {
    stderr.writeln('Error: ${e.message}');
    stderr.writeln(parser.usage);
    exit(ExitCode.usage.code);
  }

  if (results.flag('help')) {
    stdout.writeln(
      'Validate Dart package compilation against dependency lower bounds.',
    );
    stdout.writeln();
    stdout.writeln('Usage: lower_bound [options] [package_path]');
    stdout.writeln();
    stdout.writeln(parser.usage);
    exit(ExitCode.success.code);
  }

  final targets = results.multiOption('targets');
  final pin = results.flag('pin');
  final keepTemp = results.flag('keep-temp');
  final failOnError = results.flag('fail-on-error');
  final format = results.option('format') ?? 'text';
  final commentOutput = results.option('comment-output');
  final maxRowsRaw = results.option('max-comment-rows');
  final maxCommentRows = int.tryParse(maxRowsRaw ?? '0') ?? 0;
  final sdkRaw = results.option('sdk');
  final sdkOverride = sdkRaw != null ? Version.parse(sdkRaw) : null;

  final packagePaths = <String>[];

  if (results.rest.isNotEmpty) {
    // Explicit paths provided
    for (final rawPath in results.rest) {
      final dir = Directory(rawPath);
      if (!dir.existsSync()) {
        stderr.writeln('Directory does not exist: $rawPath');
        exit(ExitCode.noInput.code);
      }
      final pubspecFile = File(p.join(dir.path, 'pubspec.yaml'));
      if (!pubspecFile.existsSync()) {
        stderr.writeln('No pubspec.yaml found in $rawPath');
        exit(ExitCode.noInput.code);
      }
      packagePaths.add(p.normalize(p.absolute(dir.path)));
    }
  } else {
    // Current directory resolution (either single package or pub workspace)
    final cwd = Directory.current.path;
    final pubspecFile = File(p.join(cwd, 'pubspec.yaml'));
    if (!pubspecFile.existsSync()) {
      stderr.writeln('No pubspec.yaml found in current directory: $cwd');
      exit(ExitCode.noInput.code);
    }

    final parsed = PubspecHelper.parse(cwd);
    if (parsed.isWorkspaceRoot) {
      for (final member in parsed.workspace!) {
        final memberDir = Directory(p.join(cwd, member));
        final memberPubspec = File(p.join(memberDir.path, 'pubspec.yaml'));
        if (memberDir.existsSync() && memberPubspec.existsSync()) {
          packagePaths.add(p.normalize(p.absolute(memberDir.path)));
        }
      }
    } else {
      packagePaths.add(p.normalize(p.absolute(cwd)));
    }
  }

  if (packagePaths.isEmpty) {
    stderr.writeln('No Dart packages found to validate.');
    exit(ExitCode.noInput.code);
  }

  final validationResults = <LowerBoundValidationResult>[];
  var allPassed = true;

  for (final packagePath in packagePaths) {
    final packageName = p.basename(packagePath);
    if (format != 'json') {
      stdout.write('Validating lower bounds for $packageName... ');
    }

    try {
      final res = await LowerBoundRunner.validate(
        packagePath: packagePath,
        targets: targets,
        keepTemp: keepTemp,
        pinExactFloors: pin,
        sdkOverride: sdkOverride,
      );

      validationResults.add(res);

      if (format != 'json') {
        if (res.isClean) {
          stdout.writeln('✓ PASS');
        } else {
          stdout.writeln('✗ FAIL');
        }
      }
      if (!res.isClean) {
        allPassed = false;
      }
    } catch (e) {
      if (format != 'json') {
        stdout.writeln('✗ ERROR: $e');
      }
      allPassed = false;
    }
  }

  if (format != 'json') {
    stdout.writeln();
  }

  if (commentOutput != null && commentOutput.isNotEmpty) {
    _writeCommentOutput(
      commentOutput,
      validationResults,
      maxRows: maxCommentRows,
    );
  }

  switch (format) {
    case 'json':
      _renderJson(validationResults);
      break;
    case 'github':
      _renderGitHub(validationResults);
      break;
    case 'text':
    default:
      _renderText(validationResults);
      break;
  }

  if (!allPassed && failOnError) {
    exit(1);
  }
  exit(ExitCode.success.code);
}

void _renderText(List<LowerBoundValidationResult> results) {
  for (final result in results) {
    stdout.writeln('=== Package: ${result.packageName} ===');
    stdout.writeln('Path: ${result.packagePath}');
    stdout.writeln('SDK Floor: ${result.minSdk}');

    if (!result.pubGetSuccess) {
      stdout.writeln('Status: FAILED (pub resolution failed)');
      stdout.writeln('Error: ${result.pubGetError}');
    } else if (!result.analyzeSuccess) {
      stdout.writeln('Status: FAILED (static analysis errors at lower bound)');
      stdout.writeln('Diagnostics:');
      for (final err in result.analyzerErrors) {
        stdout.writeln('  $err');
      }
    } else {
      stdout.writeln('Status: PASSED');
    }

    if (result.warnings.isNotEmpty) {
      stdout.writeln('Warnings:');
      for (final w in result.warnings) {
        stdout.writeln('  [!] $w');
      }
    }

    if (result.dependencies.isNotEmpty) {
      stdout.writeln('Dependency Resolution Floor:');
      for (final dep in result.dependencies) {
        final resolved = result.resolvedVersions[dep.name] ?? 'unresolved';
        final isExactFloor =
            dep.lowerBound != null &&
            resolved.toString() == dep.lowerBound.toString();
        final flag = dep.isLocalPathOverride ? '~' : (isExactFloor ? '✓' : '~');
        final namePad = dep.name.padRight(20);
        final declPad = dep.declaredConstraint.toString().padRight(16);
        final floorPad = (dep.lowerBound?.toString() ?? 'any').padRight(10);
        final extraNote = dep.isLocalPathOverride
            ? ' (local path override: ${dep.localVersion ?? "wip"})'
            : '';
        stdout.writeln(
          '  $flag $namePad declared: $declPad floor: $floorPad '
          'resolved: $resolved$extraNote',
        );
      }
    }
    stdout.writeln();
  }
}

void _renderGitHub(List<LowerBoundValidationResult> results) {
  for (final result in results) {
    if (!result.pubGetSuccess) {
      emitGitHubError(
        'Dependency resolution failed at floor: ${result.pubGetError}',
        file: p.join(result.packagePath, 'pubspec.yaml'),
      );
    } else if (!result.analyzeSuccess) {
      for (final err in result.analyzerErrors) {
        emitGitHubError(
          err,
          file: p.join(result.packagePath, 'pubspec.yaml'),
          title: 'Lower Bound Compile Error',
        );
      }
    }
  }

  final fullReport = _buildMarkdownReport(results, maxRows: 0);
  appendGitHubStepSummary(fullReport);
  _renderText(results);
}

void _writeCommentOutput(
  String outputPath,
  List<LowerBoundValidationResult> results, {
  int maxRows = 0,
}) {
  final content = _buildMarkdownReport(results, maxRows: maxRows);
  final file = File(outputPath);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}

String _buildMarkdownReport(
  List<LowerBoundValidationResult> results, {
  int maxRows = 0,
}) {
  final buffer = StringBuffer();
  buffer.writeln(_commentMarker);
  buffer.writeln('## 📦 Dependency Lower-Bound Validation Summary');
  buffer.writeln();

  var totalRows = 0;
  for (final r in results) {
    totalRows += r.dependencies.length;
  }

  var rowsWritten = 0;
  final rowLimit = maxRows > 0 ? maxRows : totalRows;

  for (final result in results) {
    final statusIcon = result.isClean ? '✅' : '❌';
    buffer.writeln('### $statusIcon `${result.packageName}`');
    buffer.writeln('* **SDK Floor**: `${result.minSdk}`');
    buffer.writeln('* **Status**: ${result.isClean ? "Clean" : "**Failed**"}');
    buffer.writeln();

    if (!result.pubGetSuccess) {
      buffer.writeln('> [!CAUTION]');
      buffer.writeln('> **Pub Resolution Error**:');
      buffer.writeln('> ```');
      buffer.writeln('> ${result.pubGetError}');
      buffer.writeln('> ```');
      buffer.writeln();
    } else if (!result.analyzeSuccess) {
      buffer.writeln('> [!WARNING]');
      buffer.writeln('> **Static Analysis Errors at Dependency Floor**:');
      buffer.writeln('> ```');
      for (final err in result.analyzerErrors) {
        buffer.writeln('> $err');
      }
      buffer.writeln('> ```');
      buffer.writeln();
    }

    if (result.warnings.isNotEmpty) {
      buffer.writeln('> [!NOTE]');
      for (final w in result.warnings) {
        buffer.writeln('> * $w');
      }
      buffer.writeln();
    }

    if (result.dependencies.isNotEmpty) {
      buffer.writeln(
        '| Dependency | Declared Constraint | Declared Floor | '
        'Resolved Version | Status |',
      );
      buffer.writeln('| :--- | :--- | :--- | :--- | :---: |');

      for (final dep in result.dependencies) {
        if (rowsWritten >= rowLimit) break;
        final resolved = result.resolvedVersions[dep.name] ?? 'unresolved';
        final String status;
        if (dep.isLocalPathOverride) {
          status = 'Local Sibling (${dep.localVersion ?? "wip"})';
        } else if (dep.lowerBound != null &&
            resolved.toString() == dep.lowerBound.toString()) {
          status = 'Exact Floor';
        } else {
          status = 'Satisfied';
        }
        final floorStr = dep.lowerBound?.toString() ?? 'any';
        buffer.writeln(
          '| `${dep.name}` | `${dep.declaredConstraint}` | '
          '`$floorStr` | `$resolved` | $status |',
        );
        rowsWritten++;
      }
      buffer.writeln();
    }
  }

  if (maxRows > 0 && totalRows > maxRows) {
    buffer.writeln(
      '*Showing $maxRows of $totalRows dependencies. '
      'Full report available in Step Summary.*',
    );
    buffer.writeln();
  }

  return buffer.toString();
}

void _renderJson(List<LowerBoundValidationResult> results) {
  final jsonList = results.map((r) => r.toJson()).toList();
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(jsonList));
}
