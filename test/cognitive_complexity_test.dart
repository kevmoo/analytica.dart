import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:cognitive_complexity/cognitive_complexity.dart';
import 'package:test/test.dart';

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
      expect(_getComplexity(''), 0);
    });

    test('Simple if', () {
      expect(_getComplexity('if (a) { print(a); }'), 1);
    });

    test('If-else', () {
      expect(_getComplexity('if (a) { print(a); } else { print(b); }'), 2);
    });

    test('Nested if', () {
      expect(
        _getComplexity('''
        if (a) {
          if (b) {
            print(b);
          }
        }
      '''),
        3,
      );
    });

    test('Else-if chain', () {
      expect(
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
        4,
      );
    });

    test('Nested else-if chain', () {
      expect(
        _getComplexity('''
        if (a) {
          print(a);
        } else if (b) {
          if (c) {
            print(c);
          }
        }
      '''),
        5,
      );
    });

    test('Loops', () {
      expect(_getComplexity('for (var i = 0; i < 10; i++) { print(i); }'), 1);
      expect(_getComplexity('while (a) { print(a); }'), 1);
      expect(_getComplexity('do { print(a); } while (a);'), 1);
    });

    test('Nested loops', () {
      expect(
        _getComplexity('''
        for (var i = 0; i < 10; i++) {
          while (a) {
            print(i);
          }
        }
      '''),
        3,
      );
    });

    test('Switch statement', () {
      expect(
        _getComplexity('''
        switch (x) {
          case 1: print(1); break;
          case 2: print(2); break;
          default: print(3);
        }
      '''),
        1,
      );
    });

    test('Nested if inside switch', () {
      expect(
        _getComplexity('''
        switch (x) {
          case 1:
            if (a) {
              print(1);
            }
            break;
        }
      '''),
        3,
      );
    });

    test('Ternary operator', () {
      expect(_getComplexity('var x = a ? b : c;'), 1);
    });

    test('Nested ternary', () {
      expect(_getComplexity('var x = a ? (b ? c : d) : e;'), 3);
    });

    test('Catch clause', () {
      expect(
        _getComplexity('''
        try {
          print(1);
        } catch (e) {
          print(e);
        }
      '''),
        1,
      );
    });

    test('Nested catch', () {
      expect(
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
        2,
      );
    });

    test('Nested catch inside catch', () {
      expect(
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
        2,
      );
    });

    test('If inside catch', () {
      expect(
        _getComplexity('''
        try {
          print(1);
        } catch (e) {
          if (a) {
            print(e);
          }
        }
      '''),
        3,
      );
    });

    test('Logical operators (same type)', () {
      expect(_getComplexity('if (a && b && c) { print(1); }'), 2);
    });

    test('Logical operators (mixed type)', () {
      expect(_getComplexity('if (a && b || c) { print(1); }'), 3);
    });

    test('Logical operators (parenthesized same type)', () {
      expect(_getComplexity('if ((a && b) && c) { print(1); }'), 2);
    });

    test('Unlabeled break and continue', () {
      expect(
        _getComplexity('''
        while (a) {
          if (b) break;
          if (c) continue;
        }
      '''),
        5,
      );
    });

    test('Labeled break and continue', () {
      expect(
        _getComplexity('''
        outer: while (a) {
          while (b) {
            if (c) break outer;
            if (d) continue outer;
          }
        }
      '''),
        11,
      );
    });

    test('Switch expression with nested ternary', () {
      expect(
        _getComplexity('''
        var x = switch (y) {
          1 => a ? b : c,
          _ => 0,
        };
      '''),
        3,
      );
    });

    test('If with pattern and guard', () {
      expect(
        _getComplexity('''
        dynamic x;
        if (x case String s when s.isNotEmpty) {
          print(s);
        }
      '''),
        2,
      );
    });

    test('Collection control flow elements (IfElement & ForElement)', () {
      expect(
        _getComplexity('''
        final list = [
          if (a) 1,
          for (final item in items)
            if (item.isValid) item,
        ];
      '''),
        4,
      ); // if (a) -> 1, for -> 1, nested if -> 1 + 1 (depth) = 2. Total = 4.
    });

    test('Nested function', () {
      expect(
        _getComplexity('''
        void outer() {
          void inner() {
            if (a) {
              print(1);
            }
          }
        }
      '''),
        3,
      );
    });

    test('Lambda expression nesting', () {
      expect(
        _getComplexity('''
        void foo() {
          var lambda = () {
            if (a) {
              print(1);
            }
          };
        }
      '''),
        2,
      );
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
      expect(_getComplexity(code), 12);
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
      expect(_getComplexity(code), 4);
    });

    test('After Refactoring Sample 2', () {
      final code = '''
        int _resolveHttpTimeout(bool isSecure, int retryCount) {
          if (!isSecure) return 1000;
          return retryCount > 3 ? 5000 : 3000;
        }
      ''';
      expect(_getComplexity(code), 2);
    });
  });
}
