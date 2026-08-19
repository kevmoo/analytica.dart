import 'package:checks/checks.dart';
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;
import 'package:undead/undead.dart';

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
  group('ReachabilityEngine', () {
    test('detects unexported top-level function as pure undead', () async {
      await d.dir('pure_undead_pkg', [
        packageConfig('pure_undead_pkg'),
        d.file('pubspec.yaml', '''
name: pure_undead_pkg
environment:
  sdk: '^3.5.0'
'''),
        d.dir('lib', [
          d.file('pure_undead_pkg.dart', '''
export 'src/live.dart';
'''),
          d.dir('src', [
            d.file('live.dart', 'void liveFunc() {}'),
            d.file('dead.dart', 'void deadFunc() {}'),
          ]),
        ]),
      ]).create();

      final report = await analyzePackage(d.path('pure_undead_pkg'));
      check(report.pureUndeadFound).equals(1);
      check(report.testedUndeadFound).equals(0);
      check(report.coInvokedHazardsFound).equals(0);

      final undead = report.undead.single;
      check(undead.name).equals('deadFunc');
      check(undead.kind).equals(DeclarationKind.function);
      check(undead.classification).equals(UndeadClassification.pureUndead);
      check(undead.suggestedAction).equals(SuggestedAction.delete);
    });

    test('detects tested undead and associates orphan test sites', () async {
      await d.dir('tested_undead_pkg', [
        packageConfig('tested_undead_pkg'),
        d.file('pubspec.yaml', '''
name: tested_undead_pkg
environment:
  sdk: '^3.5.0'
'''),
        d.dir('lib', [
          d.file('tested_undead_pkg.dart', '''
export 'src/live.dart';
'''),
          d.dir('src', [
            d.file('live.dart', 'class LiveService {}'),
            d.file('old_parser.dart', '''
class OldParser {
  String parse(String s) => s.toLowerCase();
}
'''),
          ]),
        ]),
        d.dir('test', [
          d.file('old_parser_test.dart', '''
import 'package:tested_undead_pkg/src/old_parser.dart';

void test(String desc, Function body) {}

void main() {
  test('OldParser parses correctly', () {
    final parser = OldParser();
    parser.parse('FOO');
  });
}
'''),
        ]),
      ]).create();

      final report = await analyzePackage(d.path('tested_undead_pkg'));
      check(report.pureUndeadFound).equals(0);
      check(report.testedUndeadFound).equals(1);
      check(report.coInvokedHazardsFound).equals(0);

      final undead = report.undead.single;
      check(undead.name).equals('OldParser');
      check(undead.kind).equals(DeclarationKind.classType);
      check(undead.classification).equals(UndeadClassification.testedUndead);
      check(
        undead.suggestedAction,
      ).equals(SuggestedAction.deleteWithOrphanTests);

      final orphanTests = undead.orphanTests!;
      check(orphanTests.length).equals(1);
      check(orphanTests.first.file).equals('test/old_parser_test.dart');
      check(orphanTests.first.description).equals('OldParser parses correctly');
      check(orphanTests.first.coInvokedHazard).isFalse();
    });

    test(
      'detects co-invoked test hazard when test references live and dead code',
      () async {
        await d.dir('co_invoked_pkg', [
          packageConfig('co_invoked_pkg'),
          d.file('pubspec.yaml', '''
name: co_invoked_pkg
environment:
  sdk: '^3.5.0'
'''),
          d.dir('lib', [
            d.file('co_invoked_pkg.dart', '''
export 'src/live.dart';
'''),
            d.dir('src', [
              d.file('live.dart', '''
class LivePipeline {
  void process(String input) {}
}
'''),
              d.file('legacy_helper.dart', '''
class LegacyHelper {
  static String format(String s) => s.trim();
}
'''),
            ]),
          ]),
          d.dir('test', [
            d.file('pipeline_test.dart', '''
import 'package:co_invoked_pkg/src/legacy_helper.dart';
import 'package:co_invoked_pkg/src/live.dart';

void test(String desc, Function body) {}

void main() {
  test('pipeline formats output', () {
    final intermediate = LegacyHelper.format(' input ');
    final pipeline = LivePipeline();
    pipeline.process(intermediate);
  });
}
'''),
          ]),
        ]).create();

        final report = await analyzePackage(d.path('co_invoked_pkg'));
        check(report.pureUndeadFound).equals(0);
        check(report.testedUndeadFound).equals(0);
        check(report.coInvokedHazardsFound).equals(1);

        final hazard = report.undead.single;
        check(hazard.name).equals('LegacyHelper');
        check(
          hazard.classification,
        ).equals(UndeadClassification.coInvokedHazard);
        check(
          hazard.suggestedAction,
        ).equals(SuggestedAction.manualRefactorHazard);

        final orphanTests = hazard.orphanTests!;
        check(orphanTests.first.coInvokedHazard).isTrue();
      },
    );

    test('preserves direct subtypes of live sealed classes for pattern '
        'exhaustiveness', () async {
      await d.dir('sealed_pkg', [
        packageConfig('sealed_pkg'),
        d.file('pubspec.yaml', '''
name: sealed_pkg
environment:
  sdk: '^3.5.0'
'''),
        d.dir('lib', [
          d.file('sealed_pkg.dart', '''
export 'src/ast.dart';
'''),
          d.dir('src', [
            d.file('ast.dart', '''
sealed class AstNode {}
class LiteralNode extends AstNode {}
class IdentifierNode extends AstNode {}
// Uninstantiated subtype required for switch exhaustiveness:
class UnusedCommentNode extends AstNode {}
'''),
          ]),
        ]),
      ]).create();

      final report = await analyzePackage(d.path('sealed_pkg'));
      check(report.undead).isEmpty();
      check(report.pureUndeadFound).equals(0);
    });

    test(
      'preserves exported symbols under Open-World Invariant (library mode)',
      () async {
        await d.dir('open_world_pkg', [
          packageConfig('open_world_pkg'),
          d.file('pubspec.yaml', '''
name: open_world_pkg
environment:
  sdk: '^3.5.0'
'''),
          d.dir('lib', [
            d.file('open_world_pkg.dart', '''
export 'src/public_feature.dart';
'''),
            d.dir('src', [
              d.file('public_feature.dart', '''
class PublicClient {
  void connect() {}
}
'''),
              d.file('internal_dead.dart', '''
class InternalDead {}
'''),
            ]),
          ]),
        ]).create();

        final report = await analyzePackage(d.path('open_world_pkg'));
        check(report.undead.length).equals(1);
        check(report.undead.single.name).equals('InternalDead');
      },
    );

    test('flags unreferenced exports under closed-app mode', () async {
      await d.dir('closed_app_pkg', [
        packageConfig('closed_app_pkg'),
        d.file('pubspec.yaml', '''
name: closed_app_pkg
environment:
  sdk: '^3.5.0'
'''),
        d.dir('lib', [
          d.file('closed_app_pkg.dart', '''
export 'src/unused_feature.dart';
'''),
          d.dir('src', [
            d.file('unused_feature.dart', '''
class UnusedFeature {}
'''),
          ]),
        ]),
        d.dir('bin', [
          d.file('main.dart', '''
void main() {
  print('App running');
}
'''),
        ]),
      ]).create();

      final report = await analyzePackage(
        d.path('closed_app_pkg'),
        options: UndeadOptions(
          packagePath: d.path('closed_app_pkg'),
          mode: AnalysisMode.closedApp,
        ),
      );

      check(report.undead.length).equals(1);
      check(report.undead.single.name).equals('UnusedFeature');
    });

    test('preserves code in example/ under demonstration mode', () async {
      await d.dir('example_demo_pkg', [
        packageConfig('example_demo_pkg'),
        d.file('pubspec.yaml', '''
name: example_demo_pkg
environment:
  sdk: '^3.5.0'
'''),
        d.dir('lib', [
          d.file('example_demo_pkg.dart', 'export "src/live.dart";'),
          d.dir('src', [
            d.file('live.dart', 'class MySdkClient {}'),
            d.file('helper_for_demo.dart', 'class DemoHelper {}'),
          ]),
        ]),
        d.dir('example', [
          d.file('main.dart', '''
import 'package:example_demo_pkg/src/helper_for_demo.dart';

// Illustrative model on pub.dev, not instantiated in main:
class UserExampleModel {
  final String name;
  UserExampleModel(this.name);
}

void main() {
  final helper = DemoHelper();
  print(helper);
}
'''),
        ]),
      ]).create();

      final report = await analyzePackage(d.path('example_demo_pkg'));
      check(report.undead).isEmpty();
    });

    test('preserves platform-conditional import branches', () async {
      await d.dir('conditional_pkg', [
        packageConfig('conditional_pkg'),
        d.file('pubspec.yaml', '''
name: conditional_pkg
environment:
  sdk: '^3.5.0'
'''),
        d.dir('lib', [
          d.file('conditional_pkg.dart', '''
export 'src/platform_io.dart'
  if (dart.library.js_interop) 'src/platform_web.dart';
'''),
          d.dir('src', [
            d.file('platform_io.dart', 'class PlatformImplementation {}'),
            d.file('platform_web.dart', 'class PlatformWebImplementation {}'),
            d.file('dead_util.dart', 'class DeadUtil {}'),
          ]),
        ]),
      ]).create();

      final report = await analyzePackage(d.path('conditional_pkg'));
      check(report.undead.length).equals(1);
      check(report.undead.single.name).equals('DeadUtil');
    });

    test(
      'respects // undead:ignore and // undead:ignore_for_file directives',
      () async {
        await d.dir('suppression_pkg', [
          packageConfig('suppression_pkg'),
          d.file('pubspec.yaml', '''
name: suppression_pkg
environment:
  sdk: '^3.5.0'
'''),
          d.dir('lib', [
            d.file('suppression_pkg.dart', 'export "src/live.dart";'),
            d.dir('src', [
              d.file('live.dart', 'void live() {}'),
              d.file('ignored_file.dart', '''
// undead:ignore_for_file
class IgnoredFileClass {}
void ignoredFileFunc() {}
'''),
              d.file('ignored_decl.dart', '''
// undead:ignore
class IgnoredClass {}

class DeadUnignoredClass {}
'''),
            ]),
          ]),
        ]).create();

        final report = await analyzePackage(d.path('suppression_pkg'));
        check(report.undead.length).equals(1);
        check(report.undead.single.name).equals('DeadUnignoredClass');
      },
    );

    test('preserves test support hooks annotated @visibleForTesting or named '
        'Fake*', () async {
      await d.dir('test_support_pkg', [
        packageConfig('test_support_pkg'),
        d.file('pubspec.yaml', '''
name: test_support_pkg
environment:
  sdk: '^3.5.0'
'''),
        d.dir('lib', [
          d.file('test_support_pkg.dart', 'export "src/live.dart";'),
          d.dir('src', [
            d.file('live.dart', 'class LiveClass {}'),
            d.file('fixtures.dart', '''
import 'package:meta/meta.dart';

@visibleForTesting
void resetInternalTestCache() {}

class FakeBackendService {}
class DeadWithoutHook {}
'''),
          ]),
        ]),
        d.dir('test', [
          d.file('cache_test.dart', '''
import 'package:test_support_pkg/src/fixtures.dart';

void test(String desc, Function body) {}

void main() {
  test('cache resets', () {
    resetInternalTestCache();
    final fake = FakeBackendService();
    print(fake);
  });
}
'''),
        ]),
      ]).create();

      final report = await analyzePackage(d.path('test_support_pkg'));
      check(report.undead.length).equals(1);
      check(report.undead.single.name).equals('DeadWithoutHook');
    });

    test('traverses executables (bin/) and auxiliary (tool/) entrypoints to '
        'lib/src/', () async {
      await d.dir('bin_tool_pkg', [
        packageConfig('bin_tool_pkg'),
        d.file('pubspec.yaml', '''
name: bin_tool_pkg
environment:
  sdk: '^3.5.0'
'''),
        d.dir('lib', [
          d.file('bin_tool_pkg.dart', 'void exported() {}'),
          d.dir('src', [
            d.file('bin_helper.dart', 'void binUtil() {}'),
            d.file('tool_helper.dart', 'void toolUtil() {}'),
            d.file('dead_helper.dart', 'void deadUtil() {}'),
          ]),
        ]),
        d.dir('bin', [
          d.file('my_cli.dart', '''
import 'package:bin_tool_pkg/src/bin_helper.dart';

void main() {
  binUtil();
}
'''),
        ]),
        d.dir('tool', [
          d.file('benchmark.dart', '''
import 'package:bin_tool_pkg/src/tool_helper.dart';

void main() {
  toolUtil();
}
'''),
        ]),
      ]).create();

      final report = await analyzePackage(d.path('bin_tool_pkg'));
      check(report.undead.length).equals(1);
      check(report.undead.single.name).equals('deadUtil');
    });

    test('scans diverse top-level declarations (enums, mixins, extensions, '
        'getters, setters, vars)', () async {
      await d.dir('decl_types_pkg', [
        packageConfig('decl_types_pkg'),
        d.file('pubspec.yaml', '''
name: decl_types_pkg
environment:
  sdk: '^3.5.0'
'''),
        d.dir('lib', [
          d.file('decl_types_pkg.dart', 'export "src/live.dart";'),
          d.dir('src', [
            d.file('live.dart', '''
import 'dead_decls.dart';

class LiveContainer {
  void use() {
    print(liveTopVar);
    final e = LiveEnum.val;
    print(e);
  }
}
'''),
            d.file('dead_decls.dart', '''
enum LiveEnum { val }
int liveTopVar = 1;

enum DeadEnum { a, b }
mixin DeadMixin {}
extension DeadExtension on String {}
extension type DeadExtType(int value) {}
typedef DeadAlias = int Function();
int deadTopVar = 42;
int get deadGetter => 10;
set deadSetter(int v) {}
'''),
          ]),
        ]),
      ]).create();

      final report = await analyzePackage(d.path('decl_types_pkg'));
      final names = report.undead.map((z) => z.name).toSet();

      check(names).contains('DeadEnum');
      check(names).contains('DeadMixin');
      check(names).contains('DeadExtension');
      check(names).contains('DeadExtType');
      check(names).contains('DeadAlias');
      check(names).contains('deadTopVar');
      check(names).contains('deadGetter');
      check(names).contains('deadSetter');

      check(names).not((it) => it.contains('LiveEnum'));
      check(names).not((it) => it.contains('liveTopVar'));
    });

    test('correctly distinguishes tested undead from co-invoked hazard in '
        'multi-test file', () async {
      await d.dir('multi_test_pkg', [
        packageConfig('multi_test_pkg'),
        d.file('pubspec.yaml', '''
name: multi_test_pkg
environment:
  sdk: '^3.5.0'
'''),
        d.dir('lib', [
          d.file('multi_test_pkg.dart', 'export "src/live.dart";'),
          d.dir('src', [
            d.file('live.dart', 'class LiveService { void run() {} }'),
            d.file('dead_parser.dart', 'class DeadParser { void parse() {} }'),
          ]),
        ]),
        d.dir('test', [
          d.file('combined_test.dart', '''
import 'package:multi_test_pkg/src/dead_parser.dart';
import 'package:multi_test_pkg/src/live.dart';

void test(String desc, Function body) {}

void main() {
  test('isolated dead parser test', () {
    final parser = DeadParser();
    parser.parse();
  });

  test('separate live service test', () {
    final service = LiveService();
    service.run();
  });
}
'''),
        ]),
      ]).create();

      final report = await analyzePackage(d.path('multi_test_pkg'));
      check(report.pureUndeadFound).equals(0);
      check(report.testedUndeadFound).equals(1);
      check(report.coInvokedHazardsFound).equals(0);

      final undead = report.undead.single;
      check(undead.name).equals('DeadParser');
      check(undead.classification).equals(UndeadClassification.testedUndead);
      check(
        undead.suggestedAction,
      ).equals(SuggestedAction.deleteWithOrphanTests);

      final orphanTests = undead.orphanTests!;
      check(orphanTests.length).equals(1);
      check(orphanTests.first.description).equals('isolated dead parser test');
      check(orphanTests.first.coInvokedHazard).isFalse();
    });

    test(
      'preserves sealed class direct subtypes via implements, with, and enums',
      () async {
        await d.dir('sealed_hierarchy_pkg', [
          packageConfig('sealed_hierarchy_pkg'),
          d.file('pubspec.yaml', '''
name: sealed_hierarchy_pkg
environment:
  sdk: '^3.5.0'
'''),
          d.dir('lib', [
            d.file('sealed_hierarchy_pkg.dart', 'export "src/union.dart";'),
            d.dir('src', [
              d.file('union.dart', '''
sealed class ResultType {}
class SuccessResult implements ResultType {}
enum ErrorResult implements ResultType { notFound, invalid }
mixin SpecialResult on ResultType {}
'''),
            ]),
          ]),
        ]).create();

        final report = await analyzePackage(d.path('sealed_hierarchy_pkg'));
        check(report.undead).isEmpty();
      },
    );

    test(
      'preserves foreign/native entrypoints annotated with @pragma or @Native',
      () async {
        await d.dir('native_pkg', [
          packageConfig('native_pkg'),
          d.file('pubspec.yaml', '''
name: native_pkg
environment:
  sdk: '^3.5.0'
'''),
          d.dir('lib', [
            d.file('native_pkg.dart', 'void exported() {}'),
            d.dir('src', [
              d.file('native_callbacks.dart', '''
@pragma('vm:entry-point')
void vmEntryPoint() {}

class DeadInternalClass {}
'''),
            ]),
          ]),
        ]).create();

        final report = await analyzePackage(d.path('native_pkg'));
        check(report.undead.length).equals(1);
        check(report.undead.single.name).equals('DeadInternalClass');
      },
    );

    test('preserves test hooks with prefixed annotations like '
        '@meta.visibleForTesting', () async {
      await d.dir('prefixed_meta_pkg', [
        packageConfig('prefixed_meta_pkg'),
        d.file('pubspec.yaml', '''
name: prefixed_meta_pkg
environment:
  sdk: '^3.5.0'
'''),
        d.dir('lib', [
          d.file('prefixed_meta_pkg.dart', 'export "src/live.dart";'),
          d.dir('src', [
            d.file('live.dart', 'class LiveClass {}'),
            d.file('hook.dart', '''
import 'package:meta/meta.dart' as meta;

@meta.visibleForTesting
void internalTestHook() {}
'''),
          ]),
        ]),
        d.dir('test', [
          d.file('hook_test.dart', '''
import 'package:prefixed_meta_pkg/src/hook.dart';

void test(String desc, Function body) {}

void main() {
  test('invokes hook', () {
    internalTestHook();
  });
}
'''),
        ]),
      ]).create();

      final report = await analyzePackage(d.path('prefixed_meta_pkg'));
      check(report.undead).isEmpty();
    });

    test('reaches extension operator overloads in expressions', () async {
      await d.dir('operator_pkg', [
        packageConfig('operator_pkg'),
        d.file('pubspec.yaml', '''
name: operator_pkg
environment:
  sdk: '^3.5.0'
'''),
        d.dir('lib', [
          d.file('operator_pkg.dart', 'export "src/live.dart";'),
          d.dir('src', [
            d.file('live.dart', '''
import 'operators.dart';

class LiveContainer {
  void calculate() {
    final a = CustomNum(5);
    final b = a + 10;
    print(b);
  }
}
'''),
            d.file('operators.dart', '''
class CustomNum {
  final int val;
  const CustomNum(this.val);
}

extension CustomNumOps on CustomNum {
  CustomNum operator +(int other) => CustomNum(val + other);
}

extension DeadOps on CustomNum {
  CustomNum operator -(int other) => CustomNum(val - other);
}
'''),
          ]),
        ]),
      ]).create();

      final report = await analyzePackage(d.path('operator_pkg'));
      check(report.undead.length).equals(1);
      check(report.undead.single.name).equals('DeadOps');
    });

    test(
      'reaches variables mutated via prefix and postfix operators',
      () async {
        await d.dir('prefix_postfix_pkg', [
          packageConfig('prefix_postfix_pkg'),
          d.file('pubspec.yaml', '''
name: prefix_postfix_pkg
environment:
  sdk: '^3.5.0'
'''),
          d.dir('lib', [
            d.file('prefix_postfix_pkg.dart', 'export "src/live.dart";'),
            d.dir('src', [
              d.file('live.dart', '''
import 'vars.dart';

class LiveContainer {
  void mutatePrefix() {
    ++prefixMutated;
    --prefixMutated2;
  }
  void mutatePostfix() {
    postfixMutated++;
    postfixMutated2--;
  }
}
'''),
              d.file('vars.dart', '''
int prefixMutated = 0;
int prefixMutated2 = 0;
int postfixMutated = 0;
int postfixMutated2 = 0;
int deadVar = 0;
'''),
            ]),
          ]),
        ]).create();

        final report = await analyzePackage(d.path('prefix_postfix_pkg'));
        final names = report.undead.map((z) => z.name).toSet();
        check(names).contains('deadVar');
        check(names).not((it) => it.contains('prefixMutated'));
        check(names).not((it) => it.contains('prefixMutated2'));
        check(names).not((it) => it.contains('postfixMutated'));
        check(names).not((it) => it.contains('postfixMutated2'));
      },
    );

    test(
      'resolves same-package package: URIs in conditional imports',
      () async {
        await d.dir('package_uri_cond_pkg', [
          packageConfig('package_uri_cond_pkg'),
          d.file('pubspec.yaml', '''
name: package_uri_cond_pkg
environment:
  sdk: '^3.5.0'
'''),
          d.dir('lib', [
            d.file('package_uri_cond_pkg.dart', '''
export 'src/platform_io.dart'
  if (dart.library.js_interop)
    'package:package_uri_cond_pkg/src/platform_web.dart';
'''),
            d.dir('src', [
              d.file('platform_io.dart', 'class IoPlatform {}'),
              d.file('platform_web.dart', 'class WebPlatform {}'),
              d.file('dead.dart', 'class UnusedDead {}'),
            ]),
          ]),
        ]).create();

        final report = await analyzePackage(d.path('package_uri_cond_pkg'));
        check(report.undead.length).equals(1);
        check(report.undead.single.name).equals('UnusedDead');
      },
    );

    test(
      'harvests lib/main.dart and lib/main_*.dart in closed-app mode',
      () async {
        await d.dir('flutter_closed_app_pkg', [
          packageConfig('flutter_closed_app_pkg'),
          d.file('pubspec.yaml', '''
name: flutter_closed_app_pkg
environment:
  sdk: '^3.5.0'
'''),
          d.dir('lib', [
            d.file('main.dart', '''
import 'src/live_service.dart';

void main() {
  LiveService.run();
}
'''),
            d.file('main_dev.dart', '''
import 'src/dev_service.dart';

void main() {
  DevService.runDev();
}
'''),
            d.file('unused_lib_file.dart', '''
void unusedTopLevel() {}
'''),
            d.dir('src', [
              d.file('live_service.dart', '''
class LiveService {
  static void run() {}
}
'''),
              d.file('dev_service.dart', '''
class DevService {
  static void runDev() {}
}
'''),
              d.file('dead_service.dart', '''
class DeadService {}
'''),
            ]),
          ]),
        ]).create();

        final report = await analyzePackage(
          d.path('flutter_closed_app_pkg'),
          options: UndeadOptions(
            packagePath: d.path('flutter_closed_app_pkg'),
            mode: AnalysisMode.closedApp,
          ),
        );

        check(report.pureUndeadFound).equals(2);
        check(report.testedUndeadFound).equals(0);
        check(report.coInvokedHazardsFound).equals(0);

        final undeadNames = report.undead.map((z) => z.name).toSet();
        check(undeadNames).contains('DeadService');
        check(undeadNames).contains('unusedTopLevel');
        check(undeadNames).not((it) => it.contains('LiveService'));
        check(undeadNames).not((it) => it.contains('DevService'));
      },
    );

    test('evaluates test sites strictly at leaf test invocations inside '
        'mixed group', () async {
      await d.dir('leaf_test_group_pkg', [
        packageConfig('leaf_test_group_pkg'),
        d.file('pubspec.yaml', '''
name: leaf_test_group_pkg
environment:
  sdk: '^3.5.0'
'''),
        d.dir('lib', [
          d.file('leaf_test_group_pkg.dart', 'export "src/live.dart";'),
          d.dir('src', [
            d.file('live.dart', 'class LiveClass { void liveAction() {} }'),
            d.file('dead.dart', 'class DeadClass { void deadAction() {} }'),
          ]),
        ]),
        d.dir('test', [
          d.file('mixed_group_test.dart', '''
import 'package:leaf_test_group_pkg/src/dead.dart';
import 'package:leaf_test_group_pkg/src/live.dart';

void group(String desc, Function body) {}
void test(String desc, Function body) {}

void main() {
  group('mixed group', () {
    test('tests live code only', () {
      final live = LiveClass();
      live.liveAction();
    });

    test('tests dead code only', () {
      final dead = DeadClass();
      dead.deadAction();
    });
  });
}
'''),
        ]),
      ]).create();

      final report = await analyzePackage(d.path('leaf_test_group_pkg'));
      check(report.pureUndeadFound).equals(0);
      check(report.testedUndeadFound).equals(1);
      check(report.coInvokedHazardsFound).equals(0);

      final undead = report.undead.single;
      check(undead.name).equals('DeadClass');
      check(undead.classification).equals(UndeadClassification.testedUndead);
      check(
        undead.suggestedAction,
      ).equals(SuggestedAction.deleteWithOrphanTests);

      final orphanTests = undead.orphanTests!;
      check(orphanTests.length).equals(1);
      check(orphanTests.first.description).equals('tests dead code only');
      check(orphanTests.first.coInvokedHazard).isFalse();
    });

    test(
      'records reachability edges from compound assignment operators',
      () async {
        await d.dir('compound_assignment_pkg', [
          packageConfig('compound_assignment_pkg'),
          d.file('pubspec.yaml', '''
name: compound_assignment_pkg
environment:
  sdk: '^3.5.0'
'''),
          d.dir('lib', [
            d.file('compound_assignment_pkg.dart', 'export "src/live.dart";'),
            d.dir('src', [
              d.file('live.dart', '''
import 'operators.dart';

class Accumulator {
  void run() {
    var c = Counter(10);
    c += 5;
    print(c.count);
  }
}
'''),
              d.file('operators.dart', '''
class Counter {
  final int count;
  const Counter(this.count);
}

extension CounterAdd on Counter {
  Counter operator +(int delta) => Counter(count + delta);
}

extension CounterSub on Counter {
  Counter operator -(int delta) => Counter(count - delta);
}
'''),
            ]),
          ]),
        ]).create();

        final report = await analyzePackage(d.path('compound_assignment_pkg'));
        check(report.pureUndeadFound).equals(1);
        final undead = report.undead.single;
        check(undead.name).equals('CounterSub');
      },
    );

    test('records outbound references from top-level variable type annotations '
        'and metadata', () async {
      await d.dir('toplevel_var_type_pkg', [
        packageConfig('toplevel_var_type_pkg'),
        d.file('pubspec.yaml', '''
name: toplevel_var_type_pkg
environment:
  sdk: '^3.5.0'
'''),
        d.dir('lib', [
          d.file('toplevel_var_type_pkg.dart', '''
export 'src/state.dart';
'''),
          d.dir('src', [
            d.file('state.dart', '''
import 'models.dart';

@AnnotationType()
late UninitializedType globalState;
'''),
            d.file('models.dart', '''
class UninitializedType {}
class AnnotationType {
  const AnnotationType();
}
class UnusedType {}
'''),
          ]),
        ]),
      ]).create();

      final report = await analyzePackage(d.path('toplevel_var_type_pkg'));
      check(report.pureUndeadFound).equals(1);
      check(report.undead.single.name).equals('UnusedType');
    });

    test('analyzes code inside lib/src/build/ without exclusion', () async {
      await d.dir('lib_src_build_reachability_pkg', [
        packageConfig('lib_src_build_reachability_pkg'),
        d.file('pubspec.yaml', '''
name: lib_src_build_reachability_pkg
environment:
  sdk: '^3.5.0'
'''),
        d.dir('lib', [
          d.file('lib_src_build_reachability_pkg.dart', '''
export 'src/build/code_generator.dart';
'''),
          d.dir('src', [
            d.dir('build', [
              d.file('code_generator.dart', '''
class CodeGenerator {
  void generate() {}
}
'''),
              d.file('unused_generator.dart', '''
class UnusedGenerator {}
'''),
            ]),
          ]),
        ]),
      ]).create();

      final report = await analyzePackage(
        d.path('lib_src_build_reachability_pkg'),
      );
      check(report.pureUndeadFound).equals(1);
      check(report.undead.single.name).equals('UnusedGenerator');
    });

    test('classifies ClassTypeAlias as classType and records superclass and '
        'mixin references', () async {
      await d.dir('class_type_alias_pkg', [
        packageConfig('class_type_alias_pkg'),
        d.file('pubspec.yaml', '''
name: class_type_alias_pkg
environment:
  sdk: '^3.5.0'
'''),
        d.dir('lib', [
          d.file('class_type_alias_pkg.dart', '''
export 'src/alias_usage.dart';
'''),
          d.dir('src', [
            d.file('alias_usage.dart', '''
import 'alias_def.dart';

class Service {
  void execute() {
    final live = LiveAlias();
    print(live);
  }
}
'''),
            d.file('alias_def.dart', '''
class BaseType {}
mixin UsedMixin {}
mixin UnusedMixin {}
abstract class UsedInterface {}

class LiveAlias = BaseType with UsedMixin implements UsedInterface;
class DeadAlias = BaseType with UnusedMixin;
'''),
          ]),
        ]),
      ]).create();

      final report = await analyzePackage(d.path('class_type_alias_pkg'));
      check(report.pureUndeadFound).equals(2);

      final undeadNames = report.undead.map((z) => z.name).toSet();
      check(undeadNames).contains('DeadAlias');
      check(undeadNames).contains('UnusedMixin');
      check(undeadNames).not((it) => it.contains('LiveAlias'));
      check(undeadNames).not((it) => it.contains('BaseType'));
      check(undeadNames).not((it) => it.contains('UsedMixin'));
      check(undeadNames).not((it) => it.contains('UsedInterface'));

      final deadAliasUndead = report.undead.firstWhere(
        (z) => z.name == 'DeadAlias',
      );
      check(deadAliasUndead.kind).equals(DeclarationKind.classType);
    });

    test('evaluates testWidgets and solo_test in nested groups', () async {
      await d.dir('widgets_solo_group_pkg', [
        packageConfig('widgets_solo_group_pkg'),
        d.file('pubspec.yaml', '''
name: widgets_solo_group_pkg
environment:
  sdk: '^3.5.0'
'''),
        d.dir('lib', [
          d.file('widgets_solo_group_pkg.dart', 'export "src/live.dart";'),
          d.dir('src', [
            d.file('live.dart', 'class LiveWidget {}'),
            d.file('dead_widget.dart', 'class DeadWidget {}'),
            d.file('solo_dead.dart', 'class SoloDeadWidget {}'),
          ]),
        ]),
        d.dir('test', [
          d.file('nested_widget_test.dart', '''
import 'package:widgets_solo_group_pkg/src/dead_widget.dart';
import 'package:widgets_solo_group_pkg/src/live.dart';
import 'package:widgets_solo_group_pkg/src/solo_dead.dart';

void group(String desc, Function body) {}
void testWidgets(String desc, Function body) {}
void solo_test(String desc, Function body) {}

void main() {
  group('outer', () {
    group('inner', () {
      testWidgets('tests live widget', () {
        final live = LiveWidget();
        print(live);
      });
      testWidgets('tests dead widget', () {
        final dead = DeadWidget();
        print(dead);
      });
      solo_test('tests solo dead', () {
        final solo = SoloDeadWidget();
        print(solo);
      });
    });
  });
}
'''),
        ]),
      ]).create();

      final report = await analyzePackage(d.path('widgets_solo_group_pkg'));
      check(report.pureUndeadFound).equals(0);
      check(report.testedUndeadFound).equals(2);
      check(report.coInvokedHazardsFound).equals(0);

      final deadNames = report.undead.map((z) => z.name).toSet();
      check(deadNames).contains('DeadWidget');
      check(deadNames).contains('SoloDeadWidget');
      check(deadNames).not((it) => it.contains('LiveWidget'));
    });

    test('records reachability edges from compound null-aware and '
        'multiplication operators', () async {
      await d.dir('compound_extra_pkg', [
        packageConfig('compound_extra_pkg'),
        d.file('pubspec.yaml', '''
name: compound_extra_pkg
environment:
  sdk: '^3.5.0'
'''),
        d.dir('lib', [
          d.file('compound_extra_pkg.dart', 'export "src/live.dart";'),
          d.dir('src', [
            d.file('live.dart', '''
import 'helpers.dart';

class Service {
  void run() {
    var v = ValueHolder(2);
    v *= 3;
    Holder? h;
    h ??= Holder();
    print(v);
    print(h);
  }
}
'''),
            d.file('helpers.dart', '''
class ValueHolder {
  final int val;
  ValueHolder(this.val);
  ValueHolder operator *(int mult) => ValueHolder(val * mult);
}

class Holder {}
class DeadHelper {}
'''),
          ]),
        ]),
      ]).create();

      final report = await analyzePackage(d.path('compound_extra_pkg'));
      check(report.pureUndeadFound).equals(1);
      check(report.undead.single.name).equals('DeadHelper');
    });

    test('records outbound references from multi-variable declarations with '
        'generic types', () async {
      await d.dir('multivar_type_pkg', [
        packageConfig('multivar_type_pkg'),
        d.file('pubspec.yaml', '''
name: multivar_type_pkg
environment:
  sdk: '^3.5.0'
'''),
        d.dir('lib', [
          d.file('multivar_type_pkg.dart', 'export "src/state.dart";'),
          d.dir('src', [
            d.file('state.dart', '''
import 'models.dart';

@AnnotationClass()
late List<ItemModel> itemsA, itemsB;
'''),
            d.file('models.dart', '''
class ItemModel {}
class AnnotationClass {
  const AnnotationClass();
}
class DeadItemModel {}
'''),
          ]),
        ]),
      ]).create();

      final report = await analyzePackage(d.path('multivar_type_pkg'));
      check(report.pureUndeadFound).equals(1);
      check(report.undead.single.name).equals('DeadItemModel');
    });

    test('strict @pragma entrypoint matching preserves only entrypoint '
        'pragmas (VULN-5)', () async {
      await d.dir('pragma_strict_pkg', [
        packageConfig('pragma_strict_pkg'),
        d.file('pubspec.yaml', '''
name: pragma_strict_pkg
environment:
  sdk: '^3.5.0'
'''),
        d.dir('lib', [
          d.file('pragma_strict_pkg.dart', 'class PublicApi {}'),
          d.dir('src', [
            d.file('service.dart', '''
@pragma('vm:entry-point')
void vmEntryPoint() {}

@pragma('vm:isolate-unsendable')
class IsolateUnsendableClass {}

@pragma('vm:prefer-inline')
void preferInlineDead() {}

@pragma('dart2js:noInline')
void noInlineDead() {}
'''),
          ]),
        ]),
      ]).create();

      final report = await analyzePackage(d.path('pragma_strict_pkg'));
      check(report.pureUndeadFound).equals(2);
      final deadNames = report.undead.map((z) => z.name).toSet();
      check(deadNames).contains('preferInlineDead');
      check(deadNames).contains('noInlineDead');
      check(deadNames).not((it) => it.contains('vmEntryPoint'));
      check(deadNames).not((it) => it.contains('IsolateUnsendableClass'));
    });

    test('dynamic conditional import reachability does not seed dead '
        'internal files (VULN-6)', () async {
      await d.dir('dyn_conditional_pkg', [
        packageConfig('dyn_conditional_pkg'),
        d.file('pubspec.yaml', '''
name: dyn_conditional_pkg
environment:
  sdk: '^3.5.0'
'''),
        d.dir('lib', [
          d.file('dyn_conditional_pkg.dart', 'export "src/live.dart";'),
          d.dir('src', [
            d.file('live.dart', '''
import 'live_stub.dart' if (dart.library.io) 'live_io.dart';

class LiveService {
  void doWork() {}
}
'''),
            d.file('live_stub.dart', 'class LiveStubClass {}'),
            d.file('live_io.dart', 'class LiveIoClass {}'),
            d.file('dead_feature.dart', '''
import 'dead_stub.dart' if (dart.library.io) 'dead_io.dart';

class DeadFeatureService {}
'''),
            d.file('dead_stub.dart', 'class DeadStubClass {}'),
            d.file('dead_io.dart', 'class DeadIoClass {}'),
          ]),
        ]),
      ]).create();

      final report = await analyzePackage(d.path('dyn_conditional_pkg'));
      // LiveService is live, and connects to live_io/live_stub.
      // dead_feature is dead, so dead_stub and dead_io should also be dead!
      final deadNames = report.undead.map((z) => z.name).toSet();
      check(deadNames).contains('DeadFeatureService');
      check(deadNames).contains('DeadStubClass');
      check(deadNames).contains('DeadIoClass');
      check(deadNames).not((it) => it.contains('LiveService'));
      check(deadNames).not((it) => it.contains('LiveStubClass'));
      check(deadNames).not((it) => it.contains('LiveIoClass'));
    });

    test('gRPC *Stub naming is not test support and is detected as '
        'tested undead (VULN-8)', () async {
      await d.dir('grpc_stub_pkg', [
        packageConfig('grpc_stub_pkg'),
        d.file('pubspec.yaml', '''
name: grpc_stub_pkg
environment:
  sdk: '^3.5.0'
'''),
        d.dir('lib', [
          d.file('grpc_stub_pkg.dart', 'export "src/live.dart";'),
          d.dir('src', [
            d.file('live.dart', 'class LiveApi {}'),
            d.file('grpc_client.dart', '''
import 'package:meta/meta.dart';

class PaymentServiceStub {
  void sendPayment() {}
}

class MockPaymentClient {
  void mockPayment() {}
}

@visibleForTesting
class TestingHook {
  void inspectState() {}
}
'''),
          ]),
        ]),
        d.dir('test', [
          d.file('client_test.dart', '''
import 'package:grpc_stub_pkg/src/grpc_client.dart';

void test(String desc, Function body) {}

void main() {
  test('tests grpc client and mock', () {
    final stub = PaymentServiceStub();
    stub.sendPayment();
    final mock = MockPaymentClient();
    mock.mockPayment();
    final hook = TestingHook();
    hook.inspectState();
  });
}
'''),
        ]),
      ]).create();

      final report = await analyzePackage(d.path('grpc_stub_pkg'));
      // MockPaymentClient and TestingHook are preserved test support.
      // PaymentServiceStub is NOT test support and is flagged as a undead!
      check(report.testedUndeadFound).equals(1);
      final undead = report.undead.single;
      check(undead.name).equals('PaymentServiceStub');
      check(undead.classification).equals(UndeadClassification.testedUndead);
      check(undead.orphanTests).isNotNull();
      check(undead.orphanTests!.first.file).equals('test/client_test.dart');
    });

    test('build.yaml with comments and blank lines preserves builder '
        'factories (VULN-10)', () async {
      await d.dir('yaml_build_pkg', [
        packageConfig('yaml_build_pkg'),
        d.file('pubspec.yaml', '''
name: yaml_build_pkg
environment:
  sdk: '^3.5.0'
'''),
        d.file('build.yaml', '''
targets:
  \$default:
    builders:
      yaml_build_pkg|builder:
        # Factories list:
        builder_factories:
          # Main builder
          - customBuilderFactory

          # Secondary
          - "quotedBuilderFactory"
'''),
        d.dir('lib', [
          d.file('yaml_build_pkg.dart', 'export "src/live.dart";'),
          d.dir('src', [
            d.file('live.dart', 'class LiveMain {}'),
            d.file('builder.dart', '''
void customBuilderFactory() {}
void quotedBuilderFactory() {}
void deadBuilderFactory() {}
'''),
          ]),
        ]),
      ]).create();

      final report = await analyzePackage(d.path('yaml_build_pkg'));
      check(report.pureUndeadFound).equals(1);
      check(report.undead.single.name).equals('deadBuilderFactory');
    });

    test('multi-variable variable-level suppression respects '
        '// undead:ignore per variable (VULN-11)', () async {
      await d.dir('multivar_ignore_pkg', [
        packageConfig('multivar_ignore_pkg'),
        d.file('pubspec.yaml', '''
name: multivar_ignore_pkg
environment:
  sdk: '^3.5.0'
'''),
        d.dir('lib', [
          d.file('multivar_ignore_pkg.dart', 'export "src/live.dart";'),
          d.dir('src', [
            d.file('live.dart', 'class LiveClass {}'),
            d.file('vars.dart', '''
late int varA,
    // undead:ignore
    varB,
    varC;
'''),
          ]),
        ]),
      ]).create();

      final report = await analyzePackage(d.path('multivar_ignore_pkg'));
      check(report.pureUndeadFound).equals(2);
      final deadNames = report.undead.map((z) => z.name).toSet();
      check(deadNames).contains('varA');
      check(deadNames).contains('varC');
      check(deadNames).not((it) => it.contains('varB'));
    });

    test('test harness fixtures (setUp/tearDown) are recorded as orphan '
        'test sites (VULN-12)', () async {
      await d.dir('fixture_orphan_pkg', [
        packageConfig('fixture_orphan_pkg'),
        d.file('pubspec.yaml', '''
name: fixture_orphan_pkg
environment:
  sdk: '^3.5.0'
'''),
        d.dir('lib', [
          d.file('fixture_orphan_pkg.dart', 'export "src/live.dart";'),
          d.dir('src', [
            d.file('live.dart', 'class LiveService {}'),
            d.file('dead_helper.dart', '''
class DeadFixtureHelper {
  static void setupEnv() {}
  static void teardownEnv() {}
}
'''),
          ]),
        ]),
        d.dir('test', [
          d.file('helper_test.dart', '''
import 'package:fixture_orphan_pkg/src/dead_helper.dart';

void setUp(Function callback) {}
void setUpAll(Function callback) {}
void tearDown(Function callback) {}
void tearDownAll(Function callback) {}
void test(String desc, Function body) {}

void main() {
  setUpAll(() {
    DeadFixtureHelper.setupEnv();
  });

  setUp(() {
    DeadFixtureHelper.setupEnv();
  });

  tearDown(() {
    DeadFixtureHelper.teardownEnv();
  });

  tearDownAll(() {
    DeadFixtureHelper.teardownEnv();
  });

  test('dummy test', () {});
}
'''),
        ]),
      ]).create();

      final report = await analyzePackage(d.path('fixture_orphan_pkg'));
      check(report.testedUndeadFound).equals(1);
      final undead = report.undead.single;
      check(undead.name).equals('DeadFixtureHelper');
      check(undead.classification).equals(UndeadClassification.testedUndead);
      check(undead.orphanTests).isNotNull();
      final descriptions = undead.orphanTests!
          .map((t) => t.description)
          .toSet();
      check(descriptions).contains('setUpAll');
      check(descriptions).contains('setUp');
      check(descriptions).contains('tearDown');
      check(descriptions).contains('tearDownAll');
    });

    test('internal sub-library export facade generates outbound reachability '
        'edges (VULN-13)', () async {
      await d.dir('facade_pkg', [
        packageConfig('facade_pkg'),
        d.file('pubspec.yaml', '''
name: facade_pkg
environment:
  sdk: '^3.5.0'
'''),
        d.dir('lib', [
          d.file('facade_pkg.dart', 'export "src/consumer.dart";'),
          d.dir('src', [
            d.file('consumer.dart', '''
import 'facade.dart';

class Consumer {
  void useFacade() {
    FacadeRoot();
  }
}
'''),
            d.file('facade.dart', '''
export 'sub_module.dart' show ExportedSubModule, HiddenSubModule hide HiddenSubModule;

class FacadeRoot {}
'''),
            d.file('sub_module.dart', '''
class ExportedSubModule {}
class HiddenSubModule {}
class DeadSubModuleItem {}
'''),
          ]),
        ]),
      ]).create();

      final report = await analyzePackage(d.path('facade_pkg'));
      check(report.pureUndeadFound).equals(2);
      final deadNames = report.undead.map((z) => z.name).toSet();
      check(deadNames).contains('DeadSubModuleItem');
      check(deadNames).contains('HiddenSubModule');
      check(deadNames).not((it) => it.contains('Consumer'));
      check(deadNames).not((it) => it.contains('FacadeRoot'));
      check(deadNames).not((it) => it.contains('ExportedSubModule'));
    });

    test('zero-declaration internal conditional export facade preserves '
        'platform counterparts (VULN-6 & VULN-13)', () async {
      await d.dir('zero_decl_facade_pkg', [
        packageConfig('zero_decl_facade_pkg'),
        d.file('pubspec.yaml', '''
name: zero_decl_facade_pkg
environment:
  sdk: '^3.5.0'
'''),
        d.dir('lib', [
          d.file('zero_decl_facade_pkg.dart', 'export "src/caller.dart";'),
          d.dir('src', [
            d.file('caller.dart', '''
import 'platform_facade.dart';

class CallerService {
  void run() {
    PlatformService().doWork();
  }
}
'''),
            // Pure facade with zero declarations:
            d.file('platform_facade.dart', '''
export 'platform_stub.dart'
  if (dart.library.io) 'platform_io.dart'
  if (dart.library.js_interop) 'platform_web.dart';
'''),
            d.file('platform_stub.dart', '''
class PlatformService {
  void doWork() {}
}
'''),
            d.file('platform_io.dart', '''
class PlatformService {
  void doWork() {}
}
'''),
            d.file('platform_web.dart', '''
class PlatformService {
  void doWork() {}
}
'''),
            d.file('dead_internal.dart', '''
class DeadInternalService {}
'''),
          ]),
        ]),
      ]).create();

      final report = await analyzePackage(d.path('zero_decl_facade_pkg'));
      check(report.pureUndeadFound).equals(1);
      check(report.undead.single.name).equals('DeadInternalService');
      final deadNames = report.undead.map((z) => z.name).toSet();
      check(deadNames).not((it) => it.contains('CallerService'));
      check(deadNames).not((it) => it.contains('PlatformService'));
    });

    test(
      'identifies isExternalBinding and filters with ignoreExternalBindings',
      () async {
        await d.dir('js_interop_pkg', [
          packageConfig('js_interop_pkg'),
          d.file('pubspec.yaml', '''
name: js_interop_pkg
environment:
  sdk: '^3.5.0'
'''),
          d.dir('lib', [
            d.file('js_interop_pkg.dart', 'export "src/live.dart";'),
            d.dir('src', [
              d.file('live.dart', 'class LiveService {}'),
              d.file('dom_bindings.dart', '''
import 'dart:js_interop';

@JS('HTMLCanvasElement')
extension type DomCanvas(JSObject _) {
  external int get width;
}

external void topLevelJsFunc();

class DeadDartHelper {
  void unused() {}
}
'''),
            ]),
          ]),
        ]).create();

        // 1. Default run: flags both JS interop and DeadDartHelper, but
        // marks isExternalBinding.
        final defaultReport = await analyzePackage(d.path('js_interop_pkg'));
        final canvasUndead = defaultReport.undead.firstWhere(
          (z) => z.name == 'DomCanvas',
        );
        check(canvasUndead.isExternalBinding).isTrue();

        final funcUndead = defaultReport.undead.firstWhere(
          (z) => z.name == 'topLevelJsFunc',
        );
        check(funcUndead.isExternalBinding).isTrue();

        final dartUndead = defaultReport.undead.firstWhere(
          (z) => z.name == 'DeadDartHelper',
        );
        check(dartUndead.isExternalBinding).isFalse();

        // 2. Run with ignoreExternalBindings: true.
        final options = UndeadOptions(
          packagePath: d.path('js_interop_pkg'),
          ignoreExternalBindings: true,
        );
        final filteredReport = await UndeadEngine(options).analyze();
        check(filteredReport.pureUndeadFound).equals(1);
        check(filteredReport.undead.single.name).equals('DeadDartHelper');
      },
    );

    test('automatically discovers sibling workspace consumer and protects '
        'internal helper', () async {
      await d.dir('ws_monorepo', [
        d.dir('.git', []),
        d.dir('packages', [
          d.dir('core_pkg', [
            d.dir('.dart_tool', [
              d.file('package_config.json', '''
{
  "configVersion": 2,
  "packages": [
    {
      "name": "core_pkg",
      "rootUri": "../",
      "packageUri": "lib/",
      "languageVersion": "3.5"
    }
  ]
}
'''),
            ]),
            d.file('pubspec.yaml', '''
name: core_pkg
environment:
  sdk: '^3.5.0'
'''),
            d.dir('lib', [
              d.file('core_pkg.dart', 'export "src/live.dart";'),
              d.dir('src', [
                d.file('live.dart', 'void liveCore() {}'),
                d.file('internal_helper.dart', 'void internalCoreHelper() {}'),
                d.file('unused.dart', 'void deadCoreFunc() {}'),
              ]),
            ]),
          ]),
          d.dir('consumer_pkg', [
            d.dir('.dart_tool', [
              d.file('package_config.json', '''
{
  "configVersion": 2,
  "packages": [
    {
      "name": "consumer_pkg",
      "rootUri": "../",
      "packageUri": "lib/",
      "languageVersion": "3.5"
    },
    {
      "name": "core_pkg",
      "rootUri": "../../core_pkg",
      "packageUri": "lib/",
      "languageVersion": "3.5"
    }
  ]
}
'''),
            ]),
            d.file('pubspec.yaml', '''
name: consumer_pkg
environment:
  sdk: '^3.5.0'
dependencies:
  core_pkg:
    path: ../core_pkg
'''),
            d.dir('lib', [
              d.file('consumer.dart', '''
import 'package:core_pkg/src/internal_helper.dart';

void useHelper() {
  internalCoreHelper();
}
'''),
            ]),
          ]),
        ]),
      ]).create();

      // 1. With workspace discovery (default: true) -> helper is protected!
      final reportWithWs = await analyzePackage(
        d.path('ws_monorepo/packages/core_pkg'),
      );
      check(reportWithWs.pureUndeadFound).equals(1);
      check(reportWithWs.undead.single.name).equals('deadCoreFunc');

      // 2. With workspace discovery disabled -> helper is pure undead!
      final reportNoWs = await UndeadEngine(
        UndeadOptions(
          packagePath: d.path('ws_monorepo/packages/core_pkg'),
          workspaceDiscovery: false,
        ),
      ).analyze();
      check(reportNoWs.pureUndeadFound).equals(2);
      final undeadNames = reportNoWs.undead.map((z) => z.name).toSet();
      check(undeadNames).contains('internalCoreHelper');
      check(undeadNames).contains('deadCoreFunc');
    });

    test(
      'supports unified --extra-roots with explicit .dart file and directory '
      'splitting lib/test',
      () async {
        await d.dir('extra_roots_unification_pkg', [
          packageConfig('extra_roots_unification_pkg'),
          d.file('pubspec.yaml', '''
name: extra_roots_unification_pkg
environment:
  sdk: '^3.5.0'
'''),
          d.dir('lib', [
            d.file(
              'extra_roots_unification_pkg.dart',
              'export "src/live.dart";',
            ),
            d.dir('src', [
              d.file('live.dart', 'void liveFunc() {}'),
              d.file('file_root_helper.dart', 'void fileRootTarget() {}'),
              d.file('dir_prod_helper.dart', 'void dirProdTarget() {}'),
              d.file('dir_test_helper.dart', 'void dirTestTarget() {}'),
              d.file('dead_all.dart', 'void deadAll() {}'),
            ]),
          ]),
        ]).create();

        await d.dir('external_file_root', [
          d.dir('.dart_tool', [
            d.file('package_config.json', '''
{
  "configVersion": 2,
  "packages": [
    {
      "name": "external_file_root",
      "rootUri": "../",
      "packageUri": "lib/",
      "languageVersion": "3.5"
    },
    {
      "name": "extra_roots_unification_pkg",
      "rootUri": "../../extra_roots_unification_pkg",
      "packageUri": "lib/",
      "languageVersion": "3.5"
    }
  ]
}
'''),
          ]),
          d.file('entrypoint.dart', '''
import 'package:extra_roots_unification_pkg/src/file_root_helper.dart';

void main() {
  fileRootTarget();
}
'''),
        ]).create();

        await d.dir('external_companion_pkg', [
          d.dir('.dart_tool', [
            d.file('package_config.json', '''
{
  "configVersion": 2,
  "packages": [
    {
      "name": "external_companion_pkg",
      "rootUri": "../",
      "packageUri": "lib/",
      "languageVersion": "3.5"
    },
    {
      "name": "extra_roots_unification_pkg",
      "rootUri": "../../extra_roots_unification_pkg",
      "packageUri": "lib/",
      "languageVersion": "3.5"
    }
  ]
}
'''),
          ]),
          d.dir('lib', [
            d.file('companion.dart', '''
import 'package:extra_roots_unification_pkg/src/dir_prod_helper.dart';

void companionProd() {
  dirProdTarget();
}
'''),
          ]),
          d.dir('test', [
            d.file('companion_test.dart', '''
import 'package:extra_roots_unification_pkg/src/dir_test_helper.dart';

void test(String desc, Function body) {}

void main() {
  test('companion test', () {
    dirTestTarget();
  });
}
'''),
          ]),
        ]).create();

        final options = UndeadOptions(
          packagePath: d.path('extra_roots_unification_pkg'),
          extraRoots: [
            d.path('external_file_root/entrypoint.dart'),
            d.path('external_companion_pkg'),
          ],
          workspaceDiscovery: false,
        );

        final report = await UndeadEngine(options).analyze();
        // deadAll is pureUndead
        check(report.pureUndeadFound).equals(1);
        check(report.undead.any((z) => z.name == 'deadAll')).isTrue();

        // dirTestTarget is testedUndead (reached via companion test/ split)
        check(report.testedUndeadFound).equals(1);
        final testedUndead = report.undead.firstWhere(
          (z) => z.name == 'dirTestTarget',
        );
        check(
          testedUndead.classification,
        ).equals(UndeadClassification.testedUndead);

        // fileRootTarget and dirProdTarget are LIVE production roots!
        final undeadNames = report.undead.map((z) => z.name).toSet();
        check(undeadNames).not((it) => it.contains('fileRootTarget'));
        check(undeadNames).not((it) => it.contains('dirProdTarget'));
      },
    );

    test(
      'preserves reachability when sibling consumer uses internal helper from '
      'lib/src/build/ subdirectory',
      () async {
        await d.dir('sibling_build_dir_repo', [
          d.dir('.git', []),
          d.dir('packages', [
            d.dir('core_pkg', [
              packageConfig('core_pkg'),
              d.file('pubspec.yaml', '''
name: core_pkg
environment:
  sdk: '^3.5.0'
'''),
              d.dir('lib', [
                d.file('core_pkg.dart', 'export "src/live.dart";'),
                d.dir('src', [
                  d.file('live.dart', 'void liveCore() {}'),
                  d.file('helper.dart', 'void buildGenHelper() {}'),
                  d.file('dead.dart', 'void deadFunc() {}'),
                ]),
              ]),
            ]),
            d.dir('generator_pkg', [
              d.dir('.dart_tool', [
                d.file('package_config.json', '''
{
  "configVersion": 2,
  "packages": [
    {
      "name": "generator_pkg",
      "rootUri": "../",
      "packageUri": "lib/",
      "languageVersion": "3.5"
    },
    {
      "name": "core_pkg",
      "rootUri": "../../core_pkg",
      "packageUri": "lib/",
      "languageVersion": "3.5"
    }
  ]
}
'''),
              ]),
              d.file('pubspec.yaml', '''
name: generator_pkg
environment:
  sdk: '^3.5.0'
dependencies:
  core_pkg:
    path: ../core_pkg
'''),
              d.dir('lib', [
                d.dir('src', [
                  d.dir('build', [
                    d.file('gen.dart', '''
import 'package:core_pkg/src/helper.dart';

void runGen() {
  buildGenHelper();
}
'''),
                  ]),
                ]),
              ]),
            ]),
          ]),
        ]).create();

        final report = await analyzePackage(
          d.path('sibling_build_dir_repo/packages/core_pkg'),
        );

        check(report.pureUndeadFound).equals(1);
        check(report.undead.single.name).equals('deadFunc');
        final undeadNames = report.undead.map((z) => z.name).toSet();
        check(undeadNames).not((it) => it.contains('buildGenHelper'));
      },
    );
  });
}
