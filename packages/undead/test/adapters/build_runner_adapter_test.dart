import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:checks/checks.dart';
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;
import 'package:undead/undead.dart';

List<MethodInvocation> _extractInvocations(String source) {
  final result = parseString(content: source);
  final collector = _InvocationCollector();
  result.unit.accept(collector);
  return collector.invocations;
}

class _InvocationCollector extends RecursiveAstVisitor<void> {
  final List<MethodInvocation> invocations = [];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    invocations.add(node);
    super.visitMethodInvocation(node);
  }
}

void main() {
  group('BuildRunnerAdapter', () {
    const adapter = BuildRunnerAdapter();

    group('harvestRoots', () {
      test('extracts inline builder_factories from build.yaml', () async {
        await d.dir('inline_build_pkg', [
          d.file('pubspec.yaml', 'name: inline_build_pkg\n'),
          d.file('build.yaml', '''
targets:
  \$default:
    builders:
      inline_build_pkg|builder:
        builder_factories: ["sampleBuilderFactory", "secondaryFactory"]
'''),
        ]).create();

        const topology = PackageTopology(
          packagePath: '/dummy',
          packageName: 'inline_build_pkg',
          publicLibFiles: <String>[],
          internalSrcFiles: <String>[],
          executableFiles: <String>[],
          demonstrationFiles: <String>[],
          auxiliaryFiles: <String>[],
          testFiles: <String>[],
        );

        final roots = adapter.harvestRoots(
          topology: topology,
          packageDir: Directory(d.path('inline_build_pkg')),
          pubspecContent: 'name: inline_build_pkg\n',
        );

        check(roots).contains('sampleBuilderFactory');
        check(roots).contains('secondaryFactory');
      });

      test('extracts multi-line YAML list builder_factories', () async {
        await d.dir('multiline_build_pkg', [
          d.file('pubspec.yaml', 'name: multiline_build_pkg\n'),
          d.file('build.yaml', '''
targets:
  \$default:
    builders:
      multiline_build_pkg|builder:
        builder_factories:
          - customBuilderOne
          - 'customBuilderTwo'
'''),
        ]).create();

        const topology = PackageTopology(
          packagePath: '/dummy',
          packageName: 'multiline_build_pkg',
          publicLibFiles: <String>[],
          internalSrcFiles: <String>[],
          executableFiles: <String>[],
          demonstrationFiles: <String>[],
          auxiliaryFiles: <String>[],
          testFiles: <String>[],
        );

        final roots = adapter.harvestRoots(
          topology: topology,
          packageDir: Directory(d.path('multiline_build_pkg')),
          pubspecContent: 'name: multiline_build_pkg\n',
        );

        check(roots).contains('customBuilderOne');
        check(roots).contains('customBuilderTwo');
      });

      test('handles comments and blank lines in build.yaml', () async {
        await d.dir('commented_build_pkg', [
          d.file('pubspec.yaml', 'name: commented_build_pkg\n'),
          d.file('build.yaml', '''
targets:
  \$default:
    builders:
      commented_build_pkg|builder:
        # Builder factories configuration
        builder_factories:
          # Main factory
          - factoryWithComment

          # Quoted factory
          - "factoryQuoted"
          - 'factorySingleQuoted'
'''),
        ]).create();

        const topology = PackageTopology(
          packagePath: '/dummy',
          packageName: 'commented_build_pkg',
          publicLibFiles: <String>[],
          internalSrcFiles: <String>[],
          executableFiles: <String>[],
          demonstrationFiles: <String>[],
          auxiliaryFiles: <String>[],
          testFiles: <String>[],
        );

        final roots = adapter.harvestRoots(
          topology: topology,
          packageDir: Directory(d.path('commented_build_pkg')),
          pubspecContent: 'name: commented_build_pkg\n',
        );

        check(roots).contains('factoryWithComment');
        check(roots).contains('factoryQuoted');
        check(roots).contains('factorySingleQuoted');
      });

      test('returns empty set when build.yaml does not exist', () async {
        await d.dir('no_build_yaml_pkg', [
          d.file('pubspec.yaml', 'name: no_build_yaml_pkg\n'),
        ]).create();

        const topology = PackageTopology(
          packagePath: '/dummy',
          packageName: 'no_build_yaml_pkg',
          publicLibFiles: <String>[],
          internalSrcFiles: <String>[],
          executableFiles: <String>[],
          demonstrationFiles: <String>[],
          auxiliaryFiles: <String>[],
          testFiles: <String>[],
        );

        final roots = adapter.harvestRoots(
          topology: topology,
          packageDir: Directory(d.path('no_build_yaml_pkg')),
          pubspecContent: 'name: no_build_yaml_pkg\n',
        );

        check(roots).isEmpty();
      });

      test('returns empty set gracefully on malformed build.yaml', () async {
        await d.dir('malformed_build_pkg', [
          d.file('pubspec.yaml', 'name: malformed_build_pkg\n'),
          d.file('build.yaml', ': this is not valid yaml :::'),
        ]).create();

        const topology = PackageTopology(
          packagePath: '/dummy',
          packageName: 'malformed_build_pkg',
          publicLibFiles: <String>[],
          internalSrcFiles: <String>[],
          executableFiles: <String>[],
          demonstrationFiles: <String>[],
          auxiliaryFiles: <String>[],
          testFiles: <String>[],
        );

        final roots = adapter.harvestRoots(
          topology: topology,
          packageDir: Directory(d.path('malformed_build_pkg')),
          pubspecContent: 'name: malformed_build_pkg\n',
        );

        check(roots).isEmpty();
      });
    });

    group('default AST node classification', () {
      test('isTestCallSite and isTestHarnessSite return false', () {
        final invocations = _extractInvocations(
          'void main() { test("desc", () {}); setUp(() {}); }',
        );
        check(invocations).length.equals(2);
        for (final stmt in invocations) {
          check(adapter.isTestCallSite(stmt)).isFalse();
          check(adapter.isTestHarnessSite(stmt)).isFalse();
        }
      });

      test('isFrameworkEntryPoint returns false', () {
        final result = parseString(
          content: '@pragma("vm:entry-point") void foo() {}',
        );
        final decl = result.unit.declarations
            .whereType<FunctionDeclaration>()
            .first;
        check(adapter.isFrameworkEntryPoint(decl, null)).isFalse();
      });
    });
  });
}
