import 'dart:convert';
import 'package:checks/checks.dart';
import 'package:test/test.dart';
import 'package:undead/undead.dart';

void main() {
  group('Formatters', () {
    const sampleReport = UndeadReport(
      version: '0.1.0',
      package: 'test_pkg',
      totalDeclarations: 10,
      pureUndeadFound: 1,
      testedUndeadFound: 1,
      coInvokedHazardsFound: 1,
      undead: [
        UndeadFinding(
          id: 'deadFunc',
          name: 'deadFunc',
          kind: DeclarationKind.function,
          file: 'lib/src/dead.dart',
          line: 12,
          column: 1,
          length: 20,
          classification: UndeadClassification.pureUndead,
          suggestedAction: SuggestedAction.delete,
        ),
        UndeadFinding(
          id: 'OldParser',
          name: 'OldParser',
          kind: DeclarationKind.classType,
          file: 'lib/src/old_parser.dart',
          line: 5,
          column: 7,
          length: 9,
          classification: UndeadClassification.testedUndead,
          suggestedAction: SuggestedAction.deleteWithOrphanTests,
          orphanTests: [
            OrphanTestSite(
              file: 'test/old_parser_test.dart',
              line: 8,
              column: 3,
              description: 'parses old format',
            ),
          ],
        ),
        UndeadFinding(
          id: 'LegacyHelper',
          name: 'LegacyHelper',
          kind: DeclarationKind.classType,
          file: 'lib/src/helper.dart',
          line: 20,
          column: 7,
          length: 12,
          classification: UndeadClassification.coInvokedHazard,
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
        UndeadFinding(
          id: 'internalHelper',
          name: 'internalHelper',
          kind: DeclarationKind.function,
          file: 'lib/src/internal.dart',
          line: 10,
          column: 1,
          length: 14,
          classification: UndeadClassification.privateCandidate,
          suggestedAction: SuggestedAction.makePrivate,
        ),
      ],
      privateCandidatesFound: 1,
    );

    test('JsonFormatter generates valid and compliant JSON', () {
      const formatter = JsonFormatter();
      final output = formatter.format(sampleReport);

      final decoded = jsonDecode(output) as Map<String, dynamic>;
      check(decoded['version']).equals('0.1.0');
      check(decoded['package']).equals('test_pkg');

      final summary = decoded['summary'] as Map<String, dynamic>;
      check(summary['pureUndead']).equals(1);
      check(summary['testedUndead']).equals(1);
      check(summary['coInvokedHazards']).equals(1);
      check(summary['privateCandidates']).equals(1);

      final undead = decoded['undead'] as List<dynamic>;
      check(undead.length).equals(4);
    });

    test('MarkdownFormatter generates headers and categorized tables', () {
      const formatter = MarkdownFormatter();
      final output = formatter.format(sampleReport);

      check(output).contains('# Undead Code Analysis: `test_pkg`');
      check(output).contains('| **Private Candidates** | 1 |');
      check(output).contains('## Pure Undead (Safe to Delete)');
      check(output).contains('`deadFunc`');
      check(output).contains('## Tested Undead (Orphan Tests)');
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
      check(output).contains('## Private Candidates (Suggest Library-Private)');
      check(output).contains('`internalHelper`');
      check(output).contains('Make library-private (prefix with `_`)');
    });

    test('MarkdownFormatter produces clean notice when 0 undead found', () {
      const cleanReport = UndeadReport(
        version: '0.1.0',
        package: 'clean_pkg',
        totalDeclarations: 5,
        pureUndeadFound: 0,
        testedUndeadFound: 0,
        coInvokedHazardsFound: 0,
        undead: [],
      );

      const formatter = MarkdownFormatter();
      final output = formatter.format(cleanReport);

      check(output).contains('# Undead Code Analysis: `clean_pkg`');
      check(
        output,
      ).contains('🎉 **No undead declarations detected across package.**');
      check(output).not(.it()..contains('## Pure Undead'));
      check(output).not(.it()..contains('--entrypoint'));
    });

    test(
      'formatters emit possibleEntrypoints FYI when unrooted main() exists',
      () {
        const report = UndeadReport(
          version: '0.1.3-wip',
          package: 'flutter_app',
          totalDeclarations: 4,
          pureUndeadFound: 2,
          testedUndeadFound: 0,
          coInvokedHazardsFound: 0,
          undead: [
            UndeadFinding(
              id: 'main',
              name: 'main',
              kind: DeclarationKind.function,
              file: 'lib/benchmark_main.dart',
              line: 5,
              column: 1,
              length: 4,
              classification: UndeadClassification.pureUndead,
              suggestedAction: SuggestedAction.delete,
            ),
            UndeadFinding(
              id: 'main',
              name: 'main',
              kind: DeclarationKind.function,
              file: 'lib/staging.dart',
              line: 3,
              column: 1,
              length: 4,
              classification: UndeadClassification.pureUndead,
              suggestedAction: SuggestedAction.delete,
            ),
          ],
        );

        final jsonOutput = const JsonFormatter().format(report);
        final decoded = jsonDecode(jsonOutput) as Map<String, dynamic>;
        check(decoded['possibleEntrypoints']).isA<List<Object?>>().deepEquals([
          'lib/benchmark_main.dart',
          'lib/staging.dart',
        ]);

        final mdOutput = const MarkdownFormatter().format(report);
        check(mdOutput).contains('> [!NOTE]');
        check(
          mdOutput,
        ).contains('`lib/benchmark_main.dart`, `lib/staging.dart`');
        check(mdOutput).contains(
          '`--entrypoint lib/benchmark_main.dart --entrypoint lib/staging.dart`',
        );
      },
    );
  });
}
