import 'dart:io';

import 'package:checks/checks.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';
import 'package:zombie/src/cli.dart';

void main() {
  test('zombieVersion matches pubspec.yaml', () {
    final pubspecFile = File('pubspec.yaml');
    check(pubspecFile.existsSync()).isTrue();

    final content = pubspecFile.readAsStringSync();
    final doc = loadYaml(content) as YamlMap;
    final pubspecVersion = doc['version'] as String;

    check(zombieVersion).equals(pubspecVersion);
  });
}
