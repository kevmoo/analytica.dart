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
  group('CompositeFrameworkAdapter', () {
    test('defaults() constructor includes default standard adapters', () {
      const composite = CompositeFrameworkAdapter.defaults();
      check(composite.adapters.length).equals(4);
      check(composite.adapters.whereType<FlutterAdapter>().length).equals(1);
      check(
        composite.adapters.whereType<BuildRunnerAdapter>().length,
      ).equals(1);
      check(
        composite.adapters.whereType<PackageTestAdapter>().length,
      ).equals(1);
      check(composite.adapters.whereType<JsInteropAdapter>().length).equals(1);
    });

    group('harvestRoots', () {
      test('aggregates roots from all constituent adapters', () async {
        await d.dir('composite_pkg', [
          d.file('pubspec.yaml', '''
name: composite_pkg
flutter:
  plugin:
    platforms:
      android:
        pluginClass: CompositeAndroidPlugin
'''),
          d.file('build.yaml', '''
targets:
  \$default:
    builders:
      composite_pkg|builder:
        builder_factories: ["compositeFactoryOne", "compositeFactoryTwo"]
'''),
          d.dir('lib', [
            d.file('main.dart', 'void main() {}'),
            d.file('composite_pkg.dart', 'void exported() {}'),
          ]),
        ]).create();

        final topology = PackageTopology(
          packagePath: d.path('composite_pkg'),
          packageName: 'composite_pkg',
          publicLibFiles: ['lib/main.dart', 'lib/composite_pkg.dart'],
          internalSrcFiles: <String>[],
          executableFiles: <String>[],
          demonstrationFiles: <String>[],
          auxiliaryFiles: <String>[],
          testFiles: <String>[],
        );

        const composite = CompositeFrameworkAdapter.defaults();
        final roots = composite.harvestRoots(
          topology: topology,
          packageDir: Directory(d.path('composite_pkg')),
          pubspecContent: File(
            d.path('composite_pkg/pubspec.yaml'),
          ).readAsStringSync(),
        );

        // Discovered by FlutterAdapter:
        check(roots).contains('main');
        check(roots).contains('CompositeAndroidPlugin');

        // Discovered by BuildRunnerAdapter:
        check(roots).contains('compositeFactoryOne');
        check(roots).contains('compositeFactoryTwo');
      });
    });

    group('isTestCallSite', () {
      const composite = CompositeFrameworkAdapter.defaults();

      test('delegates to constituent adapters', () {
        final invocations = _extractInvocations('''
void main() {
  test("unit test", () {});
  testWidgets("widget test", (tester) {});
  solo_test("solo test", () {});
  group("group test", () {});
  otherMethod();
}
''');

        // test, testWidgets, solo_test
        check(composite.isTestCallSite(invocations[0])).isTrue();
        check(composite.isTestCallSite(invocations[1])).isTrue();
        check(composite.isTestCallSite(invocations[2])).isTrue();

        // group, otherMethod
        check(composite.isTestCallSite(invocations[3])).isFalse();
        check(composite.isTestCallSite(invocations[4])).isFalse();
      });
    });

    group('isTestHarnessSite', () {
      const composite = CompositeFrameworkAdapter.defaults();

      test('delegates to constituent adapters', () {
        final invocations = _extractInvocations('''
void main() {
  setUp(() {});
  tearDownAll(() {});
  test("unit test", () {});
}
''');

        check(composite.isTestHarnessSite(invocations[0])).isTrue();
        check(composite.isTestHarnessSite(invocations[1])).isTrue();
        check(composite.isTestHarnessSite(invocations[2])).isFalse();
      });
    });

    group('isFrameworkEntryPoint', () {
      const composite = CompositeFrameworkAdapter.defaults();

      test('delegates to constituent adapters', () {
        final result = parseString(
          content: '''
@pragma('vm:entry-point')
void vmEntryPoint() {}

@pragma('flutter:entry-point')
void flutterEntryPoint() {}

@pragma('vm:prefer-inline')
void inlineFunc() {}
''',
        );

        final decls = result.unit.declarations
            .whereType<FunctionDeclaration>()
            .toList();

        check(composite.isFrameworkEntryPoint(decls[0], null)).isTrue();
        check(composite.isFrameworkEntryPoint(decls[1], null)).isTrue();
        check(composite.isFrameworkEntryPoint(decls[2], null)).isFalse();
      });
    });
  });
}
