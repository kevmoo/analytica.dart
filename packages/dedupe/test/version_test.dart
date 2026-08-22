import 'dart:io';

import 'package:checks/checks.dart';
import 'package:dedupe/src/engine.dart';
import 'package:test/test.dart';

void main() {
  test('dedupeVersion matches pubspec.yaml', () {
    final pubspecFile =
        File('pubspec.yaml').existsSync() &&
            File('pubspec.yaml').readAsStringSync().contains('name: dedupe')
        ? File('pubspec.yaml')
        : File('packages/dedupe/pubspec.yaml');
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
