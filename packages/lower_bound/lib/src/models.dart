import 'package:pub_semver/pub_semver.dart';

/// Represents the declared and floor constraints for a single dependency.
class DependencyFloor {
  final String name;
  final VersionConstraint declaredConstraint;
  final Version? lowerBound;
  final bool isLocalPathOverride;
  final String? localPath;
  final String? localVersion;

  const DependencyFloor({
    required this.name,
    required this.declaredConstraint,
    required this.lowerBound,
    this.isLocalPathOverride = false,
    this.localPath,
    this.localVersion,
  });

  Map<String, Object?> toJson() {
    return {
      'name': name,
      'declared': declaredConstraint.toString(),
      'lowerBound': lowerBound?.toString(),
      'isLocalPathOverride': isLocalPathOverride,
      if (localPath != null) 'localPath': localPath,
      if (localVersion != null) 'localVersion': localVersion,
    };
  }

  @override
  String toString() {
    if (isLocalPathOverride) {
      return '$name: $declaredConstraint (local path override: '
          '$localPath, version: $localVersion)';
    }
    return '$name: $declaredConstraint (floor: $lowerBound)';
  }
}

/// The result of lower-bound validation for a package.
class LowerBoundValidationResult {
  final String packageName;
  final String packagePath;
  final Version minSdk;
  final List<DependencyFloor> dependencies;
  final Map<String, Version> resolvedVersions;
  final bool pubGetSuccess;
  final String? pubGetError;
  final bool analyzeSuccess;
  final List<String> analyzerErrors;
  final List<String> warnings;

  const LowerBoundValidationResult({
    required this.packageName,
    required this.packagePath,
    required this.minSdk,
    required this.dependencies,
    required this.resolvedVersions,
    required this.pubGetSuccess,
    this.pubGetError,
    required this.analyzeSuccess,
    this.analyzerErrors = const [],
    this.warnings = const [],
  });

  bool get isClean => pubGetSuccess && analyzeSuccess;

  Map<String, Object?> toJson() {
    return {
      'package': packageName,
      'path': packagePath,
      'minSdk': minSdk.toString(),
      'clean': isClean,
      'pubGetSuccess': pubGetSuccess,
      'pubGetError': pubGetError,
      'analyzeSuccess': analyzeSuccess,
      'analyzerErrors': analyzerErrors,
      'warnings': warnings,
      'dependencies': {
        for (final d in dependencies)
          d.name: {
            'declared': d.declaredConstraint.toString(),
            'lowerBound': d.lowerBound?.toString(),
            'resolved': resolvedVersions[d.name]?.toString(),
            'isLocalPathOverride': d.isLocalPathOverride,
            if (d.localPath != null) 'localPath': d.localPath,
            if (d.localVersion != null) 'localVersion': d.localVersion,
          },
      },
    };
  }
}
