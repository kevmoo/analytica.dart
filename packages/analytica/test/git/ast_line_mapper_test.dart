import 'package:analytica/git.dart';
import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:checks/checks.dart';
import 'package:test/test.dart';

void main() {
  group('AstLineMapper', () {
    const source = '''
// Line 1
void topLevelFunc() {
  print('hello');
}

class MyService {
  final int field;

  MyService(this.field);

  void doWork() {
    print(field);
  }
}

enum Status {
  active,
  inactive,
}
''';

    final parsed = parseString(
      content: source,
      featureSet: FeatureSet.latestLanguageVersion(),
    );

    test('maps line range to top-level function', () {
      // lines 2-4 is topLevelFunc
      final mapped = AstLineMapper.mapDeclarations(
        parsed.unit,
        parsed.lineInfo,
        [const LineRange(3, 3)],
      );

      check(mapped.length).equals(1);
      check(mapped.first.name).equals('topLevelFunc');
      check(mapped.first.node).isA<FunctionDeclaration>();
      check(mapped.first.startLine).equals(2);
      check(mapped.first.endLine).equals(4);
    });

    test('maps line range to class and its method', () {
      // lines 11-13 is doWork method inside MyService (lines 6-15)
      final mapped = AstLineMapper.mapDeclarations(
        parsed.unit,
        parsed.lineInfo,
        [const LineRange(12, 12)],
      );

      // Should map both MyService (class) and MyService.doWork (method)
      final names = mapped.map((m) => m.name).toList();
      check(names).contains('MyService');
      check(names).contains('MyService.doWork');
    });

    test('maps line range to constructor', () {
      // line 9 is MyService constructor
      final mapped = AstLineMapper.findFunctionsAndMethods(
        parsed.unit,
        parsed.lineInfo,
        [const LineRange(9, 9)],
      );

      check(mapped.length).equals(1);
      check(mapped.first.name).equals('MyService');
      check(mapped.first.node).isA<ConstructorDeclaration>();
    });

    test('findFunctionsAndMethods only returns executable subroutines', () {
      final mapped = AstLineMapper.findFunctionsAndMethods(
        parsed.unit,
        parsed.lineInfo,
        [
          const LineRange(2, 3), // topLevelFunc
          const LineRange(12, 12), // doWork
          const LineRange(17, 19), // Status enum
        ],
      );

      final names = mapped.map((m) => m.name).toList();
      check(names).contains('topLevelFunc');
      check(names).contains('MyService.doWork');
      check(names).not(.it()..contains('MyService'));
      check(names).not(.it()..contains('Status'));
    });

    test('findTypes only returns type declarations', () {
      final mapped = AstLineMapper.findTypes(parsed.unit, parsed.lineInfo, [
        const LineRange(2, 3), // topLevelFunc
        const LineRange(12, 12), // doWork inside MyService
        const LineRange(18, 18), // Status enum
      ]);

      final names = mapped.map((m) => m.name).toList();
      check(names).contains('MyService');
      check(names).contains('Status');
      check(names).not(.it()..contains('topLevelFunc'));
      check(names).not(.it()..contains('MyService.doWork'));
    });

    test('mapDiffToDeclarations maps using GitFileDiff', () {
      const fileDiff = GitFileDiff(
        newPath: 'lib/service.dart',
        hunks: [
          DiffHunk(
            oldStart: 2,
            oldCount: 1,
            newStart: 2,
            newCount: 2,
            lines: ['+  print("changed");'],
            addedOrModifiedRanges: [LineRange(3, 3)],
          ),
        ],
      );

      final mapped = AstLineMapper.mapDiffToDeclarations(
        parsed.unit,
        parsed.lineInfo,
        fileDiff,
      );

      check(mapped.length).equals(1);
      check(mapped.first.name).equals('topLevelFunc');
    });

    test('returns empty when ranges do not intersect any declaration', () {
      final mapped = AstLineMapper.mapDeclarations(
        parsed.unit,
        parsed.lineInfo,
        [const LineRange(1, 1)], // Comment line
      );

      check(mapped).isEmpty;
    });

    test('returns empty when range list is empty', () {
      check(
        AstLineMapper.mapDeclarations(parsed.unit, parsed.lineInfo, const []),
      ).isEmpty;
    });
  });
}
