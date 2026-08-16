import 'dart:io';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';

import '../root_harvester.dart';

/// Interface for framework-specific root harvesting and AST node
/// classification.
abstract interface class FrameworkAdapter {
  /// Harvests entrypoint and root declaration names or identifiers for the
  /// framework.
  Set<String> harvestRoots({
    required PackageTopology topology,
    required Directory packageDir,
    required String pubspecContent,
  });

  /// Whether [node] is a leaf test invocation site (e.g. `test(...)`,
  /// `testWidgets(...)`).
  bool isTestCallSite(MethodInvocation node);

  /// Whether [node] is a test lifecycle harness/fixture site (e.g. `setUp(...)`,
  /// `tearDown(...)`).
  bool isTestHarnessSite(MethodInvocation node);

  /// Whether [node] or [element] is a framework-specific entrypoint
  /// (e.g. `@pragma('vm:entry-point')`).
  bool isFrameworkEntryPoint(AnnotatedNode node, Element? element);

  /// Whether [node] or [element] represents an external JavaScript or Wasm
  /// interop declaration (e.g. extension type with external members or `@JS`
  /// annotation).
  bool isExternalJsInterop(Declaration node, Element? element);
}

/// Base adapter providing default no-op / false implementations of
/// [FrameworkAdapter].
abstract class BaseFrameworkAdapter implements FrameworkAdapter {
  const BaseFrameworkAdapter();

  @override
  Set<String> harvestRoots({
    required PackageTopology topology,
    required Directory packageDir,
    required String pubspecContent,
  }) => const {};

  @override
  bool isTestCallSite(MethodInvocation node) => false;

  @override
  bool isTestHarnessSite(MethodInvocation node) => false;

  @override
  bool isFrameworkEntryPoint(AnnotatedNode node, Element? element) => false;

  @override
  bool isExternalJsInterop(Declaration node, Element? element) => false;
}
