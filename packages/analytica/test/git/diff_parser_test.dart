import 'package:analytica/git.dart';
import 'package:checks/checks.dart';
import 'package:test/test.dart';

void main() {
  group('LineRange', () {
    test('computes lineCount, contains, and intersections', () {
      const range = LineRange(10, 20);

      check(range.lineCount).equals(11);
      check(range.contains(10)).isTrue();
      check(range.contains(15)).isTrue();
      check(range.contains(20)).isTrue();
      check(range.contains(9)).isFalse();
      check(range.contains(21)).isFalse();

      check(range.intersects(5, 9)).isFalse();
      check(range.intersects(5, 10)).isTrue();
      check(range.intersects(15, 25)).isTrue();
      check(range.intersects(20, 25)).isTrue();
      check(range.intersects(21, 30)).isFalse();

      check(range.intersectsRange(const LineRange(1, 10))).isTrue();
      check(range.intersectsRange(const LineRange(20, 30))).isTrue();
      check(range.intersectsRange(const LineRange(21, 30))).isFalse();

      check(range.toString()).equals('L10-L20');
      check(range.toJson()).deepEquals({'start_line': 10, 'end_line': 20});
    });

    test('implements Comparable and value equality', () {
      const r1 = LineRange(5, 10);
      const r2 = LineRange(5, 10);
      const r3 = LineRange(12, 15);

      check(r1 == r2).isTrue();
      check(r1.hashCode).equals(r2.hashCode);
      check(r1 == r3).isFalse();

      final list = [r3, r1]..sort();
      check(list).deepEquals([r1, r3]);

      final fromJson = LineRange.fromJson(r1.toJson());
      check(fromJson).equals(r1);
    });
  });

  group('GitDiffParser', () {
    test('parses standard modified files with multiple hunks', () {
      const diff = '''
diff --git a/lib/example.dart b/lib/example.dart
index 1234567..89abcdef 100644
--- a/lib/example.dart
+++ b/lib/example.dart
@@ -10,5 +10,6 @@ void hello() {
  line1
+ lineNew1
+ lineNew2
  line2
  line3
@@ -30,3 +31,4 @@ void goodbye() {
  line4
+ lineNew3
  line5
''';

      final result = GitDiffParser.parse(diff);
      check(result.length).equals(1);

      final file = result.first;
      check(file.path).equals('lib/example.dart');
      check(file.isNew).isFalse();
      check(file.isDeleted).isFalse();
      check(file.hunks.length).equals(2);

      final hunk1 = file.hunks[0];
      check(hunk1.oldStart).equals(10);
      check(hunk1.oldCount).equals(5);
      check(hunk1.newStart).equals(10);
      check(hunk1.newCount).equals(6);
      check(hunk1.sectionHeading).equals('void hello() {');
      check(hunk1.addedOrModifiedRanges).deepEquals([const LineRange(11, 12)]);

      final hunk2 = file.hunks[1];
      check(hunk2.oldStart).equals(30);
      check(hunk2.newStart).equals(31);
      check(hunk2.addedOrModifiedRanges).deepEquals([const LineRange(32, 32)]);

      check(
        file.addedOrModifiedLineRanges,
      ).deepEquals([const LineRange(11, 12), const LineRange(32, 32)]);
    });

    test(
      'parses diff with tab-separated timestamps in headers (diff -u format)',
      () {
        const diff = '''
--- a/lib/example.dart\t2026-08-14 09:00:00.000000000 +0000
+++ b/lib/example.dart\t2026-08-14 09:05:00.000000000 +0000
@@ -1,2 +1,3 @@
 line1
+lineAdded
 line2
''';

        final result = GitDiffParser.parse(diff);
        check(result.length).equals(1);
        check(result.first.path).equals('lib/example.dart');
        check(
          result.first.addedOrModifiedLineRanges,
        ).deepEquals([const LineRange(2, 2)]);
      },
    );

    test('parses quoted file paths with spaces', () {
      const diff = '''
diff --git "a/lib/path with spaces.dart" "b/lib/path with spaces.dart"
--- "a/lib/path with spaces.dart"
+++ "b/lib/path with spaces.dart"
@@ -1,2 +1,3 @@
 line1
+lineAdded
 line2
''';

      final result = GitDiffParser.parse(diff);
      check(result.length).equals(1);
      check(result.first.path).equals('lib/path with spaces.dart');
      check(
        result.first.addedOrModifiedLineRanges,
      ).deepEquals([const LineRange(2, 2)]);
    });

    test(
      'tolerates hunks with blank lines where leading space was stripped',
      () {
        const diff = '''
diff --git a/lib/example.dart b/lib/example.dart
--- a/lib/example.dart
+++ b/lib/example.dart
@@ -1,4 +1,5 @@
 void func() {

+  print('new');
 }
''';

        final result = GitDiffParser.parse(diff);
        check(result.length).equals(1);
        check(
          result.first.addedOrModifiedLineRanges,
        ).deepEquals([const LineRange(3, 3)]);
      },
    );

    test('parses newly added files', () {
      const diff = '''
diff --git a/lib/new_file.dart b/lib/new_file.dart
new file mode 100644
index 0000000..1234567
--- /dev/null
+++ b/lib/new_file.dart
@@ -0,0 +1,3 @@
+void foo() {
+  print('hello');
+}
''';

      final result = GitDiffParser.parse(diff);
      check(result.length).equals(1);

      final file = result.first;
      check(file.path).equals('lib/new_file.dart');
      check(file.isNew).isTrue();
      check(file.isDeleted).isFalse();
      check(file.addedOrModifiedLineRanges).deepEquals([const LineRange(1, 3)]);
    });

    test('parses deleted files', () {
      const diff = '''
diff --git a/lib/old_file.dart b/lib/old_file.dart
deleted file mode 100644
index 1234567..0000000
--- a/lib/old_file.dart
+++ /dev/null
@@ -1,3 +0,0 @@
-void foo() {
-  print('bye');
-}
''';

      final result = GitDiffParser.parse(diff);
      check(result.length).equals(1);

      final file = result.first;
      check(file.path).equals('lib/old_file.dart');
      check(file.isDeleted).isTrue();
      check(file.isNew).isFalse();
      check(file.addedOrModifiedLineRanges).isEmpty();
    });

    test('parses multiple files in unified diff output', () {
      const diff = '''
diff --git a/lib/a.dart b/lib/a.dart
--- a/lib/a.dart
+++ b/lib/a.dart
@@ -1,2 +1,3 @@
 line1
+addedA
 line2
diff --git a/lib/b.dart b/lib/b.dart
--- a/lib/b.dart
+++ b/lib/b.dart
@@ -5,2 +5,3 @@
 line5
+addedB
 line6
''';

      final result = GitDiffParser.parse(diff);
      check(result.length).equals(2);
      check(result[0].path).equals('lib/a.dart');
      check(
        result[0].addedOrModifiedLineRanges,
      ).deepEquals([const LineRange(2, 2)]);
      check(result[1].path).equals('lib/b.dart');
      check(
        result[1].addedOrModifiedLineRanges,
      ).deepEquals([const LineRange(6, 6)]);
    });

    test('handles single line hunks and no newline comment', () {
      const diff = r'''
diff --git a/lib/c.dart b/lib/c.dart
--- a/lib/c.dart
+++ b/lib/c.dart
@@ -1 +1,2 @@
-one
+two
+three
\ No newline at end of file
''';

      final result = GitDiffParser.parse(diff);
      check(result.length).equals(1);
      check(
        result.first.addedOrModifiedLineRanges,
      ).deepEquals([const LineRange(1, 2)]);
    });

    test('returns empty list for empty diff string', () {
      check(GitDiffParser.parse('')).isEmpty();
      check(GitDiffParser.parse('   \n  \n')).isEmpty();
    });

    test('handles single double-quote path without throwing RangeError', () {
      const diff = 'diff --git " "\n--- "\n+++ "\n';
      final result = GitDiffParser.parse(diff);
      check(result).length.equals(1);
      check(result.first.path).equals('"');
    });

    test(
      'skips hunk headers with oversized line numbers instead of throwing',
      () {
        const diff = '''
diff --git a/lib/a.dart b/lib/a.dart
--- a/lib/a.dart
+++ b/lib/a.dart
@@ -9999999999999999999999999 +1 @@
+ignored
@@ -1,1 +1,2 @@
 line1
+line2
''';
        final result = GitDiffParser.parse(diff);
        check(result).length.equals(1);
        check(result.first.hunks).length.equals(1);
        check(
          result.first.addedOrModifiedLineRanges,
        ).deepEquals([const LineRange(2, 2)]);
      },
    );

    test('clamps extreme 64-bit hunk start line numbers without overflow', () {
      const diff = '''
diff --git a/lib/a.dart b/lib/a.dart
--- a/lib/a.dart
+++ b/lib/a.dart
@@ -1 +9223372036854775807 @@
+line1
+line2
''';
      final result = GitDiffParser.parse(diff);
      check(result).length.equals(1);
      check(result.first.hunks).length.equals(1);
      check(result.first.addedOrModifiedLineRanges).length.equals(1);
    });
  });
}
