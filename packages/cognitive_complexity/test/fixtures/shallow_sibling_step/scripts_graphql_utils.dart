// Trimmed from kevmoo/scripts.dart `lib/src/shared/graphql_utils.dart` at
// f97ecee.
//
// Expected: `_buildGraphQLArgs` stays SAFE_INLINE (its caller calls no other
// `build*` helper).
import 'dart:math' as math;

List<String> buildNextPageArgs({
  required String graphqlQuery,
  required String searchQuery,
  required int limit,
  required int currentCount,
  required int maxPageSize,
  required String? cursor,
}) => _buildNextPageArgs(
  graphqlQuery: graphqlQuery,
  searchQuery: searchQuery,
  limit: limit,
  currentCount: currentCount,
  maxPageSize: maxPageSize,
  cursor: cursor,
);

List<String> _buildNextPageArgs({
  required String graphqlQuery,
  required String searchQuery,
  required int limit,
  required int currentCount,
  required int maxPageSize,
  required String? cursor,
}) => _buildGraphQLArgs(
  graphqlQuery: graphqlQuery,
  searchQuery: searchQuery,
  pageSize: math.min(maxPageSize, limit - currentCount),
  cursor: cursor,
);

List<String> _buildGraphQLArgs({
  required String graphqlQuery,
  required String searchQuery,
  required int pageSize,
  String? cursor,
}) => <String>[
  'api',
  'graphql',
  '-f',
  'query=$graphqlQuery',
  '-F',
  'q=$searchQuery',
  '-F',
  'limit=$pageSize',
  if (cursor != null) ...['-F', 'cursor=$cursor'],
];
