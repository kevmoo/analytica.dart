import 'package:analytica/analyzer.dart';
import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:checks/checks.dart';
import 'package:test/test.dart';

void main() {
  group('CommentDirectiveParser', () {
    final parser = CommentDirectiveParser('my_tool');

    test('detects file-level suppression directive', () {
      const source = '''
// my_tool:ignore_for_file
class Foo {}
''';
      final result = parseString(
        content: source,
        featureSet: FeatureSet.latestLanguageVersion(),
      );

      check(parser.hasIgnoreForFile(result.unit)).isTrue();
      check(
        CommentDirectiveParser.hasIgnoreForFileDirective(
          result.unit,
          toolName: 'my_tool',
        ),
      ).isTrue();
      check(
        CommentDirectiveParser.hasIgnoreForFileDirective(
          result.unit,
          toolName: 'other_tool',
        ),
      ).isFalse();
    });

    test(
      'does NOT match other tool directives or standard analyzer ignores',
      () {
        const source = '''
// ignore_for_file: unused_element
// other_tool:ignore_for_file
class Foo {}
''';
        final result = parseString(
          content: source,
          featureSet: FeatureSet.latestLanguageVersion(),
        );

        check(parser.hasIgnoreForFile(result.unit)).isFalse();
      },
    );

    test('detects declaration-level ignore comments', () {
      const source = '''
// my_tool:ignore
class IgnoredClass {}

class UnignoredClass {}

// my_tool:ignore
@deprecated
class IgnoredAnnotatedClass {}

@deprecated
// my_tool:ignore
class IgnoredAfterAnnotationClass {}
''';
      final parsed = parseString(
        content: source,
        featureSet: FeatureSet.latestLanguageVersion(),
      );

      final decls = parsed.unit.declarations;
      check(parser.isDeclarationIgnored(decls[0])).isTrue();
      check(parser.isDeclarationIgnored(decls[1])).isFalse();
      check(parser.isDeclarationIgnored(decls[2])).isTrue();
      check(parser.isDeclarationIgnored(decls[3])).isTrue();

      check(
        CommentDirectiveParser.isDeclarationIgnoredFor(
          decls[0],
          toolName: 'my_tool',
        ),
      ).isTrue();
      check(
        CommentDirectiveParser.isDeclarationIgnoredFor(
          decls[0],
          toolName: 'other_tool',
        ),
      ).isFalse();
    });

    test('detects ignore_for_file on a file containing ONLY comments', () {
      const source = '// my_tool:ignore_for_file\n';
      final parsed = parseString(
        content: source,
        featureSet: FeatureSet.latestLanguageVersion(),
      );

      check(parser.hasIgnoreForFile(parsed.unit)).isTrue();
    });

    test('detects ignore_for_file at trailing EOF position', () {
      const source = '''
class Foo {}
// my_tool:ignore_for_file
''';
      final parsed = parseString(
        content: source,
        featureSet: FeatureSet.latestLanguageVersion(),
      );

      check(parser.hasIgnoreForFile(parsed.unit)).isTrue();
    });

    test('detects ignore on TopLevelVariableDeclaration for inner '
        'VariableDeclaration node', () {
      const source = '''
// my_tool:ignore
int a = 1, b = 2;

int c = 3;
''';
      final parsed = parseString(
        content: source,
        featureSet: FeatureSet.latestLanguageVersion(),
      );

      final topVar1 =
          parsed.unit.declarations[0] as TopLevelVariableDeclaration;
      final topVar2 =
          parsed.unit.declarations[1] as TopLevelVariableDeclaration;

      // Outer declaration
      check(parser.isDeclarationIgnored(topVar1)).isTrue();
      check(parser.isDeclarationIgnored(topVar2)).isFalse();

      // Inner variable declarations
      check(
        parser.isDeclarationIgnored(topVar1.variables.variables[0]),
      ).isTrue();
      check(
        parser.isDeclarationIgnored(topVar1.variables.variables[1]),
      ).isTrue();
      check(
        parser.isDeclarationIgnored(topVar2.variables.variables[0]),
      ).isFalse();
    });

    test('is immune to string literals containing directives', () {
      const source = '''
const str = """
// my_tool:ignore_for_file
// my_tool:ignore
""";

class Foo {}
''';
      final parsed = parseString(
        content: source,
        featureSet: FeatureSet.latestLanguageVersion(),
      );

      check(parser.hasIgnoreForFile(parsed.unit)).isFalse();
      check(parser.isDeclarationIgnored(parsed.unit.declarations[0])).isFalse();
      check(parser.isDeclarationIgnored(parsed.unit.declarations[1])).isFalse();
    });

    test(
      'extracts optional suppression reason stripping leading separators',
      () {
        const source = '''
// my_tool:ignore
void bareIgnore() {}

// my_tool:ignore 2D matrix neighbor-scoring hot loop
void spaceReason() {}

// my_tool:ignore: state machine dispatch table
void colonReason() {}

// my_tool:ignore - performance critical parser
@pragma('vm:prefer-inline')
void dashReason() {}

@pragma('vm:prefer-inline')
// my_tool:ignore -- bit-manipulation kernel
void doubleDashAfterMeta() {}

void notIgnored() {}
''';
        final parsed = parseString(
          content: source,
          featureSet: FeatureSet.latestLanguageVersion(),
        );
        final decls = parsed.unit.declarations;

        check(parser.isDeclarationIgnored(decls[0])).isTrue();
        check(parser.declarationIgnoreReason(decls[0])).isNull();

        check(parser.isDeclarationIgnored(decls[1])).isTrue();
        check(
          parser.declarationIgnoreReason(decls[1]),
        ).equals('2D matrix neighbor-scoring hot loop');

        check(parser.isDeclarationIgnored(decls[2])).isTrue();
        check(
          parser.declarationIgnoreReason(decls[2]),
        ).equals('state machine dispatch table');

        check(parser.isDeclarationIgnored(decls[3])).isTrue();
        check(
          parser.declarationIgnoreReason(decls[3]),
        ).equals('performance critical parser');

        check(parser.isDeclarationIgnored(decls[4])).isTrue();
        check(
          CommentDirectiveParser.declarationIgnoreReasonFor(
            decls[4],
            toolName: 'my_tool',
          ),
        ).equals('bit-manipulation kernel');

        check(parser.isDeclarationIgnored(decls[5])).isFalse();
        check(parser.declarationIgnoreReason(decls[5])).isNull();
      },
    );
  });
}
