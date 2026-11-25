@TestOn('vm')
library;

import 'package:api_summary/api_summary.dart';
import 'package:test/scaffolding.dart';

void main() {
  // Temporary opt-out until DedupeDeltaService.applyDiffToClusters drops its
  // unused non-public `List<TokenSequence> sequences` parameter in 0.2.0.
  test(
    'api_summary',
    () => expectApiSummaryClean(
      customizer: const ApiSummaryCustomizer(allowNonPublicTypes: true),
    ),
  );
}
