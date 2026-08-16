import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:checks/checks.dart';
import 'package:test/test.dart';
import 'package:zombie/zombie.dart';

void main() {
  group('JsInteropAdapter', () {
    const adapter = JsInteropAdapter();

    group('isFrameworkEntryPoint', () {
      test('matches Wasm export/entrypoint pragmas', () {
        final result = parseString(
          content: '''
@pragma('wasm:export')
void wasmExported() {}

@pragma('wasm:export', 'my_func')
void wasmNamedExported() {}

@pragma('wasm:entry-point')
void wasmEntryPoint() {}

@pragma('dart2js:tryInline')
void inlineFunc() {}

void normalFunc() {}
''',
        );

        final declarations = result.unit.declarations;

        // wasm:export
        check(adapter.isFrameworkEntryPoint(declarations[0], null)).isTrue();
        // wasm:export named
        check(adapter.isFrameworkEntryPoint(declarations[1], null)).isTrue();
        // wasm:entry-point
        check(adapter.isFrameworkEntryPoint(declarations[2], null)).isTrue();
        // dart2js:tryInline
        check(adapter.isFrameworkEntryPoint(declarations[3], null)).isFalse();
        // normal
        check(adapter.isFrameworkEntryPoint(declarations[4], null)).isFalse();
      });
    });

    group('isExternalJsInterop', () {
      test('matches external functions and top-level variables', () {
        final result = parseString(
          content: '''
external void externalTopLevel();

external int externalVar;

void regularFunc() {}

int regularVar = 10;
''',
        );

        final declarations = result.unit.declarations;

        check(adapter.isExternalJsInterop(declarations[0], null)).isTrue();
        check(adapter.isExternalJsInterop(declarations[1], null)).isTrue();
        check(adapter.isExternalJsInterop(declarations[2], null)).isFalse();
        check(adapter.isExternalJsInterop(declarations[3], null)).isFalse();
      });

      test('matches JS extension types and classes with external members', () {
        final result = parseString(
          content: '''
@JS('HTMLCanvasElement')
extension type DomHTMLCanvasElement(JSObject _) {
  external int get width;
  external set width(int value);
}

extension type JSAnyExtension(JSAny _) {}

extension type StandardStringExtension(String value) {
  int get len => value.length;
}

class NormalClass {
  void doSomething() {}
}

class ClassWithExternalMember {
  external void callJs();
}
''',
        );

        final declarations = result.unit.declarations;

        // DomHTMLCanvasElement
        check(adapter.isExternalJsInterop(declarations[0], null)).isTrue();
        // JSAnyExtension
        check(adapter.isExternalJsInterop(declarations[1], null)).isTrue();
        // StandardStringExtension (non-JS)
        check(adapter.isExternalJsInterop(declarations[2], null)).isFalse();
        // NormalClass
        check(adapter.isExternalJsInterop(declarations[3], null)).isFalse();
        // ClassWithExternalMember
        check(adapter.isExternalJsInterop(declarations[4], null)).isTrue();
      });
    });
  });

  group('CompositeFrameworkAdapter with JsInteropAdapter', () {
    test('defaults() delegates isExternalJsInterop', () {
      const composite = CompositeFrameworkAdapter.defaults();
      final result = parseString(
        content: '''
external void myExternalFunction();
void myDartFunction() {}
''',
      );

      final decls = result.unit.declarations;
      check(composite.isExternalJsInterop(decls[0], null)).isTrue();
      check(composite.isExternalJsInterop(decls[1], null)).isFalse();
    });
  });
}
