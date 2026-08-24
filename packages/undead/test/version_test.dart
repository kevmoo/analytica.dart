import 'package:analytica/testing.dart';
import 'package:checks/checks.dart';
import 'package:test/test.dart';
import 'package:undead/src/cli.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('undeadVersion matches pubspec.yaml', () async {
    final pubspecFile = await resolvePackageFile(
      'package:undead/undead.dart',
      'pubspec.yaml',
    );
    check(pubspecFile.existsSync()).isTrue();

    final content = pubspecFile.readAsStringSync();
    final doc = loadYaml(content) as YamlMap;
    final pubspecVersion = doc['version'] as String;

    check(undeadVersion).equals(pubspecVersion);
  });
}
