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

      void extractFromNode(dynamic node) {
        if (node is Map) {
          for (final entry in node.entries) {
            if (entry.key?.toString() == 'builder_factories') {
              final val = entry.value;
              if (val is List) {
                for (final item in val) {
                  if (item != null) {
                    final str = item.toString().trim();
                    if (str.isNotEmpty) results.add(str);
                  }
                }
              } else if (val is String) {
                final str = val.trim();
                if (str.isNotEmpty) results.add(str);
              }
            } else {
              extractFromNode(entry.value);
            }
          }
        } else if (node is List) {
          for (final item in node) {
            extractFromNode(item);
          }
        }
      }

      extractFromNode(doc);
      return results;
    } catch (_) {
      return const {};
    }
  }
}
