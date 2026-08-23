import 'dart:io';

/// Resolves the GitHub Actions Step Summary markdown file from the environment,
/// or `null` if not running inside GitHub Actions.
File? resolveGitHubSummaryFile() {
  final path = Platform.environment['GITHUB_STEP_SUMMARY'];
  if (path == null || path.isEmpty) return null;
  return File(path);
}

/// Appends [markdown] content to the GitHub Actions step summary file.
void appendGitHubStepSummary(
  String markdown, {
  File? summaryFile,
  StringSink? errSink,
}) {
  final file = summaryFile ?? resolveGitHubSummaryFile();
  if (file != null) {
    try {
      file.writeAsStringSync(markdown, mode: FileMode.append);
    } catch (e) {
      (errSink ?? stderr).writeln(
        'Warning: Failed to write to step summary file: $e',
      );
    }
  }
}

/// Emits a GitHub Actions workflow error annotation.
void emitGitHubError(
  String message, {
  String? file,
  int? line,
  int? endLine,
  int? col,
  int? endColumn,
  String? title,
  StringSink? sink,
}) {
  _emitWorkflowCommand(
    'error',
    message,
    file: file,
    line: line,
    endLine: endLine,
    col: col,
    endColumn: endColumn,
    title: title,
    sink: sink,
  );
}

/// Emits a GitHub Actions workflow warning annotation.
void emitGitHubWarning(
  String message, {
  String? file,
  int? line,
  int? endLine,
  int? col,
  int? endColumn,
  String? title,
  StringSink? sink,
}) {
  _emitWorkflowCommand(
    'warning',
    message,
    file: file,
    line: line,
    endLine: endLine,
    col: col,
    endColumn: endColumn,
    title: title,
    sink: sink,
  );
}

/// Emits a GitHub Actions workflow notice annotation.
void emitGitHubNotice(
  String message, {
  String? file,
  int? line,
  int? endLine,
  int? col,
  int? endColumn,
  String? title,
  StringSink? sink,
}) {
  _emitWorkflowCommand(
    'notice',
    message,
    file: file,
    line: line,
    endLine: endLine,
    col: col,
    endColumn: endColumn,
    title: title,
    sink: sink,
  );
}

void _emitWorkflowCommand(
  String command,
  String message, {
  String? file,
  int? line,
  int? endLine,
  int? col,
  int? endColumn,
  String? title,
  StringSink? sink,
}) {
  final params = <String>[];
  if (file != null) params.add('file=$file');
  if (line != null) params.add('line=$line');
  if (endLine != null) params.add('endLine=$endLine');
  if (col != null) params.add('col=$col');
  if (endColumn != null) params.add('endColumn=$endColumn');
  if (title != null) params.add('title=$title');

  final paramStr = params.isNotEmpty ? ' ${params.join(',')}' : '';
  (sink ?? stdout).writeln('::$command$paramStr::$message');
}
