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
  group('FlutterAdapter', () {
    const adapter = FlutterAdapter();

    group('harvestRoots', () {
      test('discovers main() when lib/main.dart exists in topology', () {
        const topology = PackageTopology(
          packagePath: '/sample',
          packageName: 'sample',
          publicLibFiles: ['lib/main.dart', 'lib/sample.dart'],
          internalSrcFiles: <String>[],
          executableFiles: <String>[],
          demonstrationFiles: <String>[],
          auxiliaryFiles: <String>[],
          testFiles: <String>[],
        );

        final roots = adapter.harvestRoots(
          topology: topology,
          packageDir: Directory('/sample'),
          pubspecContent: 'name: sample\n',
        );

        check(roots).contains('main');
      });

      test('discovers main() when lib/main_dev.dart exists in topology', () {
        const topology = PackageTopology(
          packagePath: '/sample',
          packageName: 'sample',
          publicLibFiles: ['lib/main_dev.dart'],
          internalSrcFiles: <String>[],
          executableFiles: <String>[],
          demonstrationFiles: <String>[],
          auxiliaryFiles: <String>[],
          testFiles: <String>[],
        );

        final roots = adapter.harvestRoots(
          topology: topology,
          packageDir: Directory('/sample'),
          pubspecContent: 'name: sample\n',
        );

        check(roots).contains('main');
      });

      test(
        'discovers main() by checking filesystem if lib/main.dart exists',
        () async {
          await d.dir('flutter_pkg', [
            d.file('pubspec.yaml', 'name: flutter_pkg\n'),
            d.dir('lib', [d.file('main.dart', 'void main() {}')]),
          ]).create();

          final topology = PackageTopology(
            packagePath: d.path('flutter_pkg'),
            packageName: 'flutter_pkg',
            publicLibFiles: <String>[],
            internalSrcFiles: <String>[],
            executableFiles: <String>[],
            demonstrationFiles: <String>[],
            auxiliaryFiles: <String>[],
            testFiles: <String>[],
          );

          final roots = adapter.harvestRoots(
            topology: topology,
            packageDir: Directory(d.path('flutter_pkg')),
            pubspecContent: 'name: flutter_pkg\n',
          );

          check(roots).contains('main');
        },
      );

      test('extracts pluginClass and dartPluginClass from pubspec.yaml', () {
        const topology = PackageTopology(
          packagePath: '/sample',
          packageName: 'sample',
          publicLibFiles: ['lib/sample.dart'],
          internalSrcFiles: <String>[],
          executableFiles: <String>[],
          demonstrationFiles: <String>[],
          auxiliaryFiles: <String>[],
          testFiles: <String>[],
        );

        const pubspec = '''
name: sample
flutter:
  plugin:
    platforms:
      android:
        package: com.example
        pluginClass: SampleAndroidPlugin
      ios:
        pluginClass: "SampleIosPlugin"
      windows:
        dartPluginClass: 'SampleWindowsPlugin'
''';

        final roots = adapter.harvestRoots(
          topology: topology,
          packageDir: Directory('/sample'),
          pubspecContent: pubspec,
        );

        check(roots).contains('SampleAndroidPlugin');
        check(roots).contains('SampleIosPlugin');
        check(roots).contains('SampleWindowsPlugin');
        check(roots).not((it) => it.contains('main'));
      });

      test('ignores commented-out pluginClass in pubspec.yaml', () {
        const topology = PackageTopology(
          packagePath: '/sample',
          packageName: 'sample',
          publicLibFiles: ['lib/sample.dart'],
          internalSrcFiles: <String>[],
          executableFiles: <String>[],
          demonstrationFiles: <String>[],
          auxiliaryFiles: <String>[],
          testFiles: <String>[],
        );

        const pubspec = '''
name: sample
flutter:
  plugin:
    platforms:
      android:
        package: com.example
        # pluginClass: CommentedAndroidPlugin
        pluginClass: RealAndroidPlugin
''';

        final roots = adapter.harvestRoots(
          topology: topology,
          packageDir: Directory('/sample'),
          pubspecContent: pubspec,
        );

        check(roots).contains('RealAndroidPlugin');
        check(roots).not((it) => it.contains('CommentedAndroidPlugin'));
      });

      test(
        'returns empty set when no Flutter entrypoints or plugins exist',
        () {
          const topology = PackageTopology(
            packagePath: '/sample',
            packageName: 'sample',
            publicLibFiles: ['lib/other.dart', 'lib/sample.dart'],
            internalSrcFiles: ['lib/src/main.dart'],
            executableFiles: ['bin/main.dart'],
            demonstrationFiles: <String>[],
            auxiliaryFiles: <String>[],
            testFiles: <String>[],
          );

          final roots = adapter.harvestRoots(
            topology: topology,
            packageDir: Directory('/sample'),
            pubspecContent: 'name: sample\nversion: 1.0.0\n',
          );

          check(roots).isEmpty();
        },
      );
    });

    group('isTestCallSite', () {
      test('returns true for testWidgets', () {
        final invocations = _extractInvocations(
          'void main() { testWidgets("renders widget", (tester) {}); }',
        );
        check(invocations).length.equals(1);
        check(adapter.isTestCallSite(invocations.first)).isTrue();
      });

      test('returns false for test, group, and other methods', () {
        final invocations = _extractInvocations('''
void main() {
  test("unit test", () {});
  group("group test", () {});
  customHelper();
}
''');
        check(invocations).length.equals(3);
        for (final invocation in invocations) {
          check(adapter.isTestCallSite(invocation)).isFalse();
        }
      });
    });

    group('isTestHarnessSite', () {
      test('returns false for all invocations', () {
        final invocations = _extractInvocations(
          'void main() { setUp(() {}); tearDown(() {}); }',
        );
        check(invocations).length.equals(2);
        for (final invocation in invocations) {
          check(adapter.isTestHarnessSite(invocation)).isFalse();
        }
      });
    });

    group('isFrameworkEntryPoint', () {
      test('matches Flutter and VM entrypoint pragmas', () {
        final result = parseString(
          content: '''
@pragma('vm:entry-point')
void vmEntryPoint() {}

@pragma('vm:entrypoint')
void vmAltEntryPoint() {}

@pragma('flutter:entry-point')
void flutterEntryPoint() {}

@pragma('flutter:entrypoint')
void flutterAltEntryPoint() {}

@pragma('vm:prefer-inline')
void inlineFunc() {}

@pragma('dart2js:noInline')
void noInlineFunc() {}

void unannotatedFunc() {}
''',
        );

        final declarations = result.unit.declarations
            .whereType<FunctionDeclaration>()
            .toList();

        // Entrypoints
        check(adapter.isFrameworkEntryPoint(declarations[0], null)).isTrue();
        check(adapter.isFrameworkEntryPoint(declarations[1], null)).isTrue();
        check(adapter.isFrameworkEntryPoint(declarations[2], null)).isTrue();
        check(adapter.isFrameworkEntryPoint(declarations[3], null)).isTrue();

        // Non-entrypoints (optimization pragmas and unannotated)
        check(adapter.isFrameworkEntryPoint(declarations[4], null)).isFalse();
        check(adapter.isFrameworkEntryPoint(declarations[5], null)).isFalse();
        check(adapter.isFrameworkEntryPoint(declarations[6], null)).isFalse();
      });
    });
  });
}
