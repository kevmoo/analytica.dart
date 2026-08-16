import 'dart:io';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../root_harvester.dart';
import 'framework_adapter.dart';

/// Adapter for Flutter framework conventions, entrypoints, and test harnesses.
class FlutterAdapter extends BaseFrameworkAdapter {
  const FlutterAdapter();

  static const _flutterEntryPointPragmas = {
    'vm:entry-point',
    'vm:entrypoint',
    'flutter:entry-point',
    'flutter:entrypoint',
  };

  @override
  Set<String> harvestRoots({
    required PackageTopology topology,
    required Directory packageDir,
    required String pubspecContent,
  }) {
    final results = <String>{};

    // Extract plugin classes from pubspec.yaml
    try {
      final doc = loadYaml(pubspecContent);
      if (doc is Map) {
        void extractPluginClasses(dynamic node) {
          if (node is Map) {
            for (final entry in node.entries) {
              final key = entry.key?.toString();
              if (key == 'pluginClass' || key == 'dartPluginClass') {
                final val = entry.value?.toString().trim();
                if (val != null && val.isNotEmpty) {
                  results.add(val);
                }
              } else {
                extractPluginClasses(entry.value);
              }
            }
          } else if (node is List) {
            for (final item in node) {
              extractPluginClasses(item);
            }
          }
        }

        extractPluginClasses(doc['flutter']);
      }
    } catch (_) {
      final nonCommentLines = pubspecContent
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('#'))
          .join('\n');
      final matches = RegExp(
        r'(?:dartPluginClass|pluginClass):\s*["'
        "'"
        r']?([a-zA-Z0-9_]+)["'
        "'"
        r']?',
      ).allMatches(nonCommentLines);
      for (final match in matches) {
        final cls = match.group(1);
        if (cls != null && cls.isNotEmpty) {
          results.add(cls);
        }
      }
    }

    // Discover main() in lib/main.dart & lib/main_*.dart
    var hasFlutterMain = false;
    for (final file in topology.publicLibFiles) {
      if (PackageTopology.isFlutterEntrypoint(file)) {
        hasFlutterMain = true;
        break;
      }
    }
    if (!hasFlutterMain) {
      final libDir = Directory(p.join(packageDir.path, 'lib'));
      if (libDir.existsSync()) {
        for (final entity in libDir.listSync(followLinks: false)) {
          if (entity is File && entity.path.endsWith('.dart')) {
            final rel = p.relative(entity.path, from: packageDir.path);
            if (PackageTopology.isFlutterEntrypoint(rel)) {
              hasFlutterMain = true;
              break;
            }
          }
        }
      }
    }

    if (hasFlutterMain) {
      results.add('main');
    }

    return results;
  }

  @override
  bool isTestCallSite(MethodInvocation node) {
    return node.methodName.name == 'testWidgets';
  }

  @override
  bool isFrameworkEntryPoint(AnnotatedNode node, Element? element) {
    for (final meta in node.metadata) {
      final pragmaName = extractPragmaName(meta);
      if (pragmaName != null &&
          _flutterEntryPointPragmas.contains(pragmaName)) {
        return true;
      }
    }
    return false;
  }
}
