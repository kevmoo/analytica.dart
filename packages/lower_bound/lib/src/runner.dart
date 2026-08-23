import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import 'models.dart';
import 'pubspec_helper.dart';
import 'sdk_discovery.dart';
import 'synthetic_staging.dart';

/// Validates the lower bounds of the package at [packagePath].
Future<LowerBoundValidationResult> validatePackageLowerBounds({
  required String packagePath,
  List<String> targets = const ['lib', 'bin'],
  bool keepTemp = false,
  bool pinExactFloors = true,
  Version? sdkOverride,
  Map<String, LocalSibling>? localSiblings,
  Directory? baseTempDir,
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
    final resolutionError = await _runStagedPubResolution(
      staging: staging,
      targetSdk: targetSdk,
      pinExactFloors: pinExactFloors,
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

    final analyzerErrors = _parseAnalyzerErrors(analyzeResult);

    return LowerBoundValidationResult(
      packageName: parsed.name,
      packagePath: packagePath,
      minSdk: targetSdk,
      dependencies: _effectiveDependencies(parsed, staging),
      resolvedVersions: resolvedVersions,
      pubGetSuccess: true,
      analyzeSuccess: analyzeResult.exitCode == 0,
      analyzerErrors: analyzerErrors,
      warnings: staging.warnings,
    );
  } finally {
    _cleanupStaging(staging, keepTemp: keepTemp);
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

Future<String?> _runStagedPubResolution({
  required SyntheticStaging staging,
  required Version targetSdk,
  required bool pinExactFloors,
}) async {
  staging.writePubspec(pinLowerBounds: pinExactFloors);
  var pubGetResult = await _runPubGet(
    workingDirectory: staging.stagingDir.path,
    simulatedSdk: targetSdk,
  );

  if (pubGetResult.exitCode != 0 && pinExactFloors) {
    staging.writePubspec(pinLowerBounds: false);
    pubGetResult = await _runPubDowngrade(
      workingDirectory: staging.stagingDir.path,
      simulatedSdk: targetSdk,
    );
  }

  if (pubGetResult.exitCode != 0) {
    final stderrStr = pubGetResult.stderr.toString().trim();
    final stdoutStr = pubGetResult.stdout.toString().trim();
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

List<String> _parseAnalyzerErrors(ProcessResult result) {
  if (result.exitCode == 0) return const [];

  final errors = <String>[];
  final lines = result.stdout.toString().split('\n');

  for (final line in lines) {
    final trimmed = line.trim();
    if (_isDiagnosticLine(trimmed)) {
      errors.add(trimmed);
    }
  }

  if (errors.isEmpty && lines.isNotEmpty) {
    errors.addAll(lines.where((l) => l.trim().isNotEmpty).take(20));
  }

  return errors;
}

bool _isDiagnosticLine(String line) {
  return line.isNotEmpty &&
      (line.startsWith('error -') ||
          line.startsWith('warning -') ||
          line.contains('error •') ||
          line.contains('warning •') ||
          line.contains('error:'));
}

void _cleanupStaging(SyntheticStaging staging, {required bool keepTemp}) {
  if (!keepTemp) {
    staging.dispose();
  } else {
    stdout.writeln('Preserved staging directory: ${staging.stagingDir.path}');
  }
}

Future<ProcessResult> _runPubGet({
  required String workingDirectory,
  required Version simulatedSdk,
}) async {
  return Process.run(
    dartExecutable,
    ['pub', 'get'],
    workingDirectory: workingDirectory,
    environment: {'_PUB_TEST_SDK_VERSION': simulatedSdk.toString()},
  );
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
    ...targets,
  ], workingDirectory: workingDirectory);
}
