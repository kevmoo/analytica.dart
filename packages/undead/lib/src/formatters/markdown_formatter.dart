import '../models.dart';

/// Formats a [UndeadReport] into human-readable GitHub-flavored Markdown
/// tables.
class MarkdownFormatter {
  const MarkdownFormatter();

  String format(UndeadReport report) {
    final buffer = StringBuffer();
    buffer.writeln('# Undead Code Analysis: `${report.package}`');
    buffer.writeln();

    // Summary Section
    buffer.writeln('### Summary');
    buffer.writeln();
    buffer.writeln('| Metric | Count |');
    buffer.writeln('| :--- | :--- |');
    buffer.writeln(
      '| **Total Declarations Scanned** | ${report.totalDeclarations} |',
    );
    buffer.writeln('| **Pure Undead** | ${report.pureUndeadFound} |');
    buffer.writeln('| **Tested Undead** | ${report.testedUndeadFound} |');
    buffer.writeln(
      '| **Co-Invoked Hazards** | ${report.coInvokedHazardsFound} |',
    );
    if (report.privateCandidatesFound > 0) {
      buffer.writeln(
        '| **Private Candidates** | ${report.privateCandidatesFound} |',
      );
    }
    buffer.writeln();

    if (report.undead.isEmpty) {
      buffer.writeln('🎉 **No undead declarations detected across package.**');
      return buffer.toString();
    }

    final pureUndead = report.undead
        .where((z) => z.classification == UndeadClassification.pureUndead)
        .toList();
    final testedUndead = report.undead
        .where((z) => z.classification == UndeadClassification.testedUndead)
        .toList();
    final coInvokedHazards = report.undead
        .where((z) => z.classification == UndeadClassification.coInvokedHazard)
        .toList();
    final privateCandidates = report.undead
        .where((z) => z.classification == UndeadClassification.privateCandidate)
        .toList();

    if (pureUndead.isNotEmpty) {
      buffer.writeln('## Pure Undead (Safe to Delete)');
      buffer.writeln();
      buffer.writeln('| Symbol | Kind | Location | Suggested Action |');
      buffer.writeln('| :--- | :--- | :--- | :--- |');
      for (final z in pureUndead) {
        final loc = '${z.file}:${z.line}:${z.column}';
        buffer.writeln(
          '| `${z.name}` | ${z.kind.jsonValue} | `$loc` | Delete declaration |',
        );
      }
      buffer.writeln();
    }

    if (testedUndead.isNotEmpty) {
      buffer.writeln('## Tested Undead (Orphan Tests)');
      buffer.writeln();
      buffer.writeln(
        '| Symbol | Kind | Location | Orphan Test Sites | Suggested Action |',
      );
      buffer.writeln('| :--- | :--- | :--- | :--- | :--- |');
      for (final z in testedUndead) {
        final loc = '${z.file}:${z.line}:${z.column}';
        final testSites = (z.orphanTests ?? [])
            .map((t) {
              final desc = t.description != null ? ' ("${t.description}")' : '';
              return '`${t.file}:${t.line}`$desc';
            })
            .join('<br>');
        buffer.writeln(
          '| `${z.name}` | ${z.kind.jsonValue} | `$loc` | $testSites | '
          'Delete declaration + orphan test block |',
        );
      }
      buffer.writeln();
    }

    if (coInvokedHazards.isNotEmpty) {
      buffer.writeln(
        '## Co-Invoked Test Hazards (Manual Refactoring Required)',
      );
      buffer.writeln();
      buffer.writeln(
        '| Symbol | Kind | Location | Co-Invoked Test Sites | '
        'Suggested Action |',
      );
      buffer.writeln('| :--- | :--- | :--- | :--- | :--- |');
      for (final z in coInvokedHazards) {
        final loc = '${z.file}:${z.line}:${z.column}';
        final testSites = (z.orphanTests ?? [])
            .map((t) {
              final desc = t.description != null ? ' ("${t.description}")' : '';
              return '`${t.file}:${t.line}`$desc';
            })
            .join('<br>');
        buffer.writeln(
          '| `${z.name}` | ${z.kind.jsonValue} | `$loc` | $testSites | '
          'Manual refactoring required |',
        );
      }
      buffer.writeln();
    }

    if (privateCandidates.isNotEmpty) {
      buffer.writeln('## Private Candidates (Suggest Library-Private)');
      buffer.writeln();
      buffer.writeln('| Symbol | Kind | Location | Suggested Action |');
      buffer.writeln('| :--- | :--- | :--- | :--- |');
      for (final z in privateCandidates) {
        final loc = '${z.file}:${z.line}:${z.column}';
        buffer.writeln(
          '| `${z.name}` | ${z.kind.jsonValue} | `$loc` | '
          'Make library-private (prefix with `_`) |',
        );
      }
      buffer.writeln();
    }

    return buffer.toString();
  }
}
