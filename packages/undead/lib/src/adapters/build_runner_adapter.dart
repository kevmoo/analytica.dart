import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../root_harvester.dart';
import 'framework_adapter.dart';

/// Adapter for build_runner packages, discovering builder factories in
/// `build.yaml`.
class BuildRunnerAdapter extends BaseFrameworkAdapter {
  const BuildRunnerAdapter();

  @override
  Set<String> harvestRoots({
    required PackageTopology topology,
    required Directory packageDir,
    required String pubspecContent,
  }) {
    return extractBuilderFactories(packageDir.path);
  }

  /// Extracts builder factory identifiers declared in `build.yaml` at
  /// [packagePath].
  static Set<String> extractBuilderFactories(String packagePath) {
    final buildYaml = File(p.join(packagePath, 'build.yaml'));
    if (!buildYaml.existsSync()) return const {};

    try {
      final content = buildYaml.readAsStringSync();
      final doc = loadYaml(content);
      final results = <String>{};
      _collectBuilderFactories(doc, results);
      return results;
    } catch (_) {
      return const {};
    }
  }

  static void _collectBuilderFactories(Object? node, Set<String> results) {
    if (node is List) {
      for (final item in node) {
        _collectBuilderFactories(item, results);
      }
      return;
    }
    if (node is! Map) return;
    for (final entry in node.entries) {
      if (entry.key?.toString() == 'builder_factories') {
        _addFactoryValues(entry.value, results);
      } else {
        _collectBuilderFactories(entry.value, results);
      }
    }
  }

  static void _addFactoryValues(Object? val, Set<String> results) {
    if (val is String) {
      final str = val.trim();
      if (str.isNotEmpty) results.add(str);
      return;
    }
    if (val is! List) return;
    for (final item in val) {
      if (item == null) continue;
      final str = item.toString().trim();
      if (str.isNotEmpty) results.add(str);
    }
  }
}
