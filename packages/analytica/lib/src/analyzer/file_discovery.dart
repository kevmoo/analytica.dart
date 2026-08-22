import 'dart:io';

import 'package:path/path.dart' as p;

import 'glob_matcher.dart';

/// Standard code-generation, binding, and test mock exclusions for Dart
/// analysis.
const List<String> defaultDartExclusions = [
  '**/*.g.dart',
  '**/*.freezed.dart',
  '**/*.pb.dart',
  '**/*.pbjson.dart',
  '**/*.pbenum.dart',
  '**/*.pbserver.dart',
  '**/*_bindings.dart',
  '**/native_*.dart',
  '**/jni_*.dart',
  '**/*.mocks.dart',
  '**/*.config.dart',
];

/// Discovers Dart source files under [rootPath] applying include/exclude
/// filters.
///
/// If [targets] is provided, searches only within those relative subdirectories
/// or file paths within [rootPath].
///
/// Excludes [defaultDartExclusions] by default unless [excludePatterns] is
/// explicitly provided.
List<String> discoverDartFiles(
  String rootPath, {
  List<String>? targets,
  List<String>? excludePatterns,
  List<String>? includePatterns,
}) {
  final targetDir = Directory(p.normalize(p.absolute(rootPath)));
  if (!targetDir.existsSync()) {
    return const [];
  }

  final excludes = (excludePatterns ?? defaultDartExclusions)
      .map(WildcardPattern.new)
      .toList();
  final includes = (includePatterns ?? const ['**/*.dart'])
      .map(WildcardPattern.new)
      .toList();

  final discovered = <String>{};
  final searchTargets = targets ?? const ['.'];

  for (final target in searchTargets) {
    _collectFromTarget(
      targetDir: targetDir,
      target: target,
      includes: includes,
      excludes: excludes,
      discovered: discovered,
    );
  }

  final result = discovered.toList()..sort();
  return result;
}

void _collectFromTarget({
  required Directory targetDir,
  required String target,
  required List<WildcardPattern> includes,
  required List<WildcardPattern> excludes,
  required Set<String> discovered,
}) {
  final fullPath = p.normalize(p.join(targetDir.path, target));
  final type = FileSystemEntity.typeSync(fullPath);

  if (type == FileSystemEntityType.file) {
    if (_matchesFilters(fullPath, targetDir.path, includes, excludes)) {
      discovered.add(fullPath);
    }
  } else if (type == FileSystemEntityType.directory) {
    _collectFromDirectory(
      dir: Directory(fullPath),
      rootDirPath: targetDir.path,
      includes: includes,
      excludes: excludes,
      discovered: discovered,
    );
  }
}

void _collectFromDirectory({
  required Directory dir,
  required String rootDirPath,
  required List<WildcardPattern> includes,
  required List<WildcardPattern> excludes,
  required Set<String> discovered,
}) {
  for (final entity in dir.listSync(recursive: true, followLinks: false)) {
    if (entity is File &&
        _matchesFilters(entity.path, rootDirPath, includes, excludes)) {
      discovered.add(entity.path);
    }
  }
}

bool _matchesFilters(
  String filePath,
  String rootDirPath,
  List<WildcardPattern> includes,
  List<WildcardPattern> excludes,
) {
  if (!filePath.endsWith('.dart')) return false;

  final relPath = p.normalize(p.relative(filePath, from: rootDirPath));
  final forwardRelPath = relPath.replaceAll(r'\', '/');
  final rootedPath = '/$forwardRelPath';
  final basename = p.basename(filePath);

  // Check exclude patterns first
  for (final pattern in excludes) {
    if (pattern.matches(forwardRelPath) ||
        pattern.matches(rootedPath) ||
        pattern.matches(basename)) {
      return false;
    }
  }

  // Check include patterns
  for (final pattern in includes) {
    if (pattern.matches(forwardRelPath) ||
        pattern.matches(rootedPath) ||
        pattern.matches(basename)) {
      return true;
    }
  }

  return false;
}
