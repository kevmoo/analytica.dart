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
        _collectPluginClasses(doc['flutter'], results);
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

    if (_hasFlutterMain(topology, packageDir)) {
      results.add('main');
    }

    return results;
  }

  static void _collectPluginClasses(Object? node, Set<String> results) {
    if (node is List) {
      for (final item in node) {
        _collectPluginClasses(item, results);
      }
      return;
    }
    if (node is! Map) return;
    for (final entry in node.entries) {
      final key = entry.key?.toString();
      if (key != 'pluginClass' && key != 'dartPluginClass') {
        _collectPluginClasses(entry.value, results);
        continue;
      }
      final val = entry.value?.toString().trim();
      if (val != null && val.isNotEmpty) {
        results.add(val);
      }
    }
  }

  static bool _hasFlutterMain(PackageTopology topology, Directory packageDir) {
    if (topology.publicLibFiles.any(PackageTopology.isFlutterEntrypoint)) {
      return true;
    }
    final libDir = Directory(p.join(packageDir.path, 'lib'));
    if (!libDir.existsSync()) return false;
    for (final entity in libDir.listSync(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final rel = p.relative(entity.path, from: packageDir.path);
      if (PackageTopology.isFlutterEntrypoint(rel)) return true;
    }
    return false;
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
