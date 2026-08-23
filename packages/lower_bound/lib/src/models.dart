import 'package:pub_semver/pub_semver.dart';

/// Represents a static analysis diagnostic emitted during lower-bound analysis.
class LowerBoundDiagnostic {
  final String message;
  final String? file;
  final int? line;
  final int? column;
  final String severity;

  const LowerBoundDiagnostic({
    required this.message,
    this.file,
    this.line,
    this.column,
    required this.severity,
  });

  bool get isError => severity.toUpperCase() == 'ERROR';
  bool get isWarning => severity.toUpperCase() == 'WARNING';

  Map<String, Object?> toJson() {
    return {
      'message': message,
      if (file != null) 'file': file,
      if (line != null) 'line': line,
      if (column != null) 'column': column,
      'severity': severity,
    };
  }

  @override
  String toString() {
    final filePart = file ?? '';
    final linePart = line != null ? ':$line' : '';
    final colPart = column != null ? ':$column' : '';
    final loc = file != null ? '$filePart$linePart$colPart: ' : '';
    return '$loc$message';
  }
}

/// Represents the declared and floor constraints for a single dependency.
class DependencyFloor {
  final String name;
  final VersionConstraint declaredConstraint;
  final Version? lowerBound;
  final bool isLocalPathOverride;
  final String? localPath;
  final String? localVersion;
  final bool isNonHosted;

  const DependencyFloor({
    required this.name,
    required this.declaredConstraint,
    required this.lowerBound,
    this.isLocalPathOverride = false,
    this.localPath,
    this.localVersion,
    this.isNonHosted = false,
  });

  Map<String, Object?> toJson() {
    return {
      'name': name,
      'declared': declaredConstraint.toString(),
      'lowerBound': lowerBound?.toString(),
      'isLocalPathOverride': isLocalPathOverride,
      'isNonHosted': isNonHosted,
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
    if (isNonHosted) {
      return '$name: $declaredConstraint (non-hosted dependency)';
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
  final List<LowerBoundDiagnostic> diagnostics;
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
    this.diagnostics = const [],
    this.warnings = const [],
  });

  bool get isClean => pubGetSuccess && analyzeSuccess;

  List<String> get analyzerErrors =>
      diagnostics.where((d) => d.isError).map((d) => d.toString()).toList();

  List<String> get analyzerWarnings =>
      diagnostics.where((d) => d.isWarning).map((d) => d.toString()).toList();

  Map<String, Object?> toJson() {
    return {
      'package': packageName,
      'path': packagePath,
      'minSdk': minSdk.toString(),
      'clean': isClean,
      'pubGetSuccess': pubGetSuccess,
      'pubGetError': pubGetError,
      'analyzeSuccess': analyzeSuccess,
      'diagnostics': diagnostics.map((d) => d.toJson()).toList(),
      'analyzerErrors': analyzerErrors,
      'warnings': warnings,
      'dependencies': {
        for (final d in dependencies)
          d.name: {
            'declared': d.declaredConstraint.toString(),
            'lowerBound': d.lowerBound?.toString(),
            'resolved': resolvedVersions[d.name]?.toString(),
            'isLocalPathOverride': d.isLocalPathOverride,
            'isNonHosted': d.isNonHosted,
            if (d.localPath != null) 'localPath': d.localPath,
            if (d.localVersion != null) 'localVersion': d.localVersion,
          },
      },
    };
  }
}
