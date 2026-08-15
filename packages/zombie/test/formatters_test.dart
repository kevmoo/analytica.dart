import 'dart:convert';
import 'package:checks/checks.dart';
import 'package:test/test.dart';
import 'package:zombie/zombie.dart';

void main() {
  group('Formatters', () {
    const sampleReport = ZombieReport(
      version: '0.1.0',
      package: 'test_pkg',
      totalDeclarations: 10,
      pureZombiesFound: 1,
      testedZombiesFound: 1,
      coInvokedHazardsFound: 1,
      zombies: [
        ZombieFinding(
          id: 'deadFunc',
          name: 'deadFunc',
          kind: DeclarationKind.function,
          file: 'lib/src/dead.dart',
          line: 12,
          column: 1,
          length: 20,
          classification: ZombieClassification.pureZombie,
          suggestedAction: SuggestedAction.delete,
        ),
        ZombieFinding(
          id: 'OldParser',
          name: 'OldParser',
          kind: DeclarationKind.classType,
          file: 'lib/src/old_parser.dart',
          line: 5,
          column: 7,
          length: 9,
          classification: ZombieClassification.testedZombie,
          suggestedAction: SuggestedAction.deleteWithOrphanTests,
          orphanTests: [
            OrphanTestSite(
              file: 'test/old_parser_test.dart',
              line: 8,
              column: 3,
              description: 'parses old format',
              coInvokedHazard: false,
            ),
          ],
        ),
        ZombieFinding(
          id: 'LegacyHelper',
          name: 'LegacyHelper',
          kind: DeclarationKind.classType,
          file: 'lib/src/helper.dart',
          line: 20,
          column: 7,
          length: 12,
          classification: ZombieClassification.coInvokedHazard,
          suggestedAction: SuggestedAction.manualRefactorHazard,
          orphanTests: [
            OrphanTestSite(
              file: 'test/pipeline_test.dart',
              line: 15,
              column: 3,
              description: 'pipeline integration',
              coInvokedHazard: true,
            ),
          ],
        ),
      ],
    );

    test('JsonFormatter generates valid and compliant JSON', () {
      const formatter = JsonFormatter();
      final output = formatter.format(sampleReport);

      final decoded = jsonDecode(output) as Map<String, dynamic>;
      check(decoded['version']).equals('0.1.0');
      check(decoded['package']).equals('test_pkg');

      final summary = decoded['summary'] as Map<String, dynamic>;
      check(summary['pureZombies']).equals(1);
      check(summary['testedZombies']).equals(1);
      check(summary['coInvokedHazards']).equals(1);

      final zombies = decoded['zombies'] as List<dynamic>;
      check(zombies.length).equals(3);
    });

    test('MarkdownFormatter generates headers and categorized tables', () {
      const formatter = MarkdownFormatter();
      final output = formatter.format(sampleReport);

      check(output).contains('# Zombie Code Analysis: `test_pkg`');
      check(output).contains('## Pure Zombies (Safe to Delete)');
      check(output).contains('`deadFunc`');
      check(output).contains('## Tested Zombies (Orphan Tests)');
      check(output).contains('`OldParser`');
      check(
        output,
      ).contains('`test/old_parser_test.dart:8` ("parses old format")');
      check(
        output,
      ).contains('## Co-Invoked Test Hazards (Manual Refactoring Required)');
      check(output).contains('`LegacyHelper`');
      check(
        output,
      ).contains('`test/pipeline_test.dart:15` ("pipeline integration")');
    });

    test('MarkdownFormatter produces clean notice when 0 zombies found', () {
      const cleanReport = ZombieReport(
        version: '0.1.0',
        package: 'clean_pkg',
        totalDeclarations: 5,
        pureZombiesFound: 0,
        testedZombiesFound: 0,
        coInvokedHazardsFound: 0,
        zombies: [],
      );

      const formatter = MarkdownFormatter();
      final output = formatter.format(cleanReport);

      check(output).contains('# Zombie Code Analysis: `clean_pkg`');
      check(
        output,
      ).contains('🎉 **No zombie declarations detected across package.**');
      check(output).not((it) => it.contains('## Pure Zombies'));
    });
  });
}
