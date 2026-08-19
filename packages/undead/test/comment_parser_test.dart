import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:checks/checks.dart';
import 'package:test/test.dart';
import 'package:undead/src/comment_parser.dart';

void main() {
  group('CommentParser', () {
    test('detects // undead:ignore_for_file at top of file', () {
      const source = '''
// undead:ignore_for_file
class Foo {}
''';
      final result = parseString(
        content: source,
        featureSet: FeatureSet.latestLanguageVersion(),
      );

      check(CommentParser.hasIgnoreForFile(result.unit, source)).isTrue();
    });

    test('does NOT match standard analyzer ignore_for_file directives', () {
      const source = '''
// ignore_for_file: unused_element
class Foo {}
''';
      final result = parseString(
        content: source,
        featureSet: FeatureSet.latestLanguageVersion(),
      );

      check(CommentParser.hasIgnoreForFile(result.unit, source)).isFalse();
    });

    test('detects // undead:ignore immediately preceding declaration', () {
      const source = '''
// undead:ignore
class DynamicClass {}

class UnignoredClass {}
''';
      final result = parseString(
        content: source,
        featureSet: FeatureSet.latestLanguageVersion(),
      );

      final decl1 = result.unit.declarations[0];
      final decl2 = result.unit.declarations[1];

      check(CommentParser.isDeclarationIgnored(decl1)).isTrue();
      check(CommentParser.isDeclarationIgnored(decl2)).isFalse();
    });

    test('detects // undead:ignore before metadata annotations', () {
      const source = '''
// undead:ignore
@deprecated
class DynamicAnnotatedClass {}
''';
      final result = parseString(
        content: source,
        featureSet: FeatureSet.latestLanguageVersion(),
      );

      final decl = result.unit.declarations[0];
      check(CommentParser.isDeclarationIgnored(decl)).isTrue();
    });

    test('detects // undead:ignore between metadata and declaration token', () {
      const source = '''
@deprecated
// undead:ignore
class DynamicAnnotatedClass {}
''';
      final result = parseString(
        content: source,
        featureSet: FeatureSet.latestLanguageVersion(),
      );

      final decl = result.unit.declarations[0];
      check(CommentParser.isDeclarationIgnored(decl)).isTrue();
    });

    test('does NOT match standard // ignore: lint directives', () {
      const source = '''
// ignore: unused_element
class Foo {}
''';
      final result = parseString(
        content: source,
        featureSet: FeatureSet.latestLanguageVersion(),
      );

      final decl = result.unit.declarations[0];
      check(CommentParser.isDeclarationIgnored(decl)).isFalse();
    });

    test(
      'does NOT treat string literals containing // undead:ignore_for_file as suppression',
      () {
        const source = '''
const template = """
// undead:ignore_for_file
""";
class Foo {}
''';
        final result = parseString(
          content: source,
          featureSet: FeatureSet.latestLanguageVersion(),
        );

        check(CommentParser.hasIgnoreForFile(result.unit, source)).isFalse();
      },
    );
  });
}
