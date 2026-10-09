import 'package:checks/checks.dart';
import 'package:cognitive_complexity/cognitive_complexity.dart';
import 'package:cognitive_complexity/data_flow.dart';
import 'package:test/scaffolding.dart';

// `ShallowClassification`, `SplitTier`, and `ControlFlowEscapeType` are open
// value classes rather than enums, so the compiler no longer flags a missing
// switch arm when a value is added. These tables list every per-value mapping
// the package relies on; a new value fails here until it is added to the
// table and every mapping is checked.

/// Label (text and JSON `classification`) and the JSON/header count key, if
/// the value has one.
const _shallow = <ShallowClassification, ({String label, String? countKey})>{
  ShallowClassification.safeInline: (
    label: 'SAFE_INLINE',
    countKey: 'safe_inline_count',
  ),
  ShallowClassification.zeroHeadroom: (
    label: 'ZERO_HEADROOM',
    countKey: 'zero_headroom_count',
  ),
  ShallowClassification.siblingStep: (
    label: 'SIBLING_STEP',
    countKey: 'sibling_step_count',
  ),
  ShallowClassification.flattenAndInline: (
    label: 'FLATTEN_AND_INLINE',
    countKey: null,
  ),
  ShallowClassification.loadBearing: (label: 'LOAD_BEARING', countKey: null),
};

/// Text header phrase for each counted classification.
const _shallowHeader = {
  ShallowClassification.safeInline: '1 SAFE_INLINE keeping Caller CC < 15',
  ShallowClassification.zeroHeadroom: '1 ZERO_HEADROOM landing exactly on 15',
  ShallowClassification.siblingStep:
      '1 SIBLING_STEP with same-stem siblings kept extracted',
};

const _tiers = <SplitTier, ({String name, String label})>{
  SplitTier.tier1CleanLibrary: (
    name: 'tier1CleanLibrary',
    label: 'Tier 1: Clean Library Split (import + export show)',
  ),
  SplitTier.tier2InternalWidening: (
    name: 'tier2InternalWidening',
    label: 'Tier 2: Controlled @internal Widening Split',
  ),
  SplitTier.tier3PartDirective: (
    name: 'tier3PartDirective',
    label: 'Tier 3: Library part / part of Split (Gated)',
  ),
};

const _escapes = <ControlFlowEscapeType, String>{
  ControlFlowEscapeType.earlyReturn: 'earlyReturn',
  ControlFlowEscapeType.loopBreak: 'loopBreak',
  ControlFlowEscapeType.loopContinue: 'loopContinue',
  ControlFlowEscapeType.yieldEscape: 'yieldEscape',
  ControlFlowEscapeType.rethrowEscape: 'rethrowEscape',
  ControlFlowEscapeType.closureEscape: 'closureEscape',
  ControlFlowEscapeType.constructorInitializerEscape:
      'constructorInitializerEscape',
};

const _countKeys = [
  'safe_inline_count',
  'zero_headroom_count',
  'sibling_step_count',
];

void main() {
  group('ShallowClassification', () {
    test('values are exactly the mapped set, in report order', () {
      check(ShallowClassification.values).deepEquals(_shallow.keys.toList());
    });

    test('name and toString match the former enum', () {
      check(ShallowClassification.values.map((c) => c.toString())).deepEquals(
        ShallowClassification.values.map(
          (c) => 'ShallowClassification.${c.name}',
        ),
      );
      check(ShallowClassification.values.map((c) => c.name)).deepEquals([
        'safeInline',
        'zeroHeadroom',
        'siblingStep',
        'flattenAndInline',
        'loadBearing',
      ]);
    });

    test('every value has a label, JSON string, and count mapping', () {
      _shallow.forEach(_checkShallowMapping);
    });
  });

  group('SplitTier', () {
    test('values are exactly the mapped set, in order', () {
      check(SplitTier.values).deepEquals(_tiers.keys.toList());
    });

    test('every value has a JSON name, label, and toString', () {
      _tiers.forEach(_checkTierMapping);
    });
  });

  group('ControlFlowEscapeType', () {
    test('values are exactly the mapped set, in order', () {
      check(ControlFlowEscapeType.values).deepEquals(_escapes.keys.toList());
    });

    test('every value has a JSON name and toString', () {
      _escapes.forEach(_checkEscapeMapping);
    });
  });
}

void _checkShallowMapping(
  ShallowClassification c,
  ({String label, String? countKey}) m,
) {
  check(because: '$c label', c.label).equals(m.label);
  final report = _shallowReport(c);
  final json = report.toJson();
  final finding = (json['findings'] as List).single as Map;
  check(because: '$c JSON', finding['classification']).equals(m.label);
  check(because: '$c count keys', {
    for (final key in _countKeys) key: json[key],
  }).deepEquals({for (final key in _countKeys) key: key == m.countKey ? 1 : 0});
  final text = report.formatText();
  check(because: '$c text', text).contains('[${m.label}] ');
  final header = _shallowHeader[c];
  if (header != null) check(because: '$c header', text).contains(header);
}

void _checkTierMapping(SplitTier tier, ({String name, String label}) m) {
  check(tier.name).equals(m.name);
  check(tier.label).equals(m.label);
  check(tier.toString()).equals('SplitTier.${m.name}');
  final json = _cluster(tier).toJson();
  check(because: '$tier tier', json['tier']).equals(m.name);
  check(because: '$tier tier_label', json['tier_label']).equals(m.label);
}

void _checkEscapeMapping(ControlFlowEscapeType type, String name) {
  check(type.name).equals(name);
  check(type.toString()).equals('ControlFlowEscapeType.$name');
  final json = ControlFlowEscape(
    type: type,
    line: 1,
    description: 'd',
  ).toJson();
  check(because: '$type JSON', json['type']).equals(name);
}

ShallowReport _shallowReport(ShallowClassification c) => ShallowReport(
  findings: [
    ShallowFinding(
      filePath: 'lib/a.dart',
      name: '_helper',
      startLine: 10,
      endLine: 12,
      parameterCount: 1,
      namedParameterCount: 0,
      effectiveParameterCount: 1,
      signatureLines: 1,
      bodyLines: 1,
      statementCount: 1,
      score: 0,
      callerFilePath: 'lib/a.dart',
      callerName: 'run',
      callerZone: 'lib',
      callLine: 3,
      callNestingDepth: 0,
      callerBaseScore: 2,
      callerCumulativeBefore: 2,
      inlinedDeltaScore: 0,
      inlinedCallerScore: 2,
      inlinedCallerScoreIsolated: 2,
      headroomAfterInline: 13,
      sharedParamSignatureWith: null,
      sharedParamCount: 0,
      paramsSubsetOfExistingType: null,
      simulationIndex: 0,
      estimatedLinesSaved: 3,
      classification: c,
      reasons: const ['MICRO_HELPER(1 bodyL, 1 stmt, CC=0)'],
      siblingSteps: c == ShallowClassification.siblingStep
          ? const ['_helper2']
          : const [],
    ),
  ],
  declarationsScanned: 2,
  maxCallerScore: 15,
  maxParams: 5,
);

SplitCluster _cluster(SplitTier tier) => SplitCluster(
  suggestedFileName: 'a.dart',
  tier: tier,
  topologicalDepth: 0,
  isDisjointIsland: false,
  declarations: const [],
  absorbedPrivateHelpers: const [],
  privateTopLevelsToWiden: const [],
  privateMembersToWiden: const [],
  requiredImports: const [],
  exportedPublicSymbols: const [],
  rationale: 'r',
);
