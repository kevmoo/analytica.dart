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
      return LowerBoundValidationResult(
        packageName: parsed.name,
        packagePath: packagePath,
        minSdk: targetSdk,
        dependencies: const [],
        resolvedVersions: const {},
        pubGetSuccess: true,
        analyzeSuccess: true,
      );
    }

    final staging = SyntheticStaging.create(
      sourcePackagePath: packagePath,
      pubspec: parsed,
      baseTempDir: baseTempDir,
      localSiblings: localSiblings,
    );

    try {
      // Pass 1: Try exact lower-bound pinning
      staging.writePubspec(pinLowerBounds: pinExactFloors);

      var pubGetResult = await _runPubGet(
        workingDirectory: staging.stagingDir.path,
        simulatedSdk: targetSdk,
      );

      // If exact floor pinning had solver conflicts and pinExactFloors was
      // true, fallback to unpinned pub downgrade to see if a valid floor
      // solution exists.
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
        final errorMsg = stderrStr.isNotEmpty ? stderrStr : stdoutStr;
        return LowerBoundValidationResult(
          packageName: parsed.name,
          packagePath: packagePath,
          minSdk: targetSdk,
          dependencies: staging.resolvedFloorMetadata.isNotEmpty
              ? staging.resolvedFloorMetadata
              : parsed.dependencies,
          resolvedVersions: const {},
          pubGetSuccess: false,
          pubGetError: errorMsg,
          analyzeSuccess: false,
          warnings: staging.warnings,
        );
      }

      // Read resolved versions from staging package config
      final resolvedRaw = staging.readResolvedVersions();
      final resolvedVersions = <String, Version>{};
      for (final entry in resolvedRaw.entries) {
        try {
          resolvedVersions[entry.key] = Version.parse(entry.value);
        } catch (_) {}
      }

      // Determine existing targets inside staging directory
      final validTargets = <String>[];
      for (final target in targets) {
        final targetEntity = Directory(p.join(staging.stagingDir.path, target));
        if (targetEntity.existsSync()) {
          validTargets.add(target);
        } else {
          final targetFile = File(p.join(staging.stagingDir.path, target));
          if (targetFile.existsSync()) {
            validTargets.add(target);
          }
        }
      }

      if (validTargets.isEmpty) {
        validTargets.add('.');
      }

      // Execute static analysis in staging
      final analyzeResult = await _runDartAnalyze(
        workingDirectory: staging.stagingDir.path,
        targets: validTargets,
      );

      final analyzerErrors = <String>[];
      if (analyzeResult.exitCode != 0) {
        final stdoutLines = analyzeResult.stdout.toString().split('\n');
        for (final line in stdoutLines) {
          final trimmed = line.trim();
          if (trimmed.isNotEmpty &&
              (trimmed.startsWith('error -') ||
                  trimmed.startsWith('warning -') ||
                  trimmed.contains('error •') ||
                  trimmed.contains('warning •') ||
                  trimmed.contains('error:'))) {
            analyzerErrors.add(trimmed);
          }
        }
        if (analyzerErrors.isEmpty && stdoutLines.isNotEmpty) {
          analyzerErrors.addAll(
            stdoutLines.where((l) => l.trim().isNotEmpty).take(20),
          );
        }
      }

      return LowerBoundValidationResult(
        packageName: parsed.name,
        packagePath: packagePath,
        minSdk: targetSdk,
        dependencies: staging.resolvedFloorMetadata.isNotEmpty
            ? staging.resolvedFloorMetadata
            : parsed.dependencies,
        resolvedVersions: resolvedVersions,
        pubGetSuccess: true,
        analyzeSuccess: analyzeResult.exitCode == 0,
        analyzerErrors: analyzerErrors,
        warnings: staging.warnings,
      );
    } finally {
      if (!keepTemp) {
        staging.dispose();
      } else {
        stdout.writeln(
          'Preserved staging directory: ${staging.stagingDir.path}',
        );
      }
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
