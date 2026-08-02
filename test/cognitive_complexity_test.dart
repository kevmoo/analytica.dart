import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:checks/checks.dart';
import 'package:cognitive_complexity/cognitive_complexity.dart';
import 'package:test/scaffolding.dart';

int _getComplexity(String code) {
  var result = parseString(
    content: code,
    featureSet: FeatureSet.latestLanguageVersion(),
    throwIfDiagnostics: false,
  );
  var unit = result.unit;

  final hasFunction = unit.declarations.any(
    (d) => d is FunctionDeclaration && !d.name.type.isKeyword,
  );
  if (!hasFunction) {
    final fullCode = 'void test() {\n$code\n}';
    result = parseString(
      content: fullCode,
      featureSet: FeatureSet.latestLanguageVersion(),
    );
    unit = result.unit;
  }

  FunctionBody? body;
  for (final declaration in unit.declarations) {
    if (declaration is FunctionDeclaration) {
      body = declaration.functionExpression.body;
      break;
    }
  }

  if (body == null) {
    throw ArgumentError('No function found in code:\n$code');
  }

  final visitor = CognitiveComplexityVisitor();
  body.accept(visitor);
  return visitor.score;
}

void main() {
  group('Cognitive Complexity', () {
    test('Empty function', () {
      check(_getComplexity('')).equals(0);
    });

    test('Simple if', () {
      check(_getComplexity('if (a) { print(a); }')).equals(1);
    });

    test('If-else', () {
      check(
        _getComplexity('if (a) { print(a); } else { print(b); }'),
      ).equals(2);
    });

    test('Nested if', () {
      check(
        _getComplexity('''
        if (a) {
          if (b) {
            print(b);
          }
        }
      '''),
      ).equals(3);
    });

    test('Else-if chain', () {
      check(
        _getComplexity('''
        if (a) {
          print(a);
        } else if (b) {
          print(b);
        } else if (c) {
          print(c);
        } else {
          print(d);
        }
      '''),
      ).equals(4);
    });

    test('Nested else-if chain', () {
      check(
        _getComplexity('''
        if (a) {
          print(a);
        } else if (b) {
          if (c) {
            print(c);
          }
        }
      '''),
      ).equals(5);
    });

    test('Loops', () {
      check(
        _getComplexity('for (var i = 0; i < 10; i++) { print(i); }'),
      ).equals(1);
      check(_getComplexity('while (a) { print(a); }')).equals(1);
      check(_getComplexity('do { print(a); } while (a);')).equals(1);
    });

    test('Nested loops', () {
      check(
        _getComplexity('''
        for (var i = 0; i < 10; i++) {
          while (a) {
            print(i);
          }
        }
      '''),
      ).equals(3);
    });

    test('Switch statement', () {
      check(
        _getComplexity('''
        switch (x) {
          case 1: print(1); break;
          case 2: print(2); break;
          default: print(3);
        }
      '''),
      ).equals(1);
    });

    test('Nested if inside switch', () {
      check(
        _getComplexity('''
        switch (x) {
          case 1:
            if (a) {
              print(1);
            }
            break;
        }
      '''),
      ).equals(3);
    });

    test('Ternary operator', () {
      check(_getComplexity('var x = a ? b : c;')).equals(1);
    });

    test('Nested ternary', () {
      check(_getComplexity('var x = a ? (b ? c : d) : e;')).equals(3);
    });

    test('Catch clause', () {
      check(
        _getComplexity('''
        try {
          print(1);
        } catch (e) {
          print(e);
        }
      '''),
      ).equals(1);
    });

    test('Nested catch', () {
      check(
        _getComplexity('''
        try {
          try {
            print(1);
          } catch (e) {
            print(e);
          }
        } catch (e) {
          print(e);
        }
      '''),
      ).equals(2);
    });

    test('Nested catch inside catch', () {
      check(
        _getComplexity('''
        try {
          print(1);
        } catch (e) {
          try {
            print(2);
          } catch (inner) {
            print(inner);
          }
        }
      '''),
      ).equals(2);
    });

    test('If inside catch', () {
      check(
        _getComplexity('''
        try {
          print(1);
        } catch (e) {
          if (a) {
            print(e);
          }
        }
      '''),
      ).equals(3);
    });

    test('Logical operators (same type)', () {
      check(_getComplexity('if (a && b && c) { print(1); }')).equals(2);
    });

    test('Logical operators (mixed type)', () {
      check(_getComplexity('if (a && b || c) { print(1); }')).equals(3);
    });

    test('Logical operators (parenthesized same type)', () {
      check(_getComplexity('if ((a && b) && c) { print(1); }')).equals(2);
    });

    test('Unlabeled break and continue', () {
      check(
        _getComplexity('''
        while (a) {
          if (b) break;
          if (c) continue;
        }
      '''),
      ).equals(5);
    });

    test('Labeled break and continue', () {
      check(
        _getComplexity('''
        outer: while (a) {
          while (b) {
            if (c) break outer;
            if (d) continue outer;
          }
        }
      '''),
      ).equals(11);
    });

    test('Switch expression with nested ternary', () {
      check(
        _getComplexity('''
        var x = switch (y) {
          1 => a ? b : c,
          _ => 0,
        };
      '''),
      ).equals(3);
    });

    test('If with pattern and guard', () {
      check(
        _getComplexity('''
        dynamic x;
        if (x case String s when s.isNotEmpty) {
          print(s);
        }
      '''),
      ).equals(2);
    });

    test('Collection control flow elements (IfElement & ForElement)', () {
      check(
        _getComplexity('''
        final list = [
          if (a) 1,
          for (final item in items)
            if (item.isValid) item,
        ];
      '''),
      ).equals(4);
    });

    test('Nested function', () {
      check(
        _getComplexity('''
        void outer() {
          void inner() {
            if (a) {
              print(1);
            }
          }
        }
      '''),
      ).equals(3);
    });

    test('Lambda expression nesting', () {
      check(
        _getComplexity('''
        void foo() {
          var lambda = () {
            if (a) {
              print(1);
            }
          };
        }
      '''),
      ).equals(2);
    });

    test('Before Refactoring Sample', () {
      final code = '''
        int resolveTimeout(String protocol, bool isSecure, int retryCount) {
          if (protocol == 'http') {          // D=0 -> +1 (if)
            if (isSecure) {                  // D=1 -> +2 (if + depth 1)
              if (retryCount > 3) {          // D=2 -> +3 (if + depth 2)
                return 5000;
              } else {                       // D=2 -> +1 (else flat)
                return 3000;
              }
            } else {                         // D=1 -> +1 (else flat)
                return 1000;
              }
            } else if (protocol == 'ftp') {    // D=0 -> +1 (else if flat) +3 (nested...)
            return isSecure ? 10000 : 2000;
          }
          return 0;
        }
      ''';
      check(_getComplexity(code)).equals(12);
    });

    test('After Refactoring Sample 1', () {
      final code = '''
        int resolveTimeoutRefactored(String protocol, bool isSecure, int retryCount) {
          if (protocol == 'http') {
            return _resolveHttpTimeout(isSecure, retryCount);
          }
          if (protocol == 'ftp') {
            return isSecure ? 10000 : 2000;
          }
          return 0;
        }
      ''';
      check(_getComplexity(code)).equals(4);
    });

    test('After Refactoring Sample 2', () {
      final code = '''
        int _resolveHttpTimeout(bool isSecure, int retryCount) {
          if (!isSecure) return 1000;
          return retryCount > 3 ? 5000 : 3000;
        }
      ''';
      check(_getComplexity(code)).equals(2);
    });
  });
}
