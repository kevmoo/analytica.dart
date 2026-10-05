/// Immutable data models for single-caller shallow function analysis.
library;

/// Classification of a single-caller shallow helper based on simulated caller
/// Cognitive Complexity after inlining.
enum ShallowClassification {
  /// Inlining keeps the caller's Cognitive Complexity at or below the maximum
  /// caller complexity ceiling (`<= maxCallerScore`, default `15`).
  safeInline('SAFE_INLINE'),

  /// Inlining pushes the caller's Cognitive Complexity modestly above the
  /// ceiling (`maxCallerScore + 1 .. maxCallerScore + 7`); flattening a guard
  /// clause or branch allows clean inlining.
  flattenAndInline('FLATTEN_AND_INLINE'),

  /// Inlining pushes the caller's Cognitive Complexity significantly above the
  /// ceiling (`> maxCallerScore + 7`); the helper is load-bearing for
  /// complexity, so prefer grouping parameters into a value object or record.
  loadBearing('LOAD_BEARING');

  final String label;
  const ShallowClassification(this.label);
}

/// Represents a single-caller helper function or method flagged as a shallow
/// extraction candidate.
class ShallowFinding {
  final String filePath;
  final String name;
  final int startLine;
  final int endLine;
  final int parameterCount;
  final int namedParameterCount;
  final int signatureLines;
  final int bodyLines;
  final int score;
  final String callerFilePath;
  final String callerName;
  final int callLine;
  final int callNestingDepth;

  /// The caller's static Cognitive Complexity as written, independent of any
  /// sibling helpers simulated before this one.
  final int callerBaseScore;

  /// The caller's simulated Cognitive Complexity immediately before this
  /// helper is inlined: [callerBaseScore] plus the deltas of every earlier
  /// [ShallowClassification.safeInline] sibling absorbed into the same caller.
  final int callerCumulativeBefore;

  /// Alias of [callerCumulativeBefore], retained for the `caller_score` JSON
  /// key.
  final int callerScore;
  final int inlinedDeltaScore;
  final int inlinedCallerScore;
  final int estimatedLinesSaved;
  final ShallowClassification classification;
  final List<String> reasons;

  const ShallowFinding({
    required this.filePath,
    required this.name,
    required this.startLine,
    required this.endLine,
    required this.parameterCount,
    required this.namedParameterCount,
    required this.signatureLines,
    required this.bodyLines,
    required this.score,
    required this.callerFilePath,
    required this.callerName,
    required this.callLine,
    required this.callNestingDepth,
    required this.callerBaseScore,
    required this.callerCumulativeBefore,
    required this.callerScore,
    required this.inlinedDeltaScore,
    required this.inlinedCallerScore,
    required this.estimatedLinesSaved,
    required this.classification,
    required this.reasons,
  });

  /// Total physical line span of this declaration (`endLine - startLine + 1`).
  int get lineCount => endLine >= startLine ? endLine - startLine + 1 : 0;

  Map<String, dynamic> toJson() => {
    'file': filePath,
    'name': name,
    'start_line': startLine,
    'end_line': endLine,
    'lines': lineCount,
    'parameter_count': parameterCount,
    'named_parameter_count': namedParameterCount,
    'signature_lines': signatureLines,
    'body_lines': bodyLines,
    'score': score,
    'caller_file': callerFilePath,
    'caller_name': callerName,
    'call_line': callLine,
    'call_nesting_depth': callNestingDepth,
    'caller_base_score': callerBaseScore,
    'caller_cumulative_before': callerCumulativeBefore,
    'caller_score': callerScore,
    'inlined_delta_score': inlinedDeltaScore,
    'inlined_caller_score': inlinedCallerScore,
    'estimated_lines_saved': estimatedLinesSaved,
    'classification': classification.label,
    'reasons': reasons,
  };
}

/// Summary report produced by `ShallowAnalyzer`.
class ShallowReport {
  final List<ShallowFinding> findings;
  final int declarationsScanned;
  final int maxCallerScore;
  final int maxParams;

  const ShallowReport({
    required this.findings,
    required this.declarationsScanned,
    required this.maxCallerScore,
    required this.maxParams,
  });

  /// Number of findings classified as [ShallowClassification.safeInline].
  int get safeInlineCount => findings
      .where((f) => f.classification == ShallowClassification.safeInline)
      .length;

  /// Estimated lines of signature and call-site boilerplate saved by inlining
  /// all [ShallowClassification.safeInline] findings.
  int get estimatedSafeLinesSaved => findings
      .where((f) => f.classification == ShallowClassification.safeInline)
      .fold(0, (sum, f) => sum + f.estimatedLinesSaved);

  Map<String, dynamic> toJson({bool onlySafe = false}) {
    final displayed = onlySafe
        ? findings
              .where(
                (f) => f.classification == ShallowClassification.safeInline,
              )
              .toList()
        : findings;
    return {
      'declarations_scanned': declarationsScanned,
      'max_caller_cc': maxCallerScore,
      'max_params': maxParams,
      'total_findings': findings.length,
      'safe_inline_count': safeInlineCount,
      'estimated_safe_lines_saved': estimatedSafeLinesSaved,
      'findings': [for (final f in displayed) f.toJson()],
    };
  }

  /// Renders a human-readable text summary of the report.
  String formatText({bool onlySafe = false}) {
    final displayed = onlySafe
        ? findings
              .where(
                (f) => f.classification == ShallowClassification.safeInline,
              )
              .toList()
        : findings;
    if (displayed.isEmpty) {
      return onlySafe
          ? 'No SAFE_INLINE single-caller shallow helpers found '
                '($declarationsScanned declarations scanned).\n'
          : 'No single-caller shallow helpers found '
                '($declarationsScanned declarations scanned).\n';
    }

    final buf = StringBuffer()
      ..writeln(
        'Found ${findings.length} single-caller shallow helper(s) across '
        '$declarationsScanned declarations '
        '($safeInlineCount SAFE_INLINE keeping Caller CC <= $maxCallerScore, '
        'saving ~$estimatedSafeLinesSaved lines of boilerplate):',
      )
      ..writeln();

    for (final f in displayed) {
      final loc = '${f.filePath}:L${f.startLine}-${f.endLine}';
      buf
        ..writeln(
          '[${f.classification.label}] $loc '
          '${f.name} (params=${f.parameterCount}, LOC=${f.lineCount}, '
          'CC=${f.score})',
        )
        ..writeln(
          '  Called once by ${f.callerName} '
          '(${f.callerFilePath}:L${f.callLine}, depth=${f.callNestingDepth})',
        );

      final base = f.callerCumulativeBefore != f.callerBaseScore
          ? ' (base ${f.callerBaseScore})'
          : '';
      buf.writeln(
        '  Caller CC: ${f.callerCumulativeBefore}$base -> '
        '${f.inlinedCallerScore} after inline (+${f.inlinedDeltaScore}) | '
        'Est. Saved: ~${f.estimatedLinesSaved}L | '
        'Why: ${f.reasons.join(", ")}',
      );
    }
    return buf.toString();
  }
}
