import 'package:checks/checks.dart';
import 'package:test/test.dart';
import 'package:undead/undead.dart';

void main() {
  group('Models Serialization & Deserialization', () {
    test('OrphanTestSite serialization round-trip', () {
      const site = OrphanTestSite(
        file: 'test/old_parser_test.dart',
        line: 12,
        column: 5,
        description: 'OldParser parses correctly',
        coInvokedHazard: false,
      );

      final json = site.toJson();
      check(json['file']).equals('test/old_parser_test.dart');
      check(json['line']).equals(12);
      check(json['column']).equals(5);
      check(json['description']).equals('OldParser parses correctly');
      check(json['coInvokedHazard']).equals(false);

      final deserialized = OrphanTestSite.fromJson(json);
      check(deserialized.file).equals(site.file);
      check(deserialized.line).equals(site.line);
      check(deserialized.column).equals(site.column);
      check(deserialized.description).equals(site.description);
      check(deserialized.coInvokedHazard).isFalse();
    });

    test('UndeadFinding serialization round-trip', () {
      const finding = UndeadFinding(
        id: 'calculateLegacyHash',
        name: 'calculateLegacyHash',
        kind: DeclarationKind.function,
        file: 'lib/src/utils.dart',
        line: 45,
        column: 1,
        length: 19,
        classification: UndeadClassification.pureUndead,
        suggestedAction: SuggestedAction.delete,
      );

      final json = finding.toJson();
      check(json['id']).equals('calculateLegacyHash');
      check(json['name']).equals('calculateLegacyHash');
      check(json['kind']).equals('function');
      check(json['file']).equals('lib/src/utils.dart');
      check(json['line']).equals(45);
      check(json['column']).equals(1);
      check(json['length']).equals(19);
      check(json['classification']).equals('pureUndead');
      check(json['suggestedAction']).equals('delete');
      check(json.containsKey('orphanTests')).isFalse();

      final deserialized = UndeadFinding.fromJson(json);
      check(deserialized.id).equals(finding.id);
      check(deserialized.name).equals(finding.name);
      check(deserialized.kind).equals(DeclarationKind.function);
      check(
        deserialized.classification,
      ).equals(UndeadClassification.pureUndead);
      check(deserialized.suggestedAction).equals(SuggestedAction.delete);
    });

    test('UndeadReport serialization matches PRD JSON schema', () {
      const report = UndeadReport(
        version: '0.1.0',
        package: 'my_package',
        totalDeclarations: 142,
        pureUndeadFound: 1,
        testedUndeadFound: 1,
        coInvokedHazardsFound: 0,
        undead: [
          UndeadFinding(
            id: 'calculateLegacyHash',
            name: 'calculateLegacyHash',
            kind: DeclarationKind.function,
            file: 'lib/src/utils.dart',
            line: 45,
            column: 1,
            length: 19,
            classification: UndeadClassification.pureUndead,
            suggestedAction: SuggestedAction.delete,
          ),
          UndeadFinding(
            id: 'OldParser',
            name: 'OldParser',
            kind: DeclarationKind.classType,
            file: 'lib/src/old_parser.dart',
            line: 10,
            column: 7,
            length: 9,
            classification: UndeadClassification.testedUndead,
            suggestedAction: SuggestedAction.deleteWithOrphanTests,
            orphanTests: [
              OrphanTestSite(
                file: 'test/old_parser_test.dart',
                line: 3,
                column: 3,
                description: 'OldParser parses correctly',
                coInvokedHazard: false,
              ),
            ],
          ),
        ],
      );

      final json = report.toJson();
      check(json['version']).equals('0.1.0');
      check(json['package']).equals('my_package');

      final summary = json['summary'] as Map<String, dynamic>;
      check(summary['totalDeclarations']).equals(142);
      check(summary['pureUndead']).equals(1);
      check(summary['testedUndead']).equals(1);
      check(summary['coInvokedHazards']).equals(0);

      final undeadList = json['undead'] as List<dynamic>;
      check(undeadList.length).equals(2);

      final deserialized = UndeadReport.fromJson(json);
      check(deserialized.package).equals('my_package');
      check(deserialized.totalDeclarations).equals(142);
      check(deserialized.undead.length).equals(2);
      check(deserialized.undead[1].orphanTests?.length).equals(1);
    });

    test('Enum fromJson and fromString conversions', () {
      check(
        UndeadClassification.fromJson('pureUndead'),
      ).equals(UndeadClassification.pureUndead);
      check(
        UndeadClassification.fromJson('testedUndead'),
      ).equals(UndeadClassification.testedUndead);
      check(
        UndeadClassification.fromJson('coInvokedHazard'),
      ).equals(UndeadClassification.coInvokedHazard);

      check(
        DeclarationKind.fromJson('class'),
      ).equals(DeclarationKind.classType);
      check(DeclarationKind.fromJson('getter')).equals(DeclarationKind.getter);
      check(DeclarationKind.fromJson('setter')).equals(DeclarationKind.setter);

      check(
        ExampleMode.fromString('demonstration'),
      ).equals(ExampleMode.demonstration);
      check(ExampleMode.fromString('strict')).equals(ExampleMode.strict);
      check(ExampleMode.fromString('skip')).equals(ExampleMode.skip);

      check(AnalysisMode.fromString('library')).equals(AnalysisMode.library);
      check(
        AnalysisMode.fromString('closed-app'),
      ).equals(AnalysisMode.closedApp);

      check(OutputFormat.fromString('markdown')).equals(OutputFormat.markdown);
      check(OutputFormat.fromString('json')).equals(OutputFormat.json);
    });

    test('UndeadOptions default and custom values', () {
      const defaultOptions = UndeadOptions(packagePath: '/path/to/pkg');
      check(defaultOptions.testSupportPatterns).deepEquals(['Fake*', 'Mock*']);
      check(defaultOptions.ignoreNamePatterns).isEmpty();
      check(defaultOptions.format).equals(OutputFormat.markdown);
      check(defaultOptions.exampleMode).equals(ExampleMode.demonstration);
      check(defaultOptions.mode).equals(AnalysisMode.library);
      check(defaultOptions.includeGenerated).isFalse();
      check(defaultOptions.failOnUndead).isFalse();
      check(defaultOptions.autoPubGet).isFalse();
      check(defaultOptions.workspaceDiscovery).isTrue();

      const customOptions = UndeadOptions(
        packagePath: '/path/to/pkg',
        testSupportPatterns: ['*Stub', 'CustomFixture*'],
        ignoreNamePatterns: ['*_generated', 'Ignored*'],
        extraRoots: ['../companion_test', '/external/tests'],
        workspaceDiscovery: false,
      );
      check(
        customOptions.testSupportPatterns,
      ).deepEquals(['*Stub', 'CustomFixture*']);
      check(
        customOptions.ignoreNamePatterns,
      ).deepEquals(['*_generated', 'Ignored*']);
      check(
        customOptions.extraRoots,
      ).deepEquals(['../companion_test', '/external/tests']);
      check(customOptions.workspaceDiscovery).isFalse();
    });

    test('UndeadReport deserializes camelCase JSON summary correctly', () {
      final json = {
        'version': '0.1.0-dev',
        'package': 'test_pkg',
        'summary': {
          'totalDeclarations': 200,
          'pureUndead': 5,
          'testedUndead': 3,
          'coInvokedHazards': 2,
        },
        'undead': [
          {
            'id': 'unusedFunc',
            'name': 'unusedFunc',
            'kind': 'function',
            'file': 'lib/src/a.dart',
            'line': 10,
            'column': 1,
            'length': 10,
            'classification': 'pureUndead',
            'suggestedAction': 'delete',
          },
        ],
      };

      final report = UndeadReport.fromJson(json);
      check(report.totalDeclarations).equals(200);
      check(report.pureUndeadFound).equals(5);
      check(report.testedUndeadFound).equals(3);
      check(report.coInvokedHazardsFound).equals(2);
      check(report.undead.length).equals(1);
      check(report.undead.first.suggestedAction).equals('delete');
    });
  });
}
