import 'package:checks/checks.dart';
import 'package:cognitive_complexity/cognitive_complexity.dart';
import 'package:cognitive_complexity/data_flow.dart';
import 'package:test/test.dart';

void main() {
  group('Per-tool JSON schema snapshots', () {
    test(
      'ShallowReport.toJson and ShallowFinding.toJson snapshot',
      _verifyShallowJsonSnapshot,
    );

    test(
      'FileSplitReport.toJson and SplitCluster.toJson snapshot',
      _verifyFileSplitJsonSnapshot,
    );

    test('DataFlowResult.toJson snapshot', _verifyDataFlowJsonSnapshot);

    test(
      'FunctionComplexity.toJson and DeltaSummary.toJson snapshot',
      _verifyScoreAndDeltaJsonSnapshot,
    );
  });
}

void _verifyShallowJsonSnapshot() {
  const code = '''
void run(int a, int b) {
  _stepOne(a);
  _stepTwo(b);
  _singleHelper(a);
}
void _stepOne(int a) {
  if (a > 0) print(a);
}
void _stepTwo(int b) {
  if (b > 0) print(b);
}
void _singleHelper(int a) => print(a);
''';
  final report = ShallowAnalyzer().analyzeCode(code, filePath: 'lib/a.dart');
  final json = report.toJson();

  check(json['schema_version']).equals(1);
  check(json.keys.toList()).deepEquals([
    'schema_version',
    'declarations_scanned',
    'max_caller_cc',
    'max_params',
    'total_findings',
    'safe_inline_count',
    'zero_headroom_count',
    'sibling_step_count',
    'estimated_safe_lines_saved',
    'findings',
  ]);
  check(json['sibling_step_count']).equals(2);
  check(json['safe_inline_count']).equals(1);

  final findings = (json['findings'] as List).cast<Map<String, dynamic>>();
  final stepOne = findings.singleWhere((f) => f['name'] == '_stepOne');
  check(stepOne['classification']).equals('SIBLING_STEP');
  check(stepOne['sibling_steps'] as List).deepEquals(['_stepTwo']);
  check(stepOne.keys.toList()).deepEquals([
    'file',
    'name',
    'start_line',
    'end_line',
    'lines',
    'parameter_count',
    'named_parameter_count',
    'effective_parameter_count',
    'signature_lines',
    'body_lines',
    'statement_count',
    'score',
    'caller_file',
    'caller_name',
    'caller_zone',
    'call_line',
    'call_nesting_depth',
    'caller_base_score',
    'caller_cumulative_before',
    'inlined_delta_score',
    'inlined_caller_score',
    'inlined_caller_score_isolated',
    'headroom_after_inline',
    'shared_param_signature_with',
    'shared_param_count',
    'params_subset_of_existing_type',
    'simulation_index',
    'estimated_lines_saved',
    'classification',
    'reasons',
    'sibling_steps',
  ]);
}

void _verifyFileSplitJsonSnapshot() {
  const decl = DeclarationUnit(
    name: 'UserRecord',
    kind: 'extensionType',
    startLine: 10,
    endLine: 40,
    isPublic: true,
    isSealed: false,
    representationType: 'String',
    outgoingIntraFileRefs: {'Role'},
    privateMemberAccessesByTarget: {},
    requiredImportDirectives: {},
    hardPinnedPeers: {},
  );
  const cluster = SplitCluster(
    suggestedFileName: 'user_models.dart',
    tier: SplitTier.tier1CleanLibrary,
    topologicalDepth: 1,
    isDisjointIsland: true,
    declarations: [decl],
    absorbedPrivateHelpers: [],
    privateTopLevelsToWiden: [],
    privateMembersToWiden: [],
    requiredImports: ["import 'role.dart';"],
    exportedPublicSymbols: ['UserRecord'],
    rationale: 'Cohesive model cluster.',
    notes: ['sibling type Role pulled in'],
    warnings: ['barrel cycle warning'],
    inheritedCycles: [(import: "import '../barrel.dart';", via: 'barrel.dart')],
  );
  const report = FileSplitReport(
    filePath: 'lib/user.dart',
    totalLines: 500,
    targetLines: 300,
    declarationCount: 4,
    lcom4Islands: 2,
    sccCount: 4,
    maxTopologicalDepth: 2,
    clusters: [cluster],
    survivingDeclarations: [],
  );

  final json = report.toJson();
  check(json['schema_version']).equals(1);
  check(json.keys.toList()).deepEquals([
    'schema_version',
    'file',
    'total_lines',
    'target_lines',
    'use_parts',
    'declaration_count',
    'lcom4_islands',
    'scc_count',
    'max_topological_depth',
    'extracted_lines',
    'estimated_remaining_lines',
    'largest_resulting_file_lines',
    'meets_target',
    'has_surviving_coupled_scc',
    'clusters',
    'surviving_declarations',
  ]);

  final clusterJson = (json['clusters'] as List).single as Map<String, dynamic>;
  check(clusterJson['suggested_file']).equals('user_models.dart');
  check(
    clusterJson['notes'] as List,
  ).deepEquals(['sibling type Role pulled in']);
  check(clusterJson['warnings'] as List).deepEquals(['barrel cycle warning']);
  check(clusterJson['inherited_cycles'] as List).deepEquals([
    {'import': "import '../barrel.dart';", 'via': 'barrel.dart'},
  ]);
  final declJson =
      (clusterJson['declarations'] as List).single as Map<String, dynamic>;
  check(declJson['representation_type']).equals('String');
}

void _verifyDataFlowJsonSnapshot() {
  const result = DataFlowResult(
    filePath: 'lib/flow.dart',
    startLine: 5,
    endLine: 15,
    enclosingDeclaration: 'processItems',
    inputs: [
      VariableUsage(
        name: 'count',
        type: 'int',
        isMutated: false,
        declarationLine: 2,
      ),
    ],
    mutations: [],
    outputs: [],
    escapes: [
      ControlFlowEscape(
        type: ControlFlowEscapeType.earlyReturn,
        line: 10,
        description: 'Early return statement',
      ),
    ],
    suggestedSignature: 'void _extracted(int count)',
    isCleanlyExtractable: false,
    enclosingScore: 18,
    sliceScoreInPlace: 8,
    sliceScoreAtRoot: 4,
    extractionWarnings: ['Contains early return'],
  );

  final json = result.toJson();
  check(json['schema_version']).equals(1);
  check(json.keys.toList()).deepEquals([
    'schema_version',
    'file',
    'start_line',
    'end_line',
    'enclosing_declaration',
    'is_cleanly_extractable',
    'enclosing_score',
    'slice_score_in_place',
    'slice_score_at_root',
    'estimated_enclosing_score_after',
    'inputs',
    'mutations',
    'outputs',
    'escapes',
    'extraction_warnings',
    'suggested_signature',
  ]);
  check(json['estimated_enclosing_score_after']).equals(10);
}

void _verifyScoreAndDeltaJsonSnapshot() {
  const fc = FunctionComplexity(
    filePath: 'lib/score.dart',
    name: 'compute',
    startLine: 1,
    endLine: 20,
    score: 12,
    composition: (branches: 5, nesting: 6, booleanOps: 1, maxDepth: 3),
  );
  final fcJson = fc.toJson();
  check(fcJson.keys.toList()).deepEquals([
    'file',
    'name',
    'start_line',
    'end_line',
    'lines',
    'score',
    'composition',
    'is_test_entrypoint',
  ]);

  const deltaSummary = DeltaSummary(
    baseRef: 'origin/main',
    targetRef: 'HEAD',
    filesAnalyzed: 1,
    deltas: [
      ComplexityDelta(
        filePath: 'lib/score.dart',
        name: 'compute',
        startLine: 1,
        endLine: 20,
        oldScore: 16,
        newScore: 12,
        oldLines: 25,
        newLines: 20,
        status: DeltaStatus.improved,
      ),
    ],
  );
  final deltaJson = deltaSummary.toJson(failThreshold: 15);
  check(deltaJson['schema_version']).equals(1);
  check(deltaJson.keys.toList()).deepEquals([
    'schema_version',
    'base_ref',
    'target_ref',
    'summary',
    'deltas',
  ]);
}
