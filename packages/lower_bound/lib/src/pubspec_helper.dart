import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:pubspec_parse/pubspec_parse.dart';

import 'exceptions.dart';
import 'models.dart';

/// Metadata for a locally discovered sibling package in the repository.
class LocalSibling {
  final String name;
  final String path;
  final Version? version;
  final String? rawVersion;
  final bool isWip;
  final bool isPublishToNone;

  const LocalSibling({
    required this.name,
    required this.path,
    required this.version,
    required this.rawVersion,
    required this.isWip,
    required this.isPublishToNone,
  });
}

/// Parsed metadata from a package's pubspec.yaml.
class ParsedPubspec {
  final String name;
  final Version? version;
  final String? rawVersion;
  final String? publishTo;
  final Version minSdk;
  final VersionConstraint sdkConstraint;
  final List<DependencyFloor> dependencies;
  final Map<String, String> rawDependencies;
  final List<String>? workspace;

  const ParsedPubspec({
    required this.name,
    this.version,
    this.rawVersion,
    required this.publishTo,
    required this.minSdk,
    required this.sdkConstraint,
    required this.dependencies,
    required this.rawDependencies,
    this.workspace,
  });

  bool get isPublishable => publishTo != 'none';
  bool get isWorkspaceRoot => workspace != null && workspace!.isNotEmpty;
  bool get isWip =>
      rawVersion != null &&
      (rawVersion!.contains('-wip') || rawVersion!.contains('.wip'));
}

/// Helper for reading and parsing package pubspecs using pkg:pubspec_parse.
class PubspecHelper {
  /// Parses the pubspec.yaml at [packagePath].
  static ParsedPubspec parse(String packagePath) {
    final file = File(p.join(packagePath, 'pubspec.yaml'));
    if (!file.existsSync()) {
      throw MissingInputException('No pubspec.yaml found', path: packagePath);
    }

    final content = file.readAsStringSync();
    final Pubspec pubspec;
    try {
      pubspec = Pubspec.parse(content, sourceUrl: file.uri);
    } catch (e) {
      throw PackageResolutionException(
        'Failed to parse pubspec.yaml: $e',
        path: packagePath,
      );
    }

    final sdkConstraint = pubspec.environment['sdk'];
    if (sdkConstraint == null) {
      throw PackageResolutionException(
        'Missing environment.sdk constraint in pubspec.yaml',
        path: packagePath,
      );
    }

    final minSdk = _extractMinSdk(sdkConstraint, file.path);

    final dependencies = <DependencyFloor>[];
    final rawDependencies = <String, String>{};

    for (final entry in pubspec.dependencies.entries) {
      final depName = entry.key;
      final dep = entry.value;

      final VersionConstraint constraint;
      if (dep is HostedDependency) {
        constraint = dep.version;
      } else if (dep is PathDependency) {
        constraint = VersionConstraint.any;
      } else {
        constraint = VersionConstraint.any;
      }

      rawDependencies[depName] = constraint.toString();

      final floor = _extractFloor(constraint);
      dependencies.add(
        DependencyFloor(
          name: depName,
          declaredConstraint: constraint,
          lowerBound: floor,
        ),
      );
    }

    return ParsedPubspec(
      name: pubspec.name,
      version: pubspec.version,
      rawVersion: pubspec.version?.toString(),
      publishTo: pubspec.publishTo,
      minSdk: minSdk,
      sdkConstraint: sdkConstraint,
      dependencies: dependencies,
      rawDependencies: rawDependencies,
      workspace: pubspec.workspace,
    );
  }

  /// Discovers local sibling packages in the repository containing [startPath].
  static Map<String, LocalSibling> findLocalSiblings(String startPath) {
    final siblings = <String, LocalSibling>{};
    var searchDir = Directory(p.normalize(p.absolute(startPath)));

    // Walk upwards to find repository or workspace root
    Directory? repoRoot;
    while (true) {
      final workspacePubspec = File(p.join(searchDir.path, 'pubspec.yaml'));
      final gitDir = Directory(p.join(searchDir.path, '.git'));
      if (workspacePubspec.existsSync()) {
        try {
          final content = workspacePubspec.readAsStringSync();
          final parsed = Pubspec.parse(content);
          if (parsed.workspace != null && parsed.workspace!.isNotEmpty) {
            repoRoot = searchDir;
            break;
          }
        } catch (_) {}
      }

      if (gitDir.existsSync()) {
        repoRoot = searchDir;
        break;
      }

      final parent = searchDir.parent;
      if (parent.path == searchDir.path) break;
      searchDir = parent;
    }

    final rootDir = repoRoot ?? Directory(p.normalize(p.absolute(startPath)));
    final candidateDirs = <Directory>[];

    // Check workspace members if root is a workspace pubspec
    final rootPubspecFile = File(p.join(rootDir.path, 'pubspec.yaml'));
    if (rootPubspecFile.existsSync()) {
      try {
        final parsed = Pubspec.parse(rootPubspecFile.readAsStringSync());
        if (parsed.workspace != null) {
          for (final member in parsed.workspace!) {
            candidateDirs.add(Directory(p.join(rootDir.path, member)));
          }
        }
      } catch (_) {}
    }

    // Check packages/ subdirectory
    final packagesDir = Directory(p.join(rootDir.path, 'packages'));
    if (packagesDir.existsSync()) {
      for (final entity in packagesDir.listSync()) {
        if (entity is Directory) {
          candidateDirs.add(entity);
        }
      }
    }

    for (final dir in candidateDirs) {
      final pubspecFile = File(p.join(dir.path, 'pubspec.yaml'));
      if (pubspecFile.existsSync()) {
        try {
          final parsed = Pubspec.parse(pubspecFile.readAsStringSync());
          final rawVersion = parsed.version?.toString();
          final isWip =
              rawVersion != null &&
              (rawVersion.contains('-wip') || rawVersion.contains('.wip'));
          final isPublishNone = parsed.publishTo == 'none';

          siblings[parsed.name] = LocalSibling(
            name: parsed.name,
            path: dir.path,
            version: parsed.version,
            rawVersion: rawVersion,
            isWip: isWip,
            isPublishToNone: isPublishNone,
          );
        } catch (_) {}
      }
    }

    return siblings;
  }

  static Version _extractMinSdk(VersionConstraint constraint, String filePath) {
    return switch (constraint) {
      final Version v => v,
      VersionRange(:final min?) => min,
      _ => throw PackageResolutionException(
        'Could not determine minimum SDK from: $constraint',
        path: filePath,
      ),
    };
  }

  static Version? _extractFloor(VersionConstraint constraint) {
    return switch (constraint) {
      final Version v => v,
      VersionRange(:final min?) => min,
      _ => null,
    };
  }
}
