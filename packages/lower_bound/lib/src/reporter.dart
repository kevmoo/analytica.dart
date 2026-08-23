import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'github_actions.dart';
import 'models.dart';

/// Renders a human-readable text report to [sink].
void renderText(List<LowerBoundValidationResult> results, StringSink sink) {
  for (final result in results) {
    _renderPackageText(result, sink);
  }
}

void _renderPackageText(LowerBoundValidationResult result, StringSink sink) {
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

  if (result.warnings.isNotEmpty) {
    sink.writeln('Warnings:');
    for (final warning in result.warnings) {
      sink.writeln('  • $warning');
    }
  }

  _renderDependenciesText(result, sink);
  sink.writeln();
}

void _renderDependenciesText(
  LowerBoundValidationResult result,
  StringSink sink,
) {
  if (result.dependencies.isEmpty) return;

  sink.writeln('Dependency Resolution Floor:');
  for (final dep in result.dependencies) {
    if (dep.isLocalPathOverride) {
      final namePad = dep.name.padRight(20);
      final declPad = dep.declaredConstraint.toString().padRight(16);
      sink.writeln(
        '  ~ $namePad declared: $declPad '
        '(local path override: ${dep.localPath}, '
        'version: ${dep.localVersion})',
      );
      continue;
    }

    if (dep.isNonHosted) {
      final namePad = dep.name.padRight(20);
      sink.writeln('  - $namePad (non-hosted dependency)');
      continue;
    }

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
String buildMarkdownReport(
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

void _appendPackageMarkdown(
  StringBuffer buffer,
  LowerBoundValidationResult result, {
  int maxCommentRows = 0,
}) {
  final statusIcon = result.isClean ? '✅' : '❌';
  buffer.writeln('### $statusIcon `${result.packageName}`');
  buffer.writeln('* **SDK Floor**: `${result.minSdk}`');
  buffer.writeln('* **Status**: ${result.isClean ? "Clean" : "**Failed**"}');
  buffer.writeln();

  _appendWarningsMarkdown(buffer, result);
  _appendDiagnosticsMarkdown(buffer, result);
  _appendDependencyTableMarkdown(
    buffer,
    result,
    maxCommentRows: maxCommentRows,
  );
}

void _appendWarningsMarkdown(
  StringBuffer buffer,
  LowerBoundValidationResult result,
) {
  if (result.warnings.isEmpty) return;
  buffer.writeln('> [!NOTE]');
  buffer.writeln('> **Validation Warnings**:');
  for (final warning in result.warnings) {
    buffer.writeln('> * $warning');
  }
  buffer.writeln();
}

void _appendDiagnosticsMarkdown(
  StringBuffer buffer,
  LowerBoundValidationResult result,
) {
  if (!result.pubGetSuccess) {
    buffer.writeln('> [!CAUTION]');
    buffer.writeln('> **Pub Resolution Error**:');
    buffer.writeln('> ```');
    final errLines = (result.pubGetError ?? 'Unknown error').split('\n');
    for (final line in errLines) {
      buffer.writeln('> $line');
    }
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

void _appendDependencyTableMarkdown(
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
    final status = _computeDependencyStatus(dep, result);
    final resolved = result.resolvedVersions[dep.name] ?? 'unresolved';
    final floorStr = dep.lowerBound?.toString() ?? 'any';
    buffer.writeln(
      '| `${dep.name}` | `${dep.declaredConstraint}` | '
      '`$floorStr` | `$resolved` | $status |',
    );
  }

  if (maxCommentRows > 0 && result.dependencies.length > maxCommentRows) {
    final remaining = result.dependencies.length - maxCommentRows;
    buffer.writeln('| ... *($remaining more dependencies omitted)* | | | | |');
  }

  buffer.writeln();
}

String _computeDependencyStatus(
  DependencyFloor dep,
  LowerBoundValidationResult result,
) {
  if (dep.isLocalPathOverride) return 'Local Sibling Override';
  if (dep.isNonHosted) return 'Non-Hosted';
  final resolved = result.resolvedVersions[dep.name] ?? 'unresolved';
  final isFloor =
      dep.lowerBound != null &&
      resolved.toString() == dep.lowerBound.toString();
  return isFloor ? 'Exact Floor' : 'Satisfied';
}

/// Emits GitHub Step Summary and workflow annotations.
void renderGitHub(
  List<LowerBoundValidationResult> results,
  StringSink sink, {
  String? workspaceRoot,
}) {
  _emitGitHubAnnotations(results, workspaceRoot: workspaceRoot);

  final summaryReport = buildMarkdownReport(results, maxCommentRows: 0);
  appendGitHubStepSummary(summaryReport);

  renderText(results, sink);
}

void _emitGitHubAnnotations(
  List<LowerBoundValidationResult> results, {
  String? workspaceRoot,
}) {
  final root = workspaceRoot ?? Directory.current.path;

  for (final result in results) {
    final pubspecPath = _toRelativePath(
      p.join(result.packagePath, 'pubspec.yaml'),
      root,
    );

    if (!result.pubGetSuccess) {
      emitGitHubError(
        'Dependency resolution failed at floor: ${result.pubGetError}',
        file: pubspecPath,
      );
      continue;
    }

    for (final diag in result.diagnostics) {
      if (diag.isError) {
        final filePath = diag.file != null
            ? _toRelativePath(p.join(result.packagePath, diag.file!), root)
            : pubspecPath;
        emitGitHubError(
          diag.message,
          file: filePath,
          line: diag.line,
          col: diag.column,
          title: 'Lower Bound Compile Error',
        );
      }
    }
  }
}

String _toRelativePath(String fullPath, String root) {
  return p.isWithin(root, fullPath)
      ? p.relative(fullPath, from: root)
      : fullPath;
}

/// Renders structured JSON output to [sink].
void renderJson(List<LowerBoundValidationResult> results, StringSink sink) {
  final jsonList = results.map((r) => r.toJson()).toList();
  sink.writeln(const JsonEncoder.withIndent('  ').convert(jsonList));
}
