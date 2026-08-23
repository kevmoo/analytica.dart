import 'package:checks/checks.dart';
import 'package:lower_bound/lower_bound.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

void main() {
  group('Models', () {
    test('DependencyFloor toJson and toString', () {
      final floor = DependencyFloor(
        name: 'args',
        declaredConstraint: VersionConstraint.parse('^2.7.0'),
        lowerBound: Version(2, 7, 0),
        isLocalPathOverride: false,
      );

      check(floor.name).equals('args');
      check(floor.lowerBound).equals(Version(2, 7, 0));
      check(floor.isLocalPathOverride).isFalse();
      check(floor.toString()).contains('args: ^2.7.0 (floor: 2.7.0)');

      final json = floor.toJson();
      check(json['name']).equals('args');
      check(json['declared']).equals('^2.7.0');
      check(json['lowerBound']).equals('2.7.0');
      check(json['isLocalPathOverride']).equals(false);
    });

    test('DependencyFloor with local path override', () {
      final floor = DependencyFloor(
        name: 'pkg_a',
        declaredConstraint: VersionConstraint.parse('^0.1.0'),
        lowerBound: Version(0, 1, 0),
        isLocalPathOverride: true,
        localPath: '/path/to/pkg_a',
        localVersion: '0.1.0-wip',
      );

      check(floor.isLocalPathOverride).isTrue();
      check(floor.toString()).contains('local path override');

      final json = floor.toJson();
      check(json['isLocalPathOverride']).equals(true);
      check(json['localPath']).equals('/path/to/pkg_a');
      check(json['localVersion']).equals('0.1.0-wip');
    });

    test('LowerBoundValidationResult toJson and isClean', () {
      final result = LowerBoundValidationResult(
        packageName: 'my_pkg',
        packagePath: '/path/to/my_pkg',
        minSdk: Version(3, 12, 0),
        dependencies: [
          DependencyFloor(
            name: 'path',
            declaredConstraint: VersionConstraint.parse('^1.9.0'),
            lowerBound: Version(1, 9, 0),
          ),
        ],
        resolvedVersions: {'path': Version(1, 9, 0)},
        pubGetSuccess: true,
        analyzeSuccess: true,
      );

      check(result.isClean).isTrue();
      final json = result.toJson();
      check(json['package']).equals('my_pkg');
      check(json['clean']).equals(true);
      check(json['pubGetSuccess']).equals(true);
      check(json['analyzeSuccess']).equals(true);
    });
  });
}
