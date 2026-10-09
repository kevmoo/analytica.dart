// Trimmed from kevmoo/pubviz `lib/src/service.dart` at f50f9fb.
//
// Expected: `_loadPackageGraphFile` and `_loadPackageConfigFile` are
// SIBLING_STEP (they share `load`+`Package` and are called back to back).
import 'dart:convert';
import 'dart:io';

class Service {
  final String rootPackageDir;

  Service(this.rootPackageDir);

  File _findDartToolFile(String fileName, {required bool ascend}) {
    final file = File('$rootPackageDir/.dart_tool/$fileName');
    if (file.existsSync()) return file;
    throw FileSystemException(
      'Could not find `.dart_tool/$fileName` in "$rootPackageDir"'
      '${ascend ? ' or any of its parent directories' : ''}. '
      'Run `dart pub get` first.',
    );
  }

  /// Loads and parses the `.dart_tool/package_graph.json` file.
  _PackageGraphFile _loadPackageGraphFile({required bool ascend}) {
    final file = _findDartToolFile('package_graph.json', ascend: ascend);
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    return _PackageGraphFile.fromJson(json);
  }

  /// Loads and parses the `.dart_tool/package_config.json` file.
  _PackageConfigFile _loadPackageConfigFile({required bool ascend}) {
    final file = _findDartToolFile('package_config.json', ascend: ascend);
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final baseUri = Uri.directory(file.parent.path);
    return _PackageConfigFile.fromJson(json, baseUri: baseUri);
  }

  Future<Map<String, String>> getReferencedPackages(
    bool flagOutdated, {
    bool includeWorkspace = false,
  }) async {
    final ascend = includeWorkspace;
    final graphFile = _loadPackageGraphFile(ascend: ascend);
    final configFile = _loadPackageConfigFile(ascend: ascend);

    final map = <String, String>{};
    for (final root in graphFile.roots) {
      if (flagOutdated && !configFile.packages.containsKey(root)) continue;
      map[root] = configFile.packages[root] ?? '';
    }
    return map;
  }
}

class _PackageGraphFile {
  final List<String> roots;

  _PackageGraphFile.fromJson(Map<String, dynamic> json)
    : roots = (json['roots'] as List<dynamic>).cast<String>();
}

class _PackageConfigFile {
  final Map<String, String> packages;

  _PackageConfigFile.fromJson(Map<String, dynamic> json, {required Uri baseUri})
    : packages = {
        for (final p in json['packages'] as List<dynamic>)
          (p as Map<String, dynamic>)['name'] as String: baseUri
              .resolve(p['rootUri'] as String)
              .toString(),
      };
}
