import 'package:analytica/testing.dart';
import 'package:checks/checks.dart';
import 'package:dedupe/src/engine.dart';
import 'package:test/test.dart';

void main() {
  test('dedupeVersion matches pubspec.yaml', () async {
    final pubspecFile = await resolvePackageFile(
      'package:dedupe/dedupe.dart',
      'pubspec.yaml',
    );
    check(pubspecFile.existsSync()).isTrue();

    final content = pubspecFile.readAsStringSync();
    final versionMatch = RegExp(
      r'^version:\s*(.+)$',
      multiLine: true,
    ).firstMatch(content);
    check(versionMatch).isNotNull();
    final pubspecVersion = versionMatch!.group(1)!.trim();

    check(dedupeVersion).equals(pubspecVersion);
  });
}
