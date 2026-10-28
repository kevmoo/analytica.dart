import '../models.dart';

/// Formats a [UndeadReport] into human-readable GitHub-flavored Markdown
/// tables.
class MarkdownFormatter {
  const MarkdownFormatter();

  String format(UndeadReport report) {
    final buffer = StringBuffer()
      ..writeln('# Undead Code Analysis: `${report.package}`\n');

    _writeSummary(buffer, report);

    if (report.undead.isEmpty) {
      buffer.writeln('🎉 **No undead declarations detected across package.**');
      return buffer.toString();
    }

    _writePureUndead(
      buffer,
      report.undead
          .where((z) => z.classification == UndeadClassification.pureUndead)
          .toList(),
    );
    _writeTestedUndead(
      buffer,
      report.undead
          .where((z) => z.classification == UndeadClassification.testedUndead)
          .toList(),
    );
    _writeCoInvokedHazards(
      buffer,
      report.undead
          .where(
            (z) => z.classification == UndeadClassification.coInvokedHazard,
          )
          .toList(),
    );
    _writePrivateCandidates(
      buffer,
      report.undead
          .where(
            (z) => z.classification == UndeadClassification.privateCandidate,
          )
          .toList(),
    );

    return buffer.toString();
  }

  static void _writeSummary(StringBuffer buffer, UndeadReport report) {
    buffer
      ..writeln('### Summary\n')
      ..writeln('| Metric | Count |')
      ..writeln('| :--- | :--- |')
      ..writeln(
        '| **Total Declarations Scanned** | ${report.totalDeclarations} |',
      )
      ..writeln('| **Pure Undead** | ${report.pureUndeadFound} |')
      ..writeln('| **Tested Undead** | ${report.testedUndeadFound} |')
      ..writeln('| **Co-Invoked Hazards** | ${report.coInvokedHazardsFound} |');
    if (report.privateCandidatesFound > 0) {
      buffer.writeln(
        '| **Private Candidates** | ${report.privateCandidatesFound} |',
      );
    }
    buffer.writeln();
  }

  static void _writePureUndead(
    StringBuffer buffer,
    List<UndeadFinding> findings,
  ) {
    if (findings.isEmpty) return;
    buffer
      ..writeln('## Pure Undead (Safe to Delete)\n')
      ..writeln('| Symbol | Kind | Location | Suggested Action |')
      ..writeln('| :--- | :--- | :--- | :--- |');
    for (final z in findings) {
      final loc = '${z.file}:${z.line}:${z.column}';
      buffer.writeln(
        '| `${z.name}` | ${z.kind.jsonValue} | `$loc` | Delete declaration |',
      );
    }
    buffer.writeln();
  }

  static void _writeTestedUndead(
    StringBuffer buffer,
    List<UndeadFinding> findings,
  ) {
    if (findings.isEmpty) return;
    buffer
      ..writeln('## Tested Undead (Orphan Tests)\n')
      ..writeln(
        '| Symbol | Kind | Location | Orphan Test Sites | Suggested Action |',
      )
      ..writeln('| :--- | :--- | :--- | :--- | :--- |');
    for (final z in findings) {
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

  static void _writeCoInvokedHazards(
    StringBuffer buffer,
    List<UndeadFinding> findings,
  ) {
    if (findings.isEmpty) return;
    buffer
      ..writeln('## Co-Invoked Test Hazards (Manual Refactoring Required)\n')
      ..writeln(
        '| Symbol | Kind | Location | Co-Invoked Test Sites | '
        'Suggested Action |',
      )
      ..writeln('| :--- | :--- | :--- | :--- | :--- |');
    for (final z in findings) {
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

  static void _writePrivateCandidates(
    StringBuffer buffer,
    List<UndeadFinding> findings,
  ) {
    if (findings.isEmpty) return;
    buffer
      ..writeln('## Private Candidates (Suggest Library-Private)\n')
      ..writeln('| Symbol | Kind | Location | Suggested Action |')
      ..writeln('| :--- | :--- | :--- | :--- |');
    for (final z in findings) {
      final loc = '${z.file}:${z.line}:${z.column}';
      buffer.writeln(
        '| `${z.name}` | ${z.kind.jsonValue} | `$loc` | '
        'Make library-private (prefix with `_`) |',
      );
    }
    buffer.writeln();
  }
}
