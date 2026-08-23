import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'github_actions.dart';
import 'models.dart';

/// Handles output rendering and report generation across text, GitHub, and
/// JSON formats.
class LowerBoundReporter {
  /// Renders a human-readable text report to [sink].
  static void renderText(
    List<LowerBoundValidationResult> results,
    StringSink sink,
  ) {
    for (final result in results) {
      _renderPackageText(result, sink);
    }
  }

  static void _renderPackageText(
    LowerBoundValidationResult result,
    StringSink sink,
  ) {
    sink.writeln('=== Package: ${result.packageName} ===');
    sink.writeln('Path: ${result.packagePath}');
    sink.writeln('SDK Floor: ${result.minSdk}');

    if (!result.pubGetSuccess) {
      sink.writeln('Status: FAILED (pub resolution failed)');
      sink.writeln('Error: ${result.pubGetError}');
    } else if (!result.analyzeSuccess) {
      sink.writeln('Status: FAILED (static analysis errors at lower bound)');
      sink.writeln('Diagnostics:');
      for (final err in result.analyzerErrors) {
        sink.writeln('  $err');
      }
    } else {
      sink.writeln('Status: PASSED');
    }

    _renderDependenciesText(result, sink);
    sink.writeln();
  }

  static void _renderDependenciesText(
    LowerBoundValidationResult result,
    StringSink sink,
  ) {
    if (result.dependencies.isEmpty) return;

    sink.writeln('Dependency Resolution Floor:');
    for (final dep in result.dependencies) {
      final resolved = result.resolvedVersions[dep.name] ?? 'unresolved';
      final isExactFloor =
          dep.lowerBound != null &&
          resolved.toString() == dep.lowerBound.toString();
      final flag = isExactFloor ? '✓' : '~';
      final namePad = dep.name.padRight(20);
      final declPad = dep.declaredConstraint.toString().padRight(16);
      final floorPad = (dep.lowerBound?.toString() ?? 'any').padRight(10);
      sink.writeln(
        '  $flag $namePad declared: $declPad floor: $floorPad '
        'resolved: $resolved',
      );
    }
  }

  /// Builds a Markdown report for Step Summary and PR sticky comments.
  static String buildMarkdownReport(
    List<LowerBoundValidationResult> results, {
    int maxCommentRows = 0,
  }) {
    final buffer = StringBuffer();
    buffer.writeln('<!-- lower-bound-comment-marker -->');
    buffer.writeln('## 📦 Dependency Lower-Bound Validation Summary');
    buffer.writeln();

    for (final result in results) {
      _appendPackageMarkdown(buffer, result, maxCommentRows: maxCommentRows);
    }

    return buffer.toString();
  }

  static void _appendPackageMarkdown(
    StringBuffer buffer,
    LowerBoundValidationResult result, {
    int maxCommentRows = 0,
  }) {
    final statusIcon = result.isClean ? '✅' : '❌';
    buffer.writeln('### $statusIcon `${result.packageName}`');
    buffer.writeln('* **SDK Floor**: `${result.minSdk}`');
    buffer.writeln('* **Status**: ${result.isClean ? "Clean" : "**Failed**"}');
    buffer.writeln();

    _appendDiagnosticsMarkdown(buffer, result);
    _appendDependencyTableMarkdown(
      buffer,
      result,
      maxCommentRows: maxCommentRows,
    );
  }

  static void _appendDiagnosticsMarkdown(
    StringBuffer buffer,
    LowerBoundValidationResult result,
  ) {
    if (!result.pubGetSuccess) {
      buffer.writeln('> [!CAUTION]');
      buffer.writeln('> **Pub Resolution Error**:');
      buffer.writeln('> ```');
      buffer.writeln('> ${result.pubGetError}');
      buffer.writeln('> ```');
      buffer.writeln();
    } else if (!result.analyzeSuccess) {
      buffer.writeln('> [!WARNING]');
      buffer.writeln('> **Static Analysis Errors at Dependency Floor**:');
      buffer.writeln('> ```');
      for (final err in result.analyzerErrors) {
        buffer.writeln('> $err');
      }
      buffer.writeln('> ```');
      buffer.writeln();
    }
  }

  static void _appendDependencyTableMarkdown(
    StringBuffer buffer,
    LowerBoundValidationResult result, {
    int maxCommentRows = 0,
  }) {
    if (result.dependencies.isEmpty) return;

    buffer.writeln(
      '| Dependency | Declared Constraint | Declared Floor | '
      'Resolved Version | Status |',
    );
    buffer.writeln('| :--- | :--- | :--- | :--- | :---: |');

    final displayDeps = maxCommentRows > 0
        ? result.dependencies.take(maxCommentRows).toList()
        : result.dependencies;

    for (final dep in displayDeps) {
      final resolved = result.resolvedVersions[dep.name] ?? 'unresolved';
      final isFloor =
          dep.lowerBound != null &&
          resolved.toString() == dep.lowerBound.toString();
      final status = isFloor ? 'Exact Floor' : 'Satisfied';
      final floorStr = dep.lowerBound?.toString() ?? 'any';
      buffer.writeln(
        '| `${dep.name}` | `${dep.declaredConstraint}` | '
        '`$floorStr` | `$resolved` | $status |',
      );
    }

    if (maxCommentRows > 0 && result.dependencies.length > maxCommentRows) {
      final remaining = result.dependencies.length - maxCommentRows;
      buffer.writeln(
        '| ... *($remaining more dependencies omitted)* | | | | |',
      );
    }

    buffer.writeln();
  }

  /// Emits GitHub Step Summary and workflow annotations.
  static void renderGitHub(
    List<LowerBoundValidationResult> results,
    StringSink sink, {
    String? commentOutputFile,
    int maxCommentRows = 0,
  }) {
    _emitGitHubAnnotations(results);

    final summaryReport = buildMarkdownReport(results, maxCommentRows: 0);
    appendGitHubStepSummary(summaryReport);

    if (commentOutputFile != null && commentOutputFile.isNotEmpty) {
      final commentReport = buildMarkdownReport(
        results,
        maxCommentRows: maxCommentRows,
      );
      _writeCommentFile(commentOutputFile, commentReport);
    }

    renderText(results, sink);
  }

  static void _emitGitHubAnnotations(List<LowerBoundValidationResult> results) {
    for (final result in results) {
      final pubspecPath = p.join(result.packagePath, 'pubspec.yaml');

      if (!result.pubGetSuccess) {
        emitGitHubError(
          'Dependency resolution failed at floor: ${result.pubGetError}',
          file: pubspecPath,
        );
      } else if (!result.analyzeSuccess) {
        for (final err in result.analyzerErrors) {
          emitGitHubError(
            err,
            file: pubspecPath,
            title: 'Lower Bound Compile Error',
          );
        }
      }
    }
  }

  static void _writeCommentFile(String filePath, String content) {
    try {
      File(filePath).writeAsStringSync(content);
    } catch (_) {}
  }

  /// Renders structured JSON output to [sink].
  static void renderJson(
    List<LowerBoundValidationResult> results,
    StringSink sink,
  ) {
    final jsonList = results.map((r) => r.toJson()).toList();
    sink.writeln(const JsonEncoder.withIndent('  ').convert(jsonList));
  }
}
