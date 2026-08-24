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

  final filePath = resolved.toFilePath();
  final relativeInLib = uri.pathSegments.sublist(1).join('/');
  final libDir = (relativeInLib.isNotEmpty && filePath.endsWith(relativeInLib))
      ? filePath.substring(0, filePath.length - relativeInLib.length)
      : p.dirname(filePath);

  return p.normalize(p.join(libDir, '..'));
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
Future<String> resolvePackageExecutable(
  String packageUri, [
  String? executableName,
]) async {
  final pkgDir = await resolvePackageDirectory(packageUri);
  final exec = executableName ?? Uri.parse(packageUri).pathSegments.first;
  final binFile = File(p.join(pkgDir, 'bin', '$exec.dart'));
  return p.normalize(binFile.path);
}
