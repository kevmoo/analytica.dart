import 'dart:io';

import 'complexity_analyzer.dart';
import 'delta_analyzer.dart';

/// Formats and emits diagnostic reports specifically for GitHub Actions CI/CD.
class GitHubReporter {
  final StringSink _stdoutSink;
  final File? _summaryFile;
  final File? _commentFile;
  final int _maxCommentRows;
  final bool _commentOnClean;

  GitHubReporter({
    StringSink? stdoutSink,
    this._summaryFile,
    this._commentFile,
    this._maxCommentRows = 0,
    this._commentOnClean = false,
  }) : _stdoutSink = stdoutSink ?? stdout;

  /// Generates diagnostic workflow annotations and updates step summary table.
  ///
  /// The step summary always receives the complete table. When [_commentFile]
  /// is configured, a second rendering is written there with the most
  /// significant rows first, capped at [_maxCommentRows]. GitHub rejects
  /// issue-comment bodies over 65536 characters, so posting an uncapped table
  /// on a large diff silently fails.
  void printReport({
    List<FunctionComplexity>? regularResults,
    List<FileLineMetric>? fileMetrics,
    DeltaSummary? deltaSummary,
    int? failThreshold,
    int? maxFileLines,
    int? maxFunctionLines,
    bool failOnIncrease = false,
  }) {
    final summaryBuf = _newBuffer();
    var commentBuf = _commentFile == null ? null : _newBuffer();

    if (deltaSummary != null) {
      // A clean diff gets no comment unless commentOnClean is enabled: the
      // action reads the absence of the comment file as "nothing to report".
      // The step summary below is written either way.
      if (!_commentOnClean &&
          deltaSummary.isClean(
            failThreshold: failThreshold,
            maxFileLines: maxFileLines,
            maxFunctionLines: maxFunctionLines,
            failOnIncrease: failOnIncrease,
          )) {
        commentBuf = null;
      }
      _reportDelta(
        deltaSummary,
        failThreshold,
        maxFileLines,
        maxFunctionLines,
        failOnIncrease,
        summaryBuf,
        commentBuf,
      );
    } else if (regularResults != null) {
      commentBuf = _reportRegular(
        regularResults,
        fileMetrics,
        failThreshold,
        maxFileLines,
        maxFunctionLines,
        summaryBuf,
        commentBuf,
      );
    }

    _write(_summaryFile, summaryBuf, 'step summary', append: true);
    if (commentBuf != null) {
      _write(_commentFile, commentBuf, 'comment output', append: false);
    }
  }

  StringBuffer _newBuffer() => StringBuffer()
    ..writeln('<!-- complexity-comment-marker -->')
    ..writeln('# 📊 Cognitive Complexity Analysis')
    ..writeln();

  void _write(
    File? file,
    StringBuffer buf,
    String label, {
    required bool append,
  }) {
    if (file == null) return;
    try {
      file.writeAsStringSync(
        buf.toString(),
        mode: append ? FileMode.append : FileMode.write,
      );
    } catch (e) {
      stderr.writeln('Warning: Failed to write to $label file: $e');
    }
  }

  StringBuffer? _reportRegular(
    List<FunctionComplexity> regularResults,
    List<FileLineMetric>? fileMetrics,
    int? failThreshold,
    int? maxFileLines,
    int? maxFunctionLines,
    StringBuffer summaryBuf,
    StringBuffer? commentBuf,
  ) {
    final violatedFiles =
        (maxFileLines != null && maxFileLines > 0 && fileMetrics != null)
        ? fileMetrics
              .where((f) => f.isViolation(maxFileLines: maxFileLines))
              .toList()
        : const <FileLineMetric>[];
    final hasViolations =
        violatedFiles.isNotEmpty ||
        regularResults.any(
          (r) => r.isViolation(
            failThreshold: failThreshold,
            maxFunctionLines: maxFunctionLines,
          ),
        );

    final activeCommentBuf =
        (commentBuf != null && (_commentOnClean || hasViolations))
        ? commentBuf
        : null;

    if (regularResults.isEmpty && violatedFiles.isEmpty) {
      for (final buf in [summaryBuf, ?activeCommentBuf]) {
        buf.writeln('No Dart declarations analyzed.');
      }
      return activeCommentBuf;
    }

    if (regularResults.isNotEmpty) {
      _renderRegularDeclarationsTable(
        regularResults,
        failThreshold,
        maxFunctionLines,
        summaryBuf,
        emitAnnotations: true,
      );
    }
    if (violatedFiles.isNotEmpty) {
      _renderRegularFileViolations(
        violatedFiles,
        maxFileLines!,
        summaryBuf,
        emitAnnotations: true,
      );
    }

    if (activeCommentBuf != null) {
      _renderRegularComment(
        regularResults,
        violatedFiles,
        failThreshold,
        maxFileLines,
        maxFunctionLines,
        activeCommentBuf,
      );
    }
    return activeCommentBuf;
  }

  void _renderRegularComment(
    List<FunctionComplexity> regularResults,
    List<FileLineMetric> violatedFiles,
    int? failThreshold,
    int? maxFileLines,
    int? maxFunctionLines,
    StringBuffer commentBuf,
  ) {
    if (regularResults.isNotEmpty) {
      bool isVio(FunctionComplexity r) => r.isViolation(
        failThreshold: failThreshold,
        maxFunctionLines: maxFunctionLines,
      );
      // Rank violations ahead of non-violations while keeping score-descending
      // order within each bucket so row capping never hides a line violation.
      final ranked = [
        ...regularResults.where(isVio),
        ...regularResults.where((r) => !isVio(r)),
      ];
      final capped = _maxCommentRows > 0 && ranked.length > _maxCommentRows
          ? ranked.sublist(0, _maxCommentRows)
          : ranked;
      _renderRegularDeclarationsTable(
        capped,
        failThreshold,
        maxFunctionLines,
        commentBuf,
        emitAnnotations: false,
      );
      if (capped.length < ranked.length) {
        commentBuf
          ..writeln()
          ..writeln(
            '_Showing the $_maxCommentRows most significant of '
            '${ranked.length} declarations. '
            'See the workflow Step Summary for the full table._',
          );
      }
    }
    if (violatedFiles.isNotEmpty) {
      _renderRegularFileViolations(
        violatedFiles,
        maxFileLines!,
        commentBuf,
        emitAnnotations: false,
      );
    }
  }

  void _renderRegularDeclarationsTable(
    List<FunctionComplexity> results,
    int? failThreshold,
    int? maxFunctionLines,
    StringBuffer summaryBuf, {
    required bool emitAnnotations,
  }) {
    final showLines = maxFunctionLines != null && maxFunctionLines > 0;
    if (showLines) {
      summaryBuf.writeln('| Status | Declaration | Location | Lines | Score |');
      summaryBuf.writeln('| :---: | :--- | :--- | :---: | :---: |');
    } else {
      summaryBuf.writeln('| Status | Declaration | Location | Score |');
      summaryBuf.writeln('| :---: | :--- | :--- | :---: |');
    }

    for (final res in results) {
      _writeRegularDeclarationRow(
        res,
        failThreshold,
        maxFunctionLines,
        showLines,
        summaryBuf,
        emitAnnotations: emitAnnotations,
      );
    }
  }

  void _writeRegularDeclarationRow(
    FunctionComplexity res,
    int? failThreshold,
    int? maxFunctionLines,
    bool showLines,
    StringBuffer summaryBuf, {
    required bool emitAnnotations,
  }) {
    final isScoreVio = failThreshold != null && res.score > failThreshold;
    final isLineVio =
        maxFunctionLines != null &&
        maxFunctionLines > 0 &&
        res.lineCount > maxFunctionLines;
    final statusIcon = (isScoreVio || isLineVio) ? '🔴' : '🟢';
    final loc = '${res.filePath}:L${res.startLine}-${res.endLine}';
    if (showLines) {
      summaryBuf.writeln(
        '| $statusIcon | `${res.name}` | `$loc` '
        '| ${res.lineCount} | **${res.score}** |',
      );
    } else {
      summaryBuf.writeln(
        '| $statusIcon | `${res.name}` | `$loc` | **${res.score}** |',
      );
    }
    if (emitAnnotations && isScoreVio) {
      _stdoutSink.writeln(
        '::error file=${res.filePath},line=${res.startLine},'
        'title=High Cognitive Complexity '
        '(${res.score} > $failThreshold)::${res.name} has score '
        '${res.score} which exceeds failure threshold of $failThreshold.',
      );
    }
    if (emitAnnotations && isLineVio) {
      _stdoutSink.writeln(
        '::error file=${res.filePath},line=${res.startLine},'
        'title=Declaration Line Limit Exceeded '
        '(${res.lineCount} > $maxFunctionLines)::${res.name} spans '
        '${res.lineCount} lines which exceeds max-function-lines of '
        '$maxFunctionLines.',
      );
    }
  }

  void _renderRegularFileViolations(
    List<FileLineMetric> violatedFiles,
    int maxFileLines,
    StringBuffer summaryBuf, {
    required bool emitAnnotations,
  }) {
    summaryBuf
      ..writeln()
      ..writeln('## 📏 File Line Limit Violations')
      ..writeln()
      ..writeln('| Status | File | Lines | Limit |')
      ..writeln('| :---: | :--- | :---: | :---: |');
    for (final f in violatedFiles) {
      summaryBuf.writeln(
        '| 🔴 | `${f.filePath}` | **${f.lineCount}** | $maxFileLines |',
      );
      if (emitAnnotations) {
        _stdoutSink.writeln(
          '::error file=${f.filePath},line=1,'
          'title=File Line Limit Exceeded '
          '(${f.lineCount} > $maxFileLines)::${f.filePath} has ${f.lineCount} '
          'lines which exceeds max-file-lines of $maxFileLines.',
        );
      }
    }
  }

  void _reportDelta(
    DeltaSummary summary,
    int? failThreshold,
    int? maxFileLines,
    int? maxFunctionLines,
    bool failOnIncrease,
    StringBuffer summaryBuf,
    StringBuffer? commentBuf,
  ) {
    final net = summary.netDelta;
    final sign = net > 0 ? '+' : '';
    final violations = summary.countViolations(
      failThreshold: failThreshold,
      maxFileLines: maxFileLines,
      maxFunctionLines: maxFunctionLines,
      failOnIncrease: failOnIncrease,
    );
    final header =
        '**Net Delta**: $sign$net | **Added**: ${summary.countAdded} | '
        '**Increased**: ${summary.countIncreased} | '
        '**Improved**: ${summary.countImproved} | '
        '**Removed**: ${summary.countRemoved} | **Violations**: $violations';
    for (final buf in [summaryBuf, ?commentBuf]) {
      buf
        ..writeln(header)
        ..writeln();
    }

    final changed = _filterChangedDeltas(summary.deltas, maxFunctionLines);
    final violatedFiles = _filterViolatedFileDeltas(
      summary.fileDeltas,
      maxFileLines,
    );

    for (final d in changed) {
      _emitDiagnostic(d, failThreshold, maxFunctionLines, failOnIncrease);
    }
    for (final f in violatedFiles) {
      _stdoutSink.writeln(
        '::error file=${f.filePath},line=1,'
        'title=File Line Limit Violation::'
        '${f.filePath} grew to ${f.newLines} lines (limit: $maxFileLines).',
      );
    }

    if (changed.isEmpty && violatedFiles.isEmpty) {
      for (final buf in [summaryBuf, ?commentBuf]) {
        buf.writeln('No modified Dart declarations detected.');
      }
      return;
    }

    if (changed.isNotEmpty) {
      _renderDeltaTable(
        changed,
        failThreshold,
        maxFunctionLines,
        failOnIncrease,
        summaryBuf,
      );
    }
    if (violatedFiles.isNotEmpty) {
      _renderFileDeltaTable(violatedFiles, maxFileLines!, summaryBuf);
    }
    if (commentBuf != null) {
      if (changed.isNotEmpty) {
        _renderCappedComment(
          changed,
          failThreshold,
          maxFunctionLines,
          failOnIncrease,
          commentBuf,
        );
      }
      if (violatedFiles.isNotEmpty) {
        _renderFileDeltaTable(violatedFiles, maxFileLines!, commentBuf);
      }
    }
  }

  List<ComplexityDelta> _filterChangedDeltas(
    List<ComplexityDelta> deltas,
    int? maxFunctionLines,
  ) => deltas
      .where(
        (d) =>
            d.delta != 0 ||
            d.isFunctionLineViolation(maxFunctionLines: maxFunctionLines),
      )
      .toList();

  List<FileLineDelta> _filterViolatedFileDeltas(
    List<FileLineDelta> fileDeltas,
    int? maxFileLines,
  ) {
    if (maxFileLines == null || maxFileLines <= 0) return const [];
    return fileDeltas
        .where((f) => f.isViolation(maxFileLines: maxFileLines))
        .toList();
  }

  void _renderFileDeltaTable(
    List<FileLineDelta> violatedFiles,
    int maxFileLines,
    StringBuffer buf,
  ) {
    buf
      ..writeln()
      ..writeln('## 📏 File Line Limit Violations')
      ..writeln()
      ..writeln('| Status | File | Delta | Lines | Limit |')
      ..writeln('| :---: | :--- | :---: | :---: | :---: |');
    for (final f in violatedFiles) {
      final deltaStr = f.delta > 0 ? '+${f.delta}' : '${f.delta}';
      final linesStr = f.oldLines != null
          ? '${f.oldLines} -> **${f.newLines}**'
          : '**${f.newLines}**';
      buf.writeln(
        '| 🔴 | `${f.filePath}` | `$deltaStr` | $linesStr | $maxFileLines |',
      );
    }
  }

  /// Renders the sticky-comment table, capped at [_maxCommentRows], with a
  /// footer pointing at the full step summary when rows were omitted.
  ///
  /// [changed] arrives already ordered by significance from
  /// [DeltaAnalyzer.computeDeltas], so the cap keeps the most important rows.
  void _renderCappedComment(
    List<ComplexityDelta> changed,
    int? failThreshold,
    int? maxFunctionLines,
    bool failOnIncrease,
    StringBuffer commentBuf,
  ) {
    final ranked = changed;
    final capped = _maxCommentRows > 0 && ranked.length > _maxCommentRows
        ? ranked.sublist(0, _maxCommentRows)
        : ranked;

    _renderDeltaTable(
      capped,
      failThreshold,
      maxFunctionLines,
      failOnIncrease,
      commentBuf,
    );

    if (capped.length < ranked.length) {
      commentBuf
        ..writeln()
        ..writeln(
          '_Showing the $_maxCommentRows most significant of '
          '${ranked.length} changed declarations. '
          'See the workflow Step Summary for the full table._',
        );
    }
  }

  void _renderDeltaTable(
    List<ComplexityDelta> deltas,
    int? failThreshold,
    int? maxFunctionLines,
    bool failOnIncrease,
    StringBuffer buf,
  ) {
    buf.writeln('| Status | Declaration | Location | Delta | Score |');
    buf.writeln('| :---: | :--- | :--- | :---: | :---: |');

    for (final d in deltas) {
      final isVio = d.isViolation(
        failThreshold: failThreshold,
        maxFunctionLines: maxFunctionLines,
        failOnIncrease: failOnIncrease,
      );
      final icon = _getDeltaIcon(d, isVio);
      final deltaStr = d.delta > 0 ? '+${d.delta}' : '${d.delta}';
      final (loc, scoreStr) = switch ((d.oldScore, d.newScore)) {
        (final oldS?, final newS?) => (
          '${d.filePath}:L${d.startLine}-${d.endLine}',
          '$oldS -> **$newS**',
        ),
        (null, final newS?) => (
          '${d.filePath}:L${d.startLine}-${d.endLine}',
          '_new_ -> **$newS**',
        ),
        (final oldS?, null) => (d.filePath, '$oldS -> _deleted_'),
        (null, null) => (d.filePath, '_deleted_'),
      };

      buf.writeln('| $icon | `${d.name}` | `$loc` | `$deltaStr` | $scoreStr |');
    }
  }

  String _getDeltaIcon(ComplexityDelta d, bool isViolation) {
    if (isViolation) return '🔴';
    return switch (d.status) {
      DeltaStatus.increased => '🟡',
      DeltaStatus.improved => '🟢',
      DeltaStatus.added => '🔵',
      DeltaStatus.removed => '🗑️',
      DeltaStatus.unchanged => '⚪',
    };
  }

  /// Anchors annotations to the declaration line only: GitHub renders them
  /// below the last line of the range, so a whole-body range would place the
  /// message after the closing brace instead of under the signature.
  void _emitDiagnostic(
    ComplexityDelta d,
    int? failThreshold,
    int? maxFunctionLines,
    bool failInc,
  ) {
    if (d.isScoreViolation(
          failThreshold: failThreshold,
          failOnIncrease: failInc,
        ) &&
        d.newScore != null) {
      final reason = d.status == DeltaStatus.added
          ? 'newly introduced with high complexity'
          : 'increased in complexity (+${d.delta} points)';
      _stdoutSink.writeln(
        '::error file=${d.filePath},line=${d.startLine},'
        'title=Cognitive Complexity Violation::'
        '${d.name} was $reason to score ${d.newScore}.',
      );
    }

    if (d.isFunctionLineViolation(maxFunctionLines: maxFunctionLines) &&
        d.newLines != null) {
      _stdoutSink.writeln(
        '::error file=${d.filePath},line=${d.startLine},'
        'title=Declaration Line Limit Violation::'
        '${d.name} spans ${d.newLines} lines (limit: $maxFunctionLines).',
      );
    }
  }
}
