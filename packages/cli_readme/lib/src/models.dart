import 'package:args/args.dart';

/// Represents a command-line target to document and verify in a README.
class CliTarget {
  /// Unique identifier matching the marker in `README.md` (e.g.
  /// `<!-- CLI_README_START [id] -->`).
  ///
  /// If empty or omitted, matches the default marker
  /// `<!-- CLI_README_START -->`.
  final String id;

  /// The user-facing command name (e.g. `pubviz`, `dedupe`, `undead`).
  final String commandName;

  /// Optional relative path to the Dart script (e.g. `bin/dedupe.dart`).
  final String? executablePath;

  /// Optional in-memory [ArgParser] instance for zero-subprocess verification.
  final ArgParser? argParser;

  /// Optional command description line placed after the usage header.
  final String? description;

  /// Optional header text preceding the help output in the code fence.
  ///
  /// Defaults to `r'$ ' + commandName + ' --help'` or custom header.
  final String? header;

  /// Arguments passed when executing the binary or evaluating the parser.
  ///
  /// Defaults to `['--help']`.
  final List<String> args;

  /// Markdown code fence language identifier (e.g. `console`, `shell`, `text`).
  ///
  /// Defaults to `console`.
  final String codeFenceLanguage;

  const CliTarget({
    this.id = '',
    required this.commandName,
    this.executablePath,
    this.argParser,
    this.description,
    this.header,
    this.args = const ['--help'],
    this.codeFenceLanguage = 'console',
  });

  /// Creates a target backed by an executable script in `bin/`.
  factory CliTarget.executable({
    String id = '',
    required String executablePath,
    String? commandName,
    String? header,
    List<String> args = const ['--help'],
    String codeFenceLanguage = 'console',
  }) {
    final inferredName = commandName ?? _inferCommandName(executablePath);
    return CliTarget(
      id: id,
      commandName: inferredName,
      executablePath: executablePath,
      header: header,
      args: args,
      codeFenceLanguage: codeFenceLanguage,
    );
  }

  /// Creates a target backed by an in-memory [ArgParser].
  factory CliTarget.parser({
    String id = '',
    required String commandName,
    required ArgParser argParser,
    String? description,
    String? header,
    List<String> args = const ['--help'],
    String codeFenceLanguage = 'console',
  }) => CliTarget(
    id: id,
    commandName: commandName,
    argParser: argParser,
    description: description,
    header: header,
    args: args,
    codeFenceLanguage: codeFenceLanguage,
  );

  static String _inferCommandName(String path) {
    final file = path.split('/').last.split('\\').last;
    if (file.endsWith('.dart')) {
      return file.substring(0, file.length - 5);
    }
    return file;
  }
}

/// The result of verifying or updating a single target section in `README.md`.
class TargetResult {
  final CliTarget target;
  final bool isClean;
  final String expectedOutput;
  final String? actualOutputInReadme;
  final String? diff;
  final String? errorMessage;

  const TargetResult({
    required this.target,
    required this.isClean,
    required this.expectedOutput,
    this.actualOutputInReadme,
    this.diff,
    this.errorMessage,
  });
}

/// The aggregate result of verifying or updating all targets in a README.
class SyncResult {
  final String readmePath;
  final List<TargetResult> targetResults;
  final bool hasModifications;
  final String? updatedReadmeContent;

  const SyncResult({
    required this.readmePath,
    required this.targetResults,
    required this.hasModifications,
    this.updatedReadmeContent,
  });

  bool get isClean => targetResults.every((r) => r.isClean);

  List<TargetResult> get staleTargets =>
      targetResults.where((r) => !r.isClean).toList();
}
