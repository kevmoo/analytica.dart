import 'dart:io';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
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

/// Custom user-defined adapter for a hypothetical microservice/testing framework.
class CustomServerFrameworkAdapter extends BaseFrameworkAdapter {
  const CustomServerFrameworkAdapter();

  @override
  Set<String> harvestRoots({
    required PackageTopology topology,
    required Directory packageDir,
    required String pubspecContent,
  }) {
    // Custom logic: Harvests customServerEntrypoint as an entrypoint root
    return {'customServerEntrypoint'};
  }

  @override
  bool isTestCallSite(MethodInvocation node) {
    return node.methodName.name == 'customTestRunner';
  }

  @override
  bool isTestHarnessSite(MethodInvocation node) {
    return node.methodName.name == 'customBeforeEach';
  }

  @override
  bool isFrameworkEntryPoint(AnnotatedNode node, Element? element) {
    for (final meta in node.metadata) {
      if (meta.name.name == 'CustomServiceEntry') return true;
    }
    return false;
  }
}

void main() {
  group('Custom FrameworkAdapter Override', () {
    test('user-defined custom adapter correctly customizes root harvesting, '
        'entrypoint pragmas, and test call sites', () async {
      await d.dir('custom_adapter_pkg', [
        packageConfig('custom_adapter_pkg'),
        d.file('pubspec.yaml', '''
name: custom_adapter_pkg
environment:
  sdk: '^3.5.0'
'''),
        d.dir('lib', [
          d.file('custom_adapter_pkg.dart', 'export "src/live.dart";'),
          d.dir('src', [
            d.file('live.dart', '''
class LiveService {}
'''),
            d.file('server_handlers.dart', '''
// Harvested by custom adapter root discovery:
void customServerEntrypoint() {
  usedByCustomEntrypoint();
}

void usedByCustomEntrypoint() {}

// Recognized by custom adapter isFrameworkEntryPoint:
class CustomServiceEntry {
  const CustomServiceEntry();
}

@CustomServiceEntry()
void annotatedEntryPoint() {}

// Tested undead referenced only in customTestRunner:
void deadOnlyTested() {}

// Co-invoked hazard referenced in customTestRunner along with live code:
void deadCoInvoked() {}

// Pure undead:
void pureUndead() {}
'''),
          ]),
        ]),
        d.dir('test', [
          d.file('custom_test.dart', '''
import 'package:custom_adapter_pkg/src/live.dart';
import 'package:custom_adapter_pkg/src/server_handlers.dart';

void customTestRunner(String name, Function body) {}
void customBeforeEach(Function body) {}

void main() {
  customBeforeEach(() {});

  customTestRunner('isolated test', () {
    deadOnlyTested();
  });

  customTestRunner('mixed hazard test', () {
    deadCoInvoked();
    final live = LiveService();
    print(live);
  });
}
'''),
        ]),
      ]).create();

      final options = UndeadOptions(
        packagePath: d.path('custom_adapter_pkg'),
        frameworkAdapter: const CustomServerFrameworkAdapter(),
      );

      final report = await analyzePackage(
        d.path('custom_adapter_pkg'),
        options: options,
      );

      // Verify custom roots and entrypoints are preserved
      final undeadNames = report.undead.map((z) => z.name).toSet();
      check(undeadNames).not((it) => it.contains('customServerEntrypoint'));
      check(undeadNames).not((it) => it.contains('usedByCustomEntrypoint'));
      check(undeadNames).not((it) => it.contains('annotatedEntryPoint'));

      // Verify pure undead detected
      check(undeadNames).contains('pureUndead');

      // Verify tested undead classified via customTestRunner
      final tested = report.undead.firstWhere(
        (z) => z.name == 'deadOnlyTested',
      );
      check(tested.classification).equals(UndeadClassification.testedUndead);
      check(tested.orphanTests!.first.file).equals('test/custom_test.dart');
      check(tested.orphanTests!.first.description).equals('isolated test');
      check(tested.orphanTests!.first.coInvokedHazard).isFalse();

      // Verify co-invoked hazard classified via customTestRunner
      final hazard = report.undead.firstWhere((z) => z.name == 'deadCoInvoked');
      check(hazard.classification).equals(UndeadClassification.coInvokedHazard);
      check(hazard.orphanTests!.first.coInvokedHazard).isTrue();
    });

    test(
      'empty BaseFrameworkAdapter disables framework-specific defaults',
      () async {
        await d.dir('empty_adapter_pkg', [
          packageConfig('empty_adapter_pkg'),
          d.file('pubspec.yaml', '''
name: empty_adapter_pkg
flutter:
  plugin:
    platforms:
      android:
        pluginClass: AndroidPluginClass
'''),
          d.file('build.yaml', '''
targets:
  \$default:
    builders:
      empty_adapter_pkg|builder:
        builder_factories: ["builderFactory"]
'''),
          d.dir('lib', [
            d.file('empty_adapter_pkg.dart', 'void exported() {}'),
            d.dir('src', [
              d.file('plugin.dart', 'class AndroidPluginClass {}'),
              d.file('builder.dart', 'void builderFactory() {}'),
              d.file('tested.dart', 'void deadTested() {}'),
            ]),
          ]),
          d.dir('test', [
            d.file('my_test.dart', '''
import 'package:empty_adapter_pkg/src/tested.dart';

void test(String desc, Function body) {}

void main() {
  test('tested', () {
    deadTested();
  });
}
'''),
          ]),
        ]).create();

        // Run with empty BaseFrameworkAdapter
        final report = await analyzePackage(
          d.path('empty_adapter_pkg'),
          options: UndeadOptions(
            packagePath: d.path('empty_adapter_pkg'),
            frameworkAdapter: const _EmptyAdapter(),
          ),
        );

        final undeadNames = report.undead.map((z) => z.name).toSet();

        // Since Flutter and BuildRunner adapters are not active:
        // AndroidPluginClass and builderFactory are NOT harvested as roots,
        // so they are pure undeads!
        check(undeadNames).contains('AndroidPluginClass');
        check(undeadNames).contains('builderFactory');

        // Since PackageTestAdapter is not active:
        // test(...) is not recognized as a test call site, so deadTested has
        // no orphan test sites associated!
        final testedFinding = report.undead.firstWhere(
          (z) => z.name == 'deadTested',
        );
        check(
          testedFinding.classification,
        ).equals(UndeadClassification.testedUndead);
        check(testedFinding.orphanTests).isNull();
      },
    );

    test(
      'internal lib/src/ main() functions are not treated as Flutter entrypoint roots',
      () async {
        await d.dir('flutter_internal_main_pkg', [
          packageConfig('flutter_internal_main_pkg'),
          d.file('pubspec.yaml', '''
name: flutter_internal_main_pkg
environment:
  sdk: '^3.5.0'
'''),
          d.dir('lib', [
            d.file('main.dart', '''
import 'package:flutter_internal_main_pkg/src/used.dart';

void main() {
  usedByMain();
}
'''),
            d.dir('src', [
              d.file('used.dart', 'void usedByMain() {}'),
              d.file('internal_tool.dart', '''
// This internal main is in lib/src/ and must NOT be treated as a Flutter entrypoint root!
void main() {
  deadInternalHelper();
}

void deadInternalHelper() {}
'''),
            ]),
          ]),
        ]).create();

        final report = await analyzePackage(
          d.path('flutter_internal_main_pkg'),
          options: UndeadOptions(
            packagePath: d.path('flutter_internal_main_pkg'),
            mode: AnalysisMode.closedApp,
          ),
        );

        final undeadNames = report.undead.map((z) => z.name).toSet();

        // lib/main.dart main and used.dart usedByMain are live
        check(undeadNames).not((it) => it.contains('usedByMain'));

        // internal_tool.dart main and deadInternalHelper are pure undeads
        check(undeadNames).contains('deadInternalHelper');
        check(undeadNames).contains('main');
        final internalMainFinding = report.undead.firstWhere(
          (z) => z.name == 'main' && z.file.contains('internal_tool.dart'),
        );
        check(
          internalMainFinding.classification,
        ).equals(UndeadClassification.pureUndead);
      },
    );
  });
}

class _EmptyAdapter extends BaseFrameworkAdapter {
  const _EmptyAdapter();
}
