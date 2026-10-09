import 'dart:io';

import 'package:checks/checks.dart';
import 'package:cognitive_complexity/cognitive_complexity.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Edge cases from the PR #186 review of `file_split` type-cluster naming,
/// sibling types, and inherited import cycles (#182).
void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('file_split_review_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  File writeFile(String relativePath, String contents) =>
      File(p.join(tempDir.path, relativePath))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(contents);

  String lines(String prefix, int count, {String suffix = ''}) =>
      List.generate(count, (i) => '  final $prefix$i = $i$suffix;').join('\n');

  Future<FileSplitReport> analyze(File file) => const FileSplitAnalyzer()
      .analyzeFile(file.path, targetLines: 60, minClusterLines: 20);

  for (final order in [
    ['hub_a.dart', 'hub_b.dart'],
    ['hub_b.dart', 'hub_a.dart'],
  ]) {
    test(
      'prefers a re-export hop over an import hop (${order.join(', ')})',
      () async {
        writeFile('gh_clean.dart', '''
${order.map((h) => "export '$h';").join('\n')}

class GhCleanOptions {
  final int limit;
  const GhCleanOptions(this.limit);
}
''');
        writeFile('hub_a.dart', '''
import 'gh/github_queries.dart';

void touch() => print(runQueries);
''');
        writeFile('hub_b.dart', "export 'gh/github_queries.dart';\n");
        final source = writeFile('gh/github_queries.dart', '''
import '../gh_clean.dart';

class LandedPr {
  final int number;
  LandedPr(this.number);
  void pad() {
${lines('l', 20)}
  }
}

Future<List<LandedPr>> fetchLandedPrs(GhCleanOptions options) async {
  final prs = <LandedPr>[];
  for (var i = 0; i < options.limit; i++) {
    prs.add(LandedPr(i));
  }
${lines('f', 25)}
  return prs;
}

Future<void> runQueries(GhCleanOptions options) async {
  final prs = await fetchLandedPrs(options);
  print(prs.length);
${lines('q', 40)}
}
''');

        final report = await analyze(source);
        final cut = report.clusters.singleWhere(
          (c) => c.declarations.any((d) => d.name == 'fetchLandedPrs'),
        );
        check(cut.warnings).deepEquals([
          "cut imports '../gh_clean.dart', which re-exports hub_b.dart, which "
              're-exports github_queries.dart; move the declarations this cut '
              'uses out of the barrel to break the cycle',
        ]);
        check(cut.inheritedCycles).isEmpty();
      },
    );
  }

  group('sibling types left behind', () {
    String siblingsFixture({String cBody = ''}) =>
        '''
enum A { a0, a1, a2 }

int fa(A v) {
${lines('x', 45, suffix: ' + v.index')}
  return 0;
}

enum B { b0, b1, b2 }

int fb(B v) {
${lines('y', 20, suffix: ' + v.index')}
  return 0;
}

enum C {
${List.generate(12, (i) => '  c$i,').join('\n')}
$cBody}

void run() {
  fa(A.a0);
  fb(B.b0);
${lines('r', 70)}
}
''';

    Iterable<String> leftInNotes(FileSplitReport report) => [
      for (final c in report.clusters)
        for (final n in c.notes)
          if (n.contains(' left in ')) n,
    ];

    test('are not noted when a later cut pulls them', () async {
      final report = await analyze(writeFile('sib.dart', siblingsFixture()));
      final fb = report.clusters.singleWhere(
        (c) => c.declarations.any((d) => d.name == 'fb'),
      );
      check(fb.declarations.map((d) => d.name)).contains('C');
      check(leftInNotes(report)).isEmpty();
    });

    test('are noted once when no cut can take them', () async {
      final report = await analyze(
        writeFile(
          'sib.dart',
          siblingsFixture(cBody: '  ;\n  int get v => _k;\n').replaceFirst(
            'void run() {',
            'const _k = 1;\n\nvoid run() {\n  print(_k);',
          ),
        ),
      );
      check(
        report.clusters.expand((c) => c.declarations).map((d) => d.name),
      ).not((it) => it.contains('C'));
      check(leftInNotes(report)).length.equals(1);
      check(leftInNotes(report).single).contains('sibling type(s) C left in');
    });
  });

  test('names two equally sized types a type cluster', () async {
    String cls(String name, String peer) =>
        'class $name {\n  $peer? peer;\n'
        '${List.generate(19, (i) => '  int m$i() => $i;').join('\n')}\n}\n';
    final report = await analyze(
      writeFile('eq.dart', '''
${cls('Alpha', 'Beta')}
${cls('Beta', 'Alpha')}
void run() {
${lines('r', 60)}
}
'''),
    );
    final cut = report.clusters.single;
    check(cut.declarations.map((d) => d.lineCount)).deepEquals([22, 22]);
    check(cut.suggestedFileName).equals('eq_models.dart');
  });
}
