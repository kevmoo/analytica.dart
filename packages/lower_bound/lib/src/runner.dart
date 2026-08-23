import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import 'models.dart';
import 'pubspec_helper.dart';
import 'sdk_discovery.dart';
import 'synthetic_staging.dart';

/// Core runner for lower-bound validation.
class LowerBoundRunner {
  /// Validates the lower bounds of the package at [packagePath].
  static Future<LowerBoundValidationResult> validate({
    required String packagePath,
    List<String> targets = const ['lib', 'bin'],
    bool keepTemp = false,
    bool pinExactFloors = true,
    Version? sdkOverride,
    Map<String, LocalSibling>? localSiblings,
    Directory? baseTempDir,
  }) async {
    final parsed = PubspecHelper.parse(packagePath);
    final targetSdk = sdkOverride ?? parsed.minSdk;

    if (parsed.dependencies.isEmpty) {
      return _emptyDependencyResult(parsed.name, packagePath, targetSdk);
    }

    final staging = SyntheticStaging.create(
      sourcePackagePath: packagePath,
      pubspec: parsed,
      baseTempDir: baseTempDir,
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

  static LowerBoundValidationResult _emptyDependencyResult(
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

  static LowerBoundValidationResult _failedPubGetResult({
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

  static List<DependencyFloor> _effectiveDependencies(
    ParsedPubspec parsed,
    SyntheticStaging staging,
  ) {
    return staging.resolvedFloorMetadata.isNotEmpty
        ? staging.resolvedFloorMetadata
        : parsed.dependencies;
  }

  static Future<String?> _runStagedPubResolution({
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

  static Map<String, Version> _readResolvedVersions(SyntheticStaging staging) {
    final raw = staging.readResolvedVersions();
    final result = <String, Version>{};
    for (final entry in raw.entries) {
      try {
        result[entry.key] = Version.parse(entry.value);
      } catch (_) {}
    }
    return result;
  }

  static List<String> _resolveTargets(
    String stagingPath,
    List<String> targets,
  ) {
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

  static List<String> _parseAnalyzerErrors(ProcessResult result) {
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

  static bool _isDiagnosticLine(String line) {
    return line.isNotEmpty &&
        (line.startsWith('error -') ||
            line.startsWith('warning -') ||
            line.contains('error •') ||
            line.contains('warning •') ||
            line.contains('error:'));
  }

  static void _cleanupStaging(
    SyntheticStaging staging, {
    required bool keepTemp,
  }) {
    if (!keepTemp) {
      staging.dispose();
    } else {
      stdout.writeln('Preserved staging directory: ${staging.stagingDir.path}');
    }
  }

  static Future<ProcessResult> _runPubGet({
    required String workingDirectory,
    required Version simulatedSdk,
  }) async {
    return Process.run(
      SdkDiscovery.dartExecutable,
      ['pub', 'get'],
      workingDirectory: workingDirectory,
      environment: {'_PUB_TEST_SDK_VERSION': simulatedSdk.toString()},
    );
  }

  static Future<ProcessResult> _runPubDowngrade({
    required String workingDirectory,
    required Version simulatedSdk,
  }) async {
    return Process.run(
      SdkDiscovery.dartExecutable,
      ['pub', 'downgrade'],
      workingDirectory: workingDirectory,
      environment: {'_PUB_TEST_SDK_VERSION': simulatedSdk.toString()},
    );
  }

  static Future<ProcessResult> _runDartAnalyze({
    required String workingDirectory,
    required List<String> targets,
  }) async {
    return Process.run(SdkDiscovery.dartExecutable, [
      'analyze',
      ...targets,
    ], workingDirectory: workingDirectory);
  }
}
