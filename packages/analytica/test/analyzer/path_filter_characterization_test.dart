import 'package:analytica/analyzer.dart';
import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';

/// Golden matrix pinning [PathFilter] matching behaviour.
///
/// Every expectation here was captured from the running implementation rather
/// than written by hand, so the matrix records what the filter *does*, not what
/// it was assumed to do. Its purpose is to make behaviour changes to the
/// matching engine visible in review: a change that edits no rows is
/// behaviour-preserving, and a change that edits rows has documented precisely
/// what it altered.
///
/// Exclusion is not opt-in — [PathFilter.defaults] applies fifteen patterns to
/// every scanned file before any `--exclude` is supplied — so a silent
/// regression here changes the output of every tool in the workspace.
typedef _Case = ({String path, bool excluded});

void _expectAll(PathFilter filter, List<_Case> cases) {
  for (final c in cases) {
    check(
      because: 'isExcluded(${_show(c.path)})',
      filter.isExcluded(c.path),
    ).equals(c.excluded);
  }
}

String _show(String s) => "'${s.replaceAll(r'\', r'\\')}'";

void main() {
  group('PathFilter characterization: defaults', () {
    test('generated files, at every depth', () {
      _expectAll(PathFilter.defaults, const [
        (path: 'lib/src/model.g.dart', excluded: true),
        // Root-level generated files: the case a naive glob port loses,
        // because `**/` there requires at least one directory.
        (path: 'model.g.dart', excluded: true),
        (path: 'a/b/c/model.g.dart', excluded: true),
        (path: 'lib/src/model.freezed.dart', excluded: true),
        (path: 'model.freezed.dart', excluded: true),
        (path: 'test/service.mocks.dart', excluded: true),
        (path: 'lib/di.config.dart', excluded: true),
        (path: 'lib/generated.reflectable.dart', excluded: true),
        (path: 'lib/assets.gen.dart', excluded: true),
        (path: 'lib/schema.pb.dart', excluded: true),
        (path: 'lib/schema.pbenum.dart', excluded: true),
        (path: 'lib/schema.pbjson.dart', excluded: true),
        (path: 'lib/schema.pbserver.dart', excluded: true),
        (path: 'lib/src/model.dart', excluded: false),
        (path: 'lib/generator.dart', excluded: false),
      ]);
    });

    test('ignored directories, including the bare directory itself', () {
      _expectAll(PathFilter.defaults, const [
        (path: '.dart_tool/package_config.json', excluded: true),
        // Matched at any depth, not only at the root.
        (path: 'lib/.dart_tool/x.dart', excluded: true),
        (path: '.dart_tool', excluded: true),
        (path: '.git/HEAD', excluded: true),
        (path: 'packages/p/.git/HEAD', excluded: true),
        (path: '.git', excluded: true),
        (path: '.idea/workspace.xml', excluded: true),
        (path: '.vscode/settings.json', excluded: true),
        (path: 'build/app/outputs', excluded: true),
        (path: 'build', excluded: true),
      ]);
    });

    test('build is root-anchored, and lookalikes are not excluded', () {
      _expectAll(PathFilter.defaults, const [
        (path: 'lib/src/build/builder.dart', excluded: false),
        (path: 'packages/p/build/bin.dart', excluded: false),
        (path: 'lib/builders/code_builder.dart', excluded: false),
        (path: '.github/workflows/ci.yml', excluded: false),
      ]);
    });

    test('path prefixes are normalized, and matching is case-sensitive', () {
      _expectAll(PathFilter.defaults, const [
        (path: './lib/model.g.dart', excluded: true),
        (path: '/lib/model.g.dart', excluded: true),
        (path: r'lib\src\model.g.dart', excluded: true),
        (path: 'LIB/MODEL.G.DART', excluded: false),
      ]);
    });

    test('ignoreGenerated: false keeps directory exclusion active', () {
      _expectAll(PathFilter(ignoreGenerated: false), const [
        (path: 'lib/src/model.g.dart', excluded: false),
        (path: 'model.g.dart', excluded: false),
        (path: '.dart_tool/x', excluded: true),
        (path: 'build/x', excluded: true),
        (path: 'lib/src/model.dart', excluded: false),
      ]);
    });
  });

  group('PathFilter characterization: pattern shapes', () {
    test('interior ** spans zero or more directories', () {
      // Distinct from a leading `**/`: a port that relaxes only the leading
      // occurrence silently stops matching `lib/model.g.dart` here.
      _expectAll(
        PathFilter(
          excludePatterns: ['lib/**/*.g.dart'],
          ignoreGenerated: false,
        ),
        const [
          (path: 'lib/model.g.dart', excluded: true),
          (path: 'lib/x/model.g.dart', excluded: true),
          (path: 'lib/x/y/model.g.dart', excluded: true),
          (path: 'model.g.dart', excluded: false),
          (path: 'test/model.g.dart', excluded: false),
        ],
      );
    });

    test('consecutive ** segments collapse', () {
      // `replaceAll` is non-overlapping, so a run of `**/` would otherwise
      // leave all but the first unrelaxed and stop matching at the root.
      _expectAll(
        PathFilter(excludePatterns: ['**/**/x.dart'], ignoreGenerated: false),
        const [
          (path: 'x.dart', excluded: true),
          (path: 'lib/x.dart', excluded: true),
          (path: 'a/b/x.dart', excluded: true),
          (path: 'lib/y.dart', excluded: false),
        ],
      );
    });

    test('a slash-less pattern matches at any depth', () {
      _expectAll(
        PathFilter(excludePatterns: ['legacy_*.dart'], ignoreGenerated: false),
        const [
          (path: 'legacy_a.dart', excluded: true),
          (path: 'lib/legacy_a.dart', excluded: true),
          (path: 'lib/src/legacy_a.dart', excluded: true),
          (path: 'lib/other.dart', excluded: false),
          (path: 'lib/x_legacy_a.dart', excluded: false),
        ],
      );
    });

    test('trailing ** requires at least one segment beneath', () {
      _expectAll(
        PathFilter(
          excludePatterns: ['test/fixtures/**'],
          ignoreGenerated: false,
        ),
        const [
          (path: 'test/fixtures/a.dart', excluded: true),
          (path: 'test/fixtures/a/b.dart', excluded: true),
          (path: 'test/fixtures', excluded: false),
          (path: 'test/other/a.dart', excluded: false),
        ],
      );
    });

    test('leading ./ and / are stripped from patterns', () {
      _expectAll(
        PathFilter(
          excludePatterns: ['/custom/**', './other/**'],
          ignoreGenerated: false,
        ),
        const [
          (path: r'.\custom\sub\file.dart', excluded: true),
          (path: './custom/sub/file.dart', excluded: true),
          (path: '/custom/sub/file.dart', excluded: true),
          (path: 'custom/sub/file.dart', excluded: true),
          (path: 'other/sub/file.dart', excluded: true),
          (path: 'unrelated/x.dart', excluded: false),
        ],
      );
    });

    test('* and ? stop at a separator', () {
      _expectAll(
        PathFilter(excludePatterns: ['a?.dart'], ignoreGenerated: false),
        const [
          (path: 'ab.dart', excluded: true),
          (path: 'lib/ab.dart', excluded: true),
          (path: 'a/b.dart', excluded: false),
          (path: 'abc.dart', excluded: false),
        ],
      );
      _expectAll(
        PathFilter(excludePatterns: ['lib/*.dart'], ignoreGenerated: false),
        const [
          (path: 'lib/a.dart', excluded: true),
          (path: 'lib/x/a.dart', excluded: false),
          (path: 'a.dart', excluded: false),
        ],
      );
    });

    test('degenerate patterns', () {
      _expectAll(
        PathFilter(excludePatterns: ['**'], ignoreGenerated: false),
        const [
          (path: 'a.dart', excluded: true),
          (path: 'lib/a.dart', excluded: true),
        ],
      );
      // `**/` alone matches nothing; it is not a synonym for `**`.
      _expectAll(
        PathFilter(excludePatterns: ['**/'], ignoreGenerated: false),
        const [
          (path: 'a.dart', excluded: false),
          (path: 'lib/a.dart', excluded: false),
        ],
      );
    });

    test('blank patterns are inert rather than an error', () {
      // A trailing comma or an unset CI variable produces these.
      for (final blank in ['', '   ']) {
        check(
          because: 'blank pattern ${_show(blank)}',
          PathFilter(
            excludePatterns: [blank],
            ignoreGenerated: false,
          ).isExcluded('a.dart'),
        ).isFalse();
      }
    });
  });

  group('PathFilter characterization: glob metacharacters', () {
    // CHANGED by the move to package:glob. Previously every metacharacter was
    // escaped and matched literally; they are now glob syntax. This is the
    // point of the change, but it is a breaking one for any pattern that
    // relied on the old literal reading.
    test('bracket characters are a character class, not literal', () {
      _expectAll(
        PathFilter(excludePatterns: [r'lib/a[0].dart'], ignoreGenerated: false),
        const [
          // Was `true` under the literal matcher.
          (path: 'lib/a[0].dart', excluded: false),
          // Was `false`.
          (path: 'lib/a0.dart', excluded: true),
        ],
      );
    });

    test('a brace group with a single option is a syntax error', () {
      // Was matched literally and silently. Failing loudly is the intended
      // trade: a pattern that cannot mean what the author wrote should say so.
      check(
          () => PathFilter(excludePatterns: [r'lib/b{c}.dart']),
        ).throws<FormatException>().has((e) => e.message, 'message')
        ..contains(r'lib/b{c}.dart')
        ..contains('Invalid exclude pattern');
    });
  });

  group('PathFilter characterization: paths outside the scanned tree', () {
    test('../ prefixes', () {
      // undead --extra-roots and multi-target runs produce these via
      // p.relative().
      check(PathFilter.defaults.isExcluded('../lib/model.g.dart')).isTrue();
      _expectAll(
        PathFilter(excludePatterns: ['custom/**'], ignoreGenerated: false),
        const [
          // CHANGED, both were `false`. Escaping segments are now stripped
          // before matching, so a root-anchored pattern applies to an
          // out-of-tree path by its in-tree remainder. Without the strip the
          // asymmetry runs the other way and `**` stops absorbing `../`,
          // which would silently un-exclude generated files under an extra
          // root -- the more damaging direction of the two.
          (path: '../custom/x.dart', excluded: true),
          (path: '../../custom/x.dart', excluded: true),
          (path: 'custom/x.dart', excluded: true),
        ],
      );
    });
  });
}
