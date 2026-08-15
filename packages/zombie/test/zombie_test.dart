import 'package:checks/checks.dart';
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;
import 'package:zombie/zombie.dart';

d.DirectoryDescriptor packageConfig(String pkgName) {
  return d.dir('.dart_tool', [
    d.file('package_config.json', '''
{
  "configVersion": 2,
  "packages": [
    {
      "name": "$pkgName",
      "rootUri": "../",
      "packageUri": "lib/",
      "languageVersion": "3.5"
    }
  ]
}
'''),
  ]);
}

void main() {
  test('zombie public library exports and basic analysis workflow', () async {
    await d.dir('sanity_pkg', [
      packageConfig('sanity_pkg'),
      d.file('pubspec.yaml', '''
name: sanity_pkg
environment:
  sdk: '^3.5.0'
'''),
      d.dir('lib', [
        d.file('sanity_pkg.dart', 'export "src/live.dart";'),
        d.dir('src', [
          d.file('live.dart', 'void live() {}'),
          d.file('dead.dart', 'void dead() {}'),
        ]),
      ]),
    ]).create();

    final report = await analyzePackage(d.path('sanity_pkg'));
    check(report.package).equals('sanity_pkg');
    check(report.pureZombiesFound).equals(1);
    check(report.zombies.single.name).equals('dead');

    const jsonFormatter = JsonFormatter();
    final jsonStr = jsonFormatter.format(report);
    check(jsonStr).contains('"pureZombies": 1');

    const mdFormatter = MarkdownFormatter();
    final mdStr = mdFormatter.format(report);
    check(mdStr).contains('`dead`');
  });
}
