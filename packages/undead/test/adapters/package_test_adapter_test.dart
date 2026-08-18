import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:checks/checks.dart';
import 'package:test/test.dart';
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
  group('PackageTestAdapter', () {
    const adapter = PackageTestAdapter();

    group('isTestCallSite', () {
      test('matches leaf test functions (test, testWidgets, solo_test)', () {
        final invocations = _extractInvocations('''
void main() {
  test("unit test", () {});
  testWidgets("widget test", (tester) {});
  solo_test("solo test", () {});
}
''');

        check(invocations).length.equals(3);
        for (final stmt in invocations) {
          check(adapter.isTestCallSite(stmt)).isTrue();
        }
      });

      test('excludes group and general functions (leaf-only invariant)', () {
        final invocations = _extractInvocations('''
void main() {
  group("group block", () {});
  expect(1, equals(1));
  customFunction();
  setUp(() {});
}
''');

        check(invocations).length.equals(5);
        for (final stmt in invocations) {
          check(adapter.isTestCallSite(stmt)).isFalse();
        }
      });
    });

    group('isTestHarnessSite', () {
      test('matches fixture lifecycle methods '
          '(setUp, setUpAll, tearDown, tearDownAll)', () {
        final invocations = _extractInvocations('''
void main() {
  setUp(() {});
  setUpAll(() {});
  tearDown(() {});
  tearDownAll(() {});
}
''');

        check(invocations).length.equals(4);
        for (final stmt in invocations) {
          check(adapter.isTestHarnessSite(stmt)).isTrue();
        }
      });

      test('returns false for test, group, and other methods', () {
        final invocations = _extractInvocations('''
void main() {
  test("unit test", () {});
  group("group block", () {});
  otherMethod();
}
''');

        check(invocations).length.equals(3);
        for (final stmt in invocations) {
          check(adapter.isTestHarnessSite(stmt)).isFalse();
        }
      });
    });

    group('harvestRoots and isFrameworkEntryPoint', () {
      test('harvestRoots returns empty set', () {
        const topology = PackageTopology(
          packagePath: '/sample',
          packageName: 'sample',
          publicLibFiles: <String>[],
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
        check(roots).isEmpty();
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
