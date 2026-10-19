import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Directory _getRepoRoot() {
  var dir = Directory.current;
  while (!File(p.join(dir.path, 'pubspec.yaml')).existsSync() ||
      !Directory(p.join(dir.path, 'skills')).existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      return Directory.current.path.endsWith('tool')
          ? Directory.current.parent
          : Directory.current;
    }
    dir = parent;
  }
  return dir;
}

List<File> _findEvalsFiles(Directory baseDir) {
  if (!baseDir.existsSync()) {
    return [];
  }
  return baseDir.listSync(recursive: true).whereType<File>().where((f) {
    final name = p.basename(f.path);
    return name == 'evals.json' || name.endsWith('_evals.json');
  }).toList();
}

Map<String, dynamic> _decodeJsonMap(File file) {
  final decoded = jsonDecode(file.readAsStringSync());
  expect(
    decoded,
    isA<Map<String, dynamic>>(),
    reason: '${file.path} must be a JSON map.',
  );
  return decoded as Map<String, dynamic>;
}

void _verifyStructuralConsistency(List<File> files, String itemsKey) {
  Set<String>? expectedRootKeys;
  String? expectedRootKeysFilePath;
  Set<String>? expectedItemKeys;
  String? expectedItemFilePath;

  for (final file in files) {
    final decodedMap = _decodeJsonMap(file);
    final rootKeys = decodedMap.keys.toSet();
    expectedRootKeys ??= rootKeys;
    expectedRootKeysFilePath ??= file.path;
    expect(
      rootKeys,
      equals(expectedRootKeys),
      reason:
          '${file.path} root keys do not match consistency pattern. '
          'Expected keys to match the first processed file '
          '($expectedRootKeysFilePath).',
    );

    final itemsRaw = decodedMap[itemsKey];
    expect(
      itemsRaw,
      isA<List<dynamic>>(),
      reason: '$itemsKey key in ${file.path} must be a List.',
    );
    for (final item in itemsRaw as List<dynamic>) {
      expect(
        item,
        isA<Map<String, dynamic>>(),
        reason: 'Item in $itemsKey list in ${file.path} must be a JSON map.',
      );
      final itemKeys = (item as Map<String, dynamic>).keys.toSet();
      expectedItemKeys ??= itemKeys;
      expectedItemFilePath ??= file.path;
      expect(
        itemKeys,
        equals(expectedItemKeys),
        reason:
            'Item in ${file.path} keys do not match consistency pattern. '
            'Expected item keys to match the first processed file '
            '($expectedItemFilePath).',
      );
    }
  }
}

void main() {
  group('Evals structure consistency', () {
    test(
      'all evals.json files across skills share consistent structure and keys',
      () {
        final repoRoot = _getRepoRoot();
        final evalsFiles = [
          ..._findEvalsFiles(Directory(p.join(repoRoot.path, 'skills'))),
          ..._findEvalsFiles(Directory(p.join(repoRoot.path, 'evals'))),
        ]..sort((a, b) => a.path.compareTo(b.path));

        expect(
          evalsFiles,
          isNotEmpty,
          reason:
              'Should find at least one evals.json file in skills or evals.',
        );

        _verifyStructuralConsistency(evalsFiles, 'evals');
      },
    );

    test('all published skills with evals have an evals.json file', () {
      final repoRoot = _getRepoRoot();
      final skillsDir = Directory(p.join(repoRoot.path, 'skills'));
      final skillDirsWithEvals = skillsDir
          .listSync()
          .whereType<Directory>()
          .where((dir) => Directory(p.join(dir.path, 'evals')).existsSync())
          .toList();

      expect(
        skillDirsWithEvals,
        isNotEmpty,
        reason: 'Expected at least one published skill to define evals.',
      );

      for (final skillDir in skillDirsWithEvals) {
        final evalsFile = File(p.join(skillDir.path, 'evals', 'evals.json'));
        final skillName = p.basename(skillDir.path);
        expect(
          evalsFile.existsSync(),
          isTrue,
          reason:
              'Published skill "$skillName" has an evals directory but '
              'is missing an evals.json file at ${evalsFile.path}',
        );
      }
    });

    test(
      'all referenced rubrics in evals.json exist and have valid structure',
      () {
        final repoRoot = _getRepoRoot();
        final evalsFiles = [
          ..._findEvalsFiles(Directory(p.join(repoRoot.path, 'skills'))),
          ..._findEvalsFiles(Directory(p.join(repoRoot.path, 'evals'))),
        ];

        expect(evalsFiles, isNotEmpty);

        for (final file in evalsFiles) {
          final decodedMap = _decodeJsonMap(file);
          final repoCriteriaRaw =
              decodedMap['repo_criteria'] ?? const <Object?>[];
          expect(
            repoCriteriaRaw,
            isA<List<dynamic>>(),
            reason: 'repo_criteria in ${file.path} must be a List.',
          );

          for (final rubricPath in repoCriteriaRaw as List<dynamic>) {
            expect(rubricPath, isA<String>());
            final rubricFile = File(
              p.join(repoRoot.path, rubricPath as String),
            );
            expect(
              rubricFile.existsSync(),
              isTrue,
              reason:
                  'Referenced rubric "$rubricPath" in ${file.path} does not '
                  'exist at ${rubricFile.path}',
            );

            final rubricMap = _decodeJsonMap(rubricFile);
            expect(
              rubricMap['evals'],
              isA<List<dynamic>>(),
              reason: '${rubricFile.path} must contain an "evals" array.',
            );
          }
        }
      },
    );

    test(
      'all rubric JSON files in evals/ share consistent structure and keys',
      () {
        final repoRoot = _getRepoRoot();
        final rubricsDir = Directory(p.join(repoRoot.path, 'evals'));
        final rubricFiles =
            rubricsDir
                .listSync()
                .whereType<File>()
                .where(
                  (f) =>
                      f.path.endsWith('.json') &&
                      !f.path.endsWith('_evals.json') &&
                      p.basename(f.path) != 'evals.json',
                )
                .toList()
              ..sort((a, b) => a.path.compareTo(b.path));

        expect(rubricFiles, isNotEmpty);
        _verifyStructuralConsistency(rubricFiles, 'evals');
      },
    );

    test('skills.sh.json groups all published skills', () {
      final repoRoot = _getRepoRoot();
      final skillsDir = Directory(p.join(repoRoot.path, 'skills'));
      final actualSkills = skillsDir
          .listSync()
          .whereType<Directory>()
          .where((dir) => File(p.join(dir.path, 'SKILL.md')).existsSync())
          .map((dir) => p.basename(dir.path))
          .toSet();

      final configFile = File(p.join(repoRoot.path, 'skills.sh.json'));
      expect(configFile.existsSync(), isTrue);

      final decoded = _decodeJsonMap(configFile);
      expect(
        decoded[r'$schema'],
        'https://skills.sh/schemas/skills.sh.schema.json',
      );
      expect(decoded['notGrouped'], 'bottom');

      final groupings = (decoded['groupings'] as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(groupings, isNotEmpty);

      final groupedSkills = <String>{};
      for (final group in groupings) {
        expect(
          group['title'],
          isA<String>().having(
            (s) =>
                s.trim().isNotEmpty &&
                s.trim().split(RegExp(r'\s+')).length <= 3,
            '1-3 words',
            isTrue,
          ),
        );
        expect(
          group['description'],
          isA<String>().having((s) => s.isNotEmpty, 'non-empty', isTrue),
        );
        final skills = (group['skills'] as List<Object?>).cast<String>();
        expect(skills, isNotEmpty);
        expect(skills.toSet(), hasLength(skills.length));
        expect(
          groupedSkills.intersection(skills.toSet()),
          isEmpty,
          reason: 'Duplicate skill in skills.sh.json',
        );
        groupedSkills.addAll(skills);
      }

      expect(groupedSkills, equals(actualSkills));
    });
  });
}
