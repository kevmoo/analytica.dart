import 'package:analyzer/dart/element/element.dart';

import 'adapters/adapters.dart';

export 'package:analytica/analytica.dart' show PackageResolutionException;

/// The classification category of a detected undead declaration.
enum UndeadClassification {
  /// An unexported declaration with zero incoming references from production or
  /// tests. Safe for immediate automated or manual deletion.
  pureUndead('pureUndead', 'Pure Undead'),

  /// A declaration referenced exclusively by isolated unit/integration tests
  /// with no other live dependencies. Safe to delete along with its orphan
  /// test blocks.
  testedUndead('testedUndead', 'Tested Undead'),

  /// A declaration referenced only in tests, but co-invoked within test blocks
  /// that also exercise live production code. Requires manual refactoring.
  coInvokedHazard('coInvokedHazard', 'Co-Invoked Test Hazard');

  final String jsonValue;
  final String displayName;

  const UndeadClassification(this.jsonValue, this.displayName);

  static UndeadClassification fromJson(String value) => switch (value) {
    'pureUndead' || 'pureUndead' => pureUndead,
    'testedUndead' || 'testedUndead' => testedUndead,
    'coInvokedHazard' => coInvokedHazard,
    _ => throw ArgumentError.value(
      value,
      'value',
      'Unknown UndeadClassification',
    ),
  };
}

/// The kind of Dart top-level AST declaration.
enum DeclarationKind {
  classType('class'),
  function('function'),
  enumType('enum'),
  mixinType('mixin'),
  extension('extension'),
  extensionType('extensionType'),
  typedefType('typedef'),
  variable('variable'),
  getter('getter'),
  setter('setter');

  final String jsonValue;

  const DeclarationKind(this.jsonValue);

  static DeclarationKind fromJson(String value) => switch (value) {
    'class' => classType,
    'function' => function,
    'enum' => enumType,
    'mixin' => mixinType,
    'extension' => extension,
    'extensionType' => extensionType,
    'typedef' => typedefType,
    'variable' => variable,
    'getter' => getter,
    'setter' => setter,
    _ => throw ArgumentError.value(value, 'value', 'Unknown DeclarationKind'),
  };
}

/// Suggested remediation action for a detected zombie.
abstract final class SuggestedAction {
  static const String delete = 'delete';
  static const String deleteWithOrphanTests = 'deleteWithOrphanTests';
  static const String manualRefactorHazard = 'manualRefactorHazard';
}

/// How code in `example/` is treated during reachability analysis.
enum ExampleMode {
  /// Code in `example/` serves as pub.dev demonstration and is a consumer root
  /// immune from deletion.
  demonstration('demonstration'),

  /// Code in `example/` is treated strictly as an internal analysis target.
  strict('strict'),

  /// Code in `example/` is excluded from analysis entirely.
  skip('skip');

  final String jsonValue;

  const ExampleMode(this.jsonValue);

  static ExampleMode fromString(String value) => switch (value) {
    'demonstration' => demonstration,
    'strict' => strict,
    'skip' => skip,
    _ => throw ArgumentError.value(value, 'value', 'Unknown ExampleMode'),
  };
}

/// Package analysis mode.
enum AnalysisMode {
  /// Open-World Invariant: All exported symbols in non-src `lib/**` are Public
  /// API roots.
  library('library'),

  /// Closed application universe: Unreferenced exports in `lib/**` can be
  /// flagged if not reached by executables or other roots.
  closedApp('closed-app');

  final String value;

  const AnalysisMode(this.value);

  static AnalysisMode fromString(String value) => switch (value) {
    'library' => library,
    'closed-app' => closedApp,
    _ => throw ArgumentError.value(value, 'value', 'Unknown AnalysisMode'),
  };
}

/// Output formatting mode for CLI and reports.
enum OutputFormat {
  markdown('markdown'),
  json('json');

  final String jsonValue;

  const OutputFormat(this.jsonValue);

  static OutputFormat fromString(String value) => switch (value) {
    'markdown' || 'github' => markdown,
    'json' => json,
    _ => throw ArgumentError.value(value, 'value', 'Unknown OutputFormat'),
  };
}

/// Configuration options for reachability analysis.
final class UndeadOptions {
  final String packagePath;
  final OutputFormat format;
  final ExampleMode exampleMode;
  final AnalysisMode mode;
  final bool includeGenerated;
  final bool failOnUndead;
  final bool autoPubGet;
  final String? sdkPath;
  final String? jsonOutputPath;
  final FrameworkAdapter frameworkAdapter;
  final List<String> testSupportPatterns;
  final List<String> ignoreNamePatterns;
  final List<String> extraRoots;
  final bool ignoreExternalBindings;
  final bool workspaceDiscovery;

  const UndeadOptions({
    required this.packagePath,
    this.format = OutputFormat.markdown,
    this.exampleMode = ExampleMode.demonstration,
    this.mode = AnalysisMode.library,
    this.includeGenerated = false,
    this.failOnUndead = false,
    this.autoPubGet = false,
    this.sdkPath,
    this.jsonOutputPath,
    this.frameworkAdapter = const CompositeFrameworkAdapter.defaults(),
    this.testSupportPatterns = const ['Fake*', 'Mock*'],
    this.ignoreNamePatterns = const [],
    this.extraRoots = const [],
    this.ignoreExternalBindings = false,
    this.workspaceDiscovery = true,
  });
}

/// Details about a test call site referencing a dead declaration.
class OrphanTestSite {
  final String file;
  final int line;
  final int column;
  final String? description;
  final bool coInvokedHazard;

  const OrphanTestSite({
    required this.file,
    required this.line,
    required this.column,
    this.description,
    this.coInvokedHazard = false,
  });

  factory OrphanTestSite.fromJson(Map<String, dynamic> json) => OrphanTestSite(
    file: json['file'] as String,
    line: json['line'] as int,
    column: json['column'] as int,
    description: json['description'] as String?,
    coInvokedHazard: json['coInvokedHazard'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {
    'file': file,
    'line': line,
    'column': column,
    if (description != null) 'description': description,
    'coInvokedHazard': coInvokedHazard,
  };

  @override
  String toString() =>
      '$file:$line:$column${description != null ? ' ("$description")' : ''}';
}

/// A detected dead/undead declaration.
class UndeadFinding {
  final String id;
  final String name;
  final DeclarationKind kind;
  final String file;
  final int line;
  final int column;
  final int length;
  final UndeadClassification classification;
  final String suggestedAction;
  final List<OrphanTestSite>? orphanTests;
  final bool isExternalBinding;

  const UndeadFinding({
    required this.id,
    required this.name,
    required this.kind,
    required this.file,
    required this.line,
    required this.column,
    required this.length,
    required this.classification,
    required this.suggestedAction,
    this.orphanTests,
    this.isExternalBinding = false,
  });

  factory UndeadFinding.fromJson(Map<String, dynamic> json) => UndeadFinding(
    id: json['id'] as String,
    name: json['name'] as String,
    kind: DeclarationKind.fromJson(json['kind'] as String),
    file: json['file'] as String,
    line: json['line'] as int,
    column: json['column'] as int,
    length: json['length'] as int,
    classification: UndeadClassification.fromJson(
      json['classification'] as String,
    ),
    suggestedAction: json['suggestedAction'] as String,
    orphanTests: (json['orphanTests'] as List<dynamic>?)
        ?.map((t) => OrphanTestSite.fromJson(t as Map<String, dynamic>))
        .toList(),
    isExternalBinding:
        json['isExternalBinding'] as bool? ??
        json['isExternalJsInterop'] as bool? ??
        false,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.jsonValue,
    'file': file,
    'line': line,
    'column': column,
    'length': length,
    'classification': classification.jsonValue,
    'suggestedAction': suggestedAction,
    if (isExternalBinding) 'isExternalBinding': true,
    if (orphanTests != null && orphanTests!.isNotEmpty)
      'orphanTests': orphanTests!.map((t) => t.toJson()).toList(),
  };
}

/// Complete diagnostic report generated by `pkg:undead`.
class UndeadReport {
  final String version;
  final String package;
  final int totalDeclarations;
  final int pureUndeadFound;
  final int testedUndeadFound;
  final int coInvokedHazardsFound;
  final List<UndeadFinding> undead;

  const UndeadReport({
    required this.version,
    required this.package,
    required this.totalDeclarations,
    required this.pureUndeadFound,
    required this.testedUndeadFound,
    required this.coInvokedHazardsFound,
    required this.undead,
  });

  factory UndeadReport.fromJson(Map<String, dynamic> json) {
    final summary = json['summary'] as Map<String, dynamic>;
    final findingsList =
        (json['undead'] as List<dynamic>?) ??
        (json['zombies'] as List<dynamic>?) ??
        const [];
    return UndeadReport(
      version: json['version'] as String,
      package: json['package'] as String,
      totalDeclarations: summary['totalDeclarations'] as int,
      pureUndeadFound:
          (summary['pureUndead'] as int?) ??
          (summary['pureUndeads'] as int?) ??
          0,
      testedUndeadFound:
          (summary['testedUndead'] as int?) ??
          (summary['testedUndeads'] as int?) ??
          0,
      coInvokedHazardsFound: summary['coInvokedHazards'] as int,
      undead: findingsList
          .map((e) => UndeadFinding.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    'package': package,
    'summary': {
      'totalDeclarations': totalDeclarations,
      'pureUndead': pureUndeadFound,
      'testedUndead': testedUndeadFound,
      'coInvokedHazards': coInvokedHazardsFound,
    },
    'undead': undead.map((z) => z.toJson()).toList(),
  };
}

/// Internal representation of a top-level declaration node in the
/// package graph.
class DeclarationNode {
  final String id;
  final String name;
  final DeclarationKind kind;
  final String relativeFilePath;
  final int offset;
  final int length;
  final int line;
  final int column;
  final Element? element;
  final bool isIgnored;
  final bool isExported;
  final bool isTestSupport;
  final bool isSealed;
  final bool isNativeRoot;
  final bool isExternalBinding;
  final String? sealedSuperclassName;
  final Element? sealedSuperclassElement;
  final Set<String> outgoingTargetIds;

  DeclarationNode({
    required this.id,
    required this.name,
    required this.kind,
    required this.relativeFilePath,
    required this.offset,
    required this.length,
    required this.line,
    required this.column,
    this.element,
    this.isIgnored = false,
    this.isExported = false,
    this.isTestSupport = false,
    this.isSealed = false,
    this.isNativeRoot = false,
    this.isExternalBinding = false,
    this.sealedSuperclassName,
    this.sealedSuperclassElement,
    Set<String>? outgoingTargetIds,
  }) : outgoingTargetIds = outgoingTargetIds ?? {};

  @override
  String toString() => '$kind $name ($relativeFilePath:$line:$column)';
}

/// Representation of a test site (block or function) in a test file.
class TestBlockSite {
  final String relativeFilePath;
  final int line;
  final int column;
  final String? description;
  final Set<String> referencedDeclarationIds;

  TestBlockSite({
    required this.relativeFilePath,
    required this.line,
    required this.column,
    this.description,
    Set<String>? referencedDeclarationIds,
  }) : referencedDeclarationIds = referencedDeclarationIds ?? {};
}
