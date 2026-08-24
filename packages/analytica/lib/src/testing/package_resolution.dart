import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

/// Resolves the root directory path of a package given a [packageUri] string
/// (e.g. `'package:undead/undead.dart'`).
///
/// Traverses up from the resolved `lib/` directory to locate the package root.
Future<String> resolvePackageDirectory(String packageUri) async {
  final uri = Uri.parse(packageUri);
  if (!uri.isScheme('package') || uri.pathSegments.isEmpty) {
    throw ArgumentError.value(
      packageUri,
      'packageUri',
      'Must be a valid package: URI (e.g. "package:pkg/pkg.dart").',
    );
  }

  final resolved = await Isolate.resolvePackageUri(uri);
  if (resolved == null) {
    throw StateError(
      'Could not resolve package URI: "$packageUri". '
      'Ensure the package is declared in dependencies or dev_dependencies.',
    );
  }

  var currentDir = p.dirname(resolved.toFilePath());
  // The path inside lib/ has (uri.pathSegments.length - 1) segments.
  // Climbing up (uri.pathSegments.length - 1) times from the file's parent
  // directory reaches the package root across all platform path separators.
  for (var i = 1; i < uri.pathSegments.length; i++) {
    currentDir = p.dirname(currentDir);
  }
  return p.normalize(currentDir);
}

/// Resolves a [File] relative to a package root given a [packageUri] string
/// and a [relativePath] (e.g. `'pubspec.yaml'`).
Future<File> resolvePackageFile(String packageUri, String relativePath) async {
  final pkgDir = await resolvePackageDirectory(packageUri);
  return File(p.normalize(p.join(pkgDir, relativePath)));
}

/// Resolves the absolute path to an executable in `bin/` given a [packageUri]
/// and an optional [executableName].
///
/// If [executableName] is omitted, defaults to the package name (the first path
/// segment of [packageUri]).
///
/// Throws a [StateError] if the executable file does not exist.
Future<String> resolvePackageExecutable(
  String packageUri, [
  String? executableName,
]) async {
  final pkgDir = await resolvePackageDirectory(packageUri);
  final exec = executableName ?? Uri.parse(packageUri).pathSegments.first;
  final binFile = File(p.join(pkgDir, 'bin', '$exec.dart'));
  if (!binFile.existsSync()) {
    throw StateError(
      'Executable not found at "${binFile.path}". '
      'Ensure bin/$exec.dart exists in package "$packageUri".',
    );
  }
  return p.normalize(binFile.path);
}
