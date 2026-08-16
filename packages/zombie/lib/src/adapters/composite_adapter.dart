import 'dart:io';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';

import '../root_harvester.dart';
import 'build_runner_adapter.dart';
import 'flutter_adapter.dart';
import 'framework_adapter.dart';
import 'js_interop_adapter.dart';
import 'package_test_adapter.dart';

/// Composite adapter that aggregates multiple [FrameworkAdapter] instances.
class CompositeFrameworkAdapter implements FrameworkAdapter {
  final List<FrameworkAdapter> adapters;

  const CompositeFrameworkAdapter(this.adapters);

  /// Default composite adapter configuring [FlutterAdapter],
  /// [BuildRunnerAdapter], [PackageTestAdapter], and [JsInteropAdapter].
  const CompositeFrameworkAdapter.defaults()
    : adapters = const [
        FlutterAdapter(),
        BuildRunnerAdapter(),
        PackageTestAdapter(),
        JsInteropAdapter(),
      ];

  @override
  Set<String> harvestRoots({
    required PackageTopology topology,
    required Directory packageDir,
    required String pubspecContent,
  }) {
    final combined = <String>{};
    for (final adapter in adapters) {
      combined.addAll(
        adapter.harvestRoots(
          topology: topology,
          packageDir: packageDir,
          pubspecContent: pubspecContent,
        ),
      );
    }
    return combined;
  }

  @override
  bool isTestCallSite(MethodInvocation node) {
    for (final adapter in adapters) {
      if (adapter.isTestCallSite(node)) return true;
    }
    return false;
  }

  @override
  bool isTestHarnessSite(MethodInvocation node) {
    for (final adapter in adapters) {
      if (adapter.isTestHarnessSite(node)) return true;
    }
    return false;
  }

  @override
  bool isFrameworkEntryPoint(AnnotatedNode node, Element? element) {
    for (final adapter in adapters) {
      if (adapter.isFrameworkEntryPoint(node, element)) return true;
    }
    return false;
  }

  @override
  bool isExternalBinding(Declaration node, Element? element) {
    for (final adapter in adapters) {
      if (adapter.isExternalBinding(node, element)) return true;
    }
    return false;
  }
}
