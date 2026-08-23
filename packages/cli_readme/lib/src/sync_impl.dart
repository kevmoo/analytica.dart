import 'dart:io';

import 'package:test/test.dart' show TestFailure;

import 'diff.dart';
import 'discover.dart';
import 'executor.dart';
import 'models.dart';
import 'normalizer.dart';
import 'parser.dart';

/// Core engine for synchronizing and verifying CLI help in README files.
class CliReadmeSync {
  final String workingDirectory;
  final String readmePath;
  final List<CliTarget> targets;

  CliReadmeSync({
    required this.workingDirectory,
    required this.readmePath,
    required this.targets,
  });

  /// Automatically discovers package context from [workingDir] and optional
  /// overrides.
  factory CliReadmeSync.discover({
    String? workingDir,
    String? packageRelativeDirectory,
    String? readmePath,
    List<CliTarget>? targets,
  }) {
    final ctx = PackageContext.discover(
      workingDir: workingDir,
      packageRelativeDirectory: packageRelativeDirectory,
      readmePath: readmePath,
      customTargets: targets,
    );

    return CliReadmeSync(
      workingDirectory: ctx.packageDirectory,
      readmePath: ctx.readmePath,
      targets: ctx.defaultTargets,
    );
  }

  /// Evaluates targets against the README without modifying disk.
  Future<SyncResult> evaluate() async {
    final readmeFile = File(readmePath);
    if (!readmeFile.existsSync()) {
      throw FileSystemException(
        'README file not found at "$readmePath".',
        readmePath,
      );
    }

    final readmeContent = readmeFile.readAsStringSync();
    final sections = findMarkedSections(readmeContent);
    final targetResults = <TargetResult>[];

    var updatedMarkdown = readmeContent;
    var hasModifications = false;

    for (final target in targets) {
      final rawCliOutput = await executeTarget(
        target,
        workingDirectory: workingDirectory,
      );

      final header =
          target.header ?? '\$ ${target.commandName} ${target.args.join(' ')}';
      final expectedFence = formatCodeFence(
        content: rawCliOutput,
        language: target.codeFenceLanguage,
        header: header,
      );

      // Find matching marked section in README
      final matchingSection = sections
          .where((s) => s.id == target.id)
          .firstOrNull;

      if (matchingSection == null) {
        final markerTag = target.id.isEmpty
            ? '<!-- CLI_README_START --> ... <!-- CLI_README_END -->'
            : '<!-- CLI_README_START ${target.id} --> ... '
                  '<!-- CLI_README_END ${target.id} -->';

        targetResults.add(
          TargetResult(
            target: target,
            isClean: false,
            expectedOutput: expectedFence,
            errorMessage:
                'Missing marked section for target "${target.commandName}" '
                '(id: "${target.id}").\n'
                'Add the following markers to $readmePath:\n\n$markerTag',
          ),
        );
        continue;
      }

      final actualInner = matchingSection.rawInnerContent;
      final normalizedActual = normalizeText(actualInner);
      final normalizedExpected = normalizeText(expectedFence);

      final isClean = normalizedActual == normalizedExpected;

      String? diff;
      if (!isClean) {
        final idLabel = target.id.isEmpty ? 'default' : target.id;
        diff = generateDiff(
          expected: normalizedExpected,
          actual: normalizedActual,
          expectedHeader: 'expected (from CLI)',
          actualHeader: 'actual in README.md ($idLabel)',
        );

        updatedMarkdown = replaceMarkedSectionById(
          markdown: updatedMarkdown,
          id: target.id,
          newInnerContent: expectedFence,
        );
        hasModifications = true;
      }

      targetResults.add(
        TargetResult(
          target: target,
          isClean: isClean,
          expectedOutput: expectedFence,
          actualOutputInReadme: actualInner,
          diff: diff,
        ),
      );
    }

    return SyncResult(
      readmePath: readmePath,
      targetResults: targetResults,
      hasModifications: hasModifications,
      updatedReadmeContent: updatedMarkdown,
    );
  }

  /// Verifies that all target sections in the README are clean and up to date.
  Future<SyncResult> verify() => evaluate();

  /// Updates all target sections in the README in-place.
  Future<SyncResult> update({bool dryRun = false}) async {
    final result = await evaluate();
    if (!dryRun &&
        result.hasModifications &&
        result.updatedReadmeContent != null) {
      File(readmePath).writeAsStringSync(result.updatedReadmeContent!);
    }
    return result;
  }
}

/// The 3-line test assertion helper.
///
/// Verifies that CLI usage in `README.md` matches the actual output.
/// If any target is out-of-date or missing, fails the test with a descriptive
/// diff.
Future<void> expectReadmeHelpClean({
  String? packageRelativeDirectory,
  String? readmePath,
  List<CliTarget>? targets,
}) async {
  final syncer = CliReadmeSync.discover(
    packageRelativeDirectory: packageRelativeDirectory,
    readmePath: readmePath,
    targets: targets,
  );

  final result = await syncer.verify();
  if (!result.isClean) {
    final buffer = StringBuffer();
    buffer.writeln(
      'README CLI documentation in ${result.readmePath} is out of date.',
    );
    buffer.writeln();

    for (final targetResult in result.staleTargets) {
      final t = targetResult.target;
      buffer.writeln('=== Target: ${t.commandName} (id: "${t.id}") ===');
      if (targetResult.errorMessage != null) {
        buffer.writeln(targetResult.errorMessage);
      }
      if (targetResult.diff != null) {
        buffer.writeln(targetResult.diff);
      }
      buffer.writeln();
    }

    buffer.writeln('To automatically update README.md, run:');
    buffer.writeln('  dart run cli_readme --write');

    throw TestFailure(buffer.toString());
  }
}
