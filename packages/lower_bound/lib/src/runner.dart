import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import 'models.dart';
import 'pubspec_helper.dart';
import 'sdk_discovery.dart';
import 'synthetic_staging.dart';

/// Validates the lower bounds of the package at [packagePath].
///
/// Simulates minimum dependency resolution by executing `pub downgrade` in an
/// isolated synthetic directory (with `dev_dependencies` and workspace
/// boundaries removed), followed by static analysis.
///
/// Note: When [sdkOverride] is passed, `_PUB_TEST_SDK_VERSION` is set for pub
/// resolution only. Static analysis runs using the local ambient Dart SDK.
Future<LowerBoundValidationResult> validatePackageLowerBounds({
  required String packagePath,
  List<String> targets = const ['lib', 'bin'],
  bool keepTemp = false,
  bool allowLocalSiblings = false,
  Version? sdkOverride,
  Map<String, LocalSibling>? localSiblings,
  Directory? baseTempDir,
  StringSink? errSink,
}) async {
  final parsed = parsePubspec(packagePath);
  final targetSdk = sdkOverride ?? parsed.minSdk;

  if (parsed.dependencies.isEmpty) {
    return _emptyDependencyResult(parsed.name, packagePath, targetSdk);
  }

  final staging = SyntheticStaging.create(
    sourcePackagePath: packagePath,
    pubspec: parsed,
    baseTempDir: baseTempDir,
    localSiblings: localSiblings,
  );

  try {
    final resolutionError = await _runStagedPubDowngrade(
      staging: staging,
      targetSdk: targetSdk,
      allowLocalSiblings: allowLocalSiblings,
    );

    if (resolutionError != null) {
      return _failedPubGetResult(
        parsed: parsed,
        packagePath: packagePath,
        targetSdk: targetSdk,
        staging: staging,
        errorMsg: resolutionError,
      );
    }

    final resolvedVersions = _readResolvedVersions(staging);
    final validTargets = _resolveTargets(staging.stagingDir.path, targets);

    final analyzeResult = await _runDartAnalyze(
      workingDirectory: staging.stagingDir.path,
      targets: validTargets,
    );

    final diagnostics = _parseDiagnostics(
      analyzeResult,
      staging.stagingDir.path,
    );
    final analyzeSuccess = diagnostics.every((d) => !d.isError);

    return LowerBoundValidationResult(
      packageName: parsed.name,
      packagePath: packagePath,
      minSdk: targetSdk,
      dependencies: _effectiveDependencies(parsed, staging),
      resolvedVersions: resolvedVersions,
      pubGetSuccess: true,
      analyzeSuccess: analyzeSuccess,
      diagnostics: diagnostics,
      warnings: staging.warnings,
    );
  } finally {
    _cleanupStaging(staging, keepTemp: keepTemp, errSink: errSink);
  }
}

LowerBoundValidationResult _emptyDependencyResult(
  String name,
  String path,
  Version sdk,
) {
  return LowerBoundValidationResult(
    packageName: name,
    packagePath: path,
    minSdk: sdk,
    dependencies: const [],
    resolvedVersions: const {},
    pubGetSuccess: true,
    analyzeSuccess: true,
  );
}

LowerBoundValidationResult _failedPubGetResult({
  required ParsedPubspec parsed,
  required String packagePath,
  required Version targetSdk,
  required SyntheticStaging staging,
  required String errorMsg,
}) {
  return LowerBoundValidationResult(
    packageName: parsed.name,
    packagePath: packagePath,
    minSdk: targetSdk,
    dependencies: _effectiveDependencies(parsed, staging),
    resolvedVersions: const {},
    pubGetSuccess: false,
    pubGetError: errorMsg,
    analyzeSuccess: false,
    warnings: staging.warnings,
  );
}

List<DependencyFloor> _effectiveDependencies(
  ParsedPubspec parsed,
  SyntheticStaging staging,
) {
  return staging.resolvedFloorMetadata.isNotEmpty
      ? staging.resolvedFloorMetadata
      : parsed.dependencies;
}

Future<String?> _runStagedPubDowngrade({
  required SyntheticStaging staging,
  required Version targetSdk,
  required bool allowLocalSiblings,
}) async {
  staging.writePubspec(allowLocalSiblings: allowLocalSiblings);
  final downgradeResult = await _runPubDowngrade(
    workingDirectory: staging.stagingDir.path,
    simulatedSdk: targetSdk,
  );

  if (downgradeResult.exitCode != 0) {
    final stderrStr = downgradeResult.stderr.toString().trim();
    final stdoutStr = downgradeResult.stdout.toString().trim();
    return stderrStr.isNotEmpty ? stderrStr : stdoutStr;
  }

  return null;
}

Map<String, Version> _readResolvedVersions(SyntheticStaging staging) {
  final raw = staging.readResolvedVersions();
  final result = <String, Version>{};
  for (final entry in raw.entries) {
    try {
      result[entry.key] = Version.parse(entry.value);
    } catch (_) {}
  }
  return result;
}

List<String> _resolveTargets(String stagingPath, List<String> targets) {
  final validTargets = <String>[];
  for (final target in targets) {
    final entity = Directory(p.join(stagingPath, target));
    final file = File(p.join(stagingPath, target));
    if (entity.existsSync() || file.existsSync()) {
      validTargets.add(target);
    }
  }
  return validTargets.isEmpty ? const ['.'] : validTargets;
}

List<LowerBoundDiagnostic> _parseDiagnostics(
  ProcessResult result,
  String stagingPath,
) {
  final raw = result.stdout.toString().trim();
  if (raw.isEmpty) return const [];

  try {
    final json = jsonDecode(raw);
    if (json is Map<String, Object?> && json['diagnostics'] is List) {
      final list = json['diagnostics'] as List;
      final parsed = <LowerBoundDiagnostic>[];
      for (final item in list) {
        if (item is Map<String, Object?>) {
          final diag = _parseJsonDiagnostic(item, stagingPath);
          if (diag != null) parsed.add(diag);
        }
      }
      return parsed;
    }
  } catch (_) {}

  return _fallbackDiagnostics(raw);
}

LowerBoundDiagnostic? _parseJsonDiagnostic(
  Map<String, Object?> item,
  String stagingPath,
) {
  final message = item['problemMessage'] as String? ?? '';
  final severity = item['severity'] as String? ?? 'ERROR';
  final location = item['location'] as Map<String, Object?>?;

  String? relativeFile;
  int? line;
  int? column;

  if (location != null) {
    final filePath = location['file'] as String?;
    if (filePath != null) {
      relativeFile = p.isWithin(stagingPath, filePath)
          ? p.relative(filePath, from: stagingPath)
          : filePath;
    }
    final range = location['range'] as Map<String, Object?>?;
    final start = range?['start'] as Map<String, Object?>?;
    line = start?['line'] as int?;
    column = start?['column'] as int?;
  }

  return LowerBoundDiagnostic(
    message: message,
    file: relativeFile,
    line: line,
    column: column,
    severity: severity,
  );
}

List<LowerBoundDiagnostic> _fallbackDiagnostics(String output) {
  final lines = output.split('\n');
  final result = <LowerBoundDiagnostic>[];
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty) {
      final isErr =
          trimmed.startsWith('error -') ||
          trimmed.contains('error •') ||
          trimmed.contains('error:');
      result.add(
        LowerBoundDiagnostic(
          message: trimmed,
          severity: isErr ? 'ERROR' : 'WARNING',
        ),
      );
    }
  }
  return result;
}

void _cleanupStaging(
  SyntheticStaging staging, {
  required bool keepTemp,
  StringSink? errSink,
}) {
  if (!keepTemp) {
    staging.dispose();
  } else {
    (errSink ?? stderr).writeln(
      'Preserved staging directory: ${staging.stagingDir.path}',
    );
  }
}

Future<ProcessResult> _runPubDowngrade({
  required String workingDirectory,
  required Version simulatedSdk,
}) async {
  return Process.run(
    dartExecutable,
    ['pub', 'downgrade'],
    workingDirectory: workingDirectory,
    environment: {'_PUB_TEST_SDK_VERSION': simulatedSdk.toString()},
  );
}

Future<ProcessResult> _runDartAnalyze({
  required String workingDirectory,
  required List<String> targets,
}) async {
  return Process.run(dartExecutable, [
    'analyze',
    '--format=json',
    ...targets,
  ], workingDirectory: workingDirectory);
}
