// Trimmed from kevmoo/scripts.dart `lib/src/gh_view/github_queries.dart` at
// f97ecee.
//
// Expected: `_resolveActiveReviewers` stays SAFE_INLINE (its caller's other
// helpers are `_extract*`, not `_resolve*`).
typedef GhPr = ({
  int number,
  String author,
  List<String> activeReviewers,
  int unresolvedReviewThreads,
});

({DateTime? lastAuthorCommentAt, List<String> mentionedUsers})
_extractAuthorComment(Map<String, dynamic>? commentsObj, String prAuthor) {
  final nodes = (commentsObj?['nodes'] as List<dynamic>? ?? [])
      .whereType<Map<String, dynamic>>()
      .where((c) => c['author'] == prAuthor)
      .toList();
  if (nodes.isEmpty) return (lastAuthorCommentAt: null, mentionedUsers: []);
  final last = nodes.last;
  return (
    lastAuthorCommentAt: DateTime.tryParse(last['createdAt'] as String? ?? ''),
    mentionedUsers: RegExp(
      r'@(\w+)',
    ).allMatches(last['body'] as String? ?? '').map((m) => m[1]!).toList(),
  );
}

({DateTime? lastReviewerActivityAt, List<String> humanParticipants})
_extractReviewerActivity(Map<String, dynamic>? reviewsObj, String prAuthor) {
  final reviews = (reviewsObj?['nodes'] as List<dynamic>? ?? [])
      .whereType<Map<String, dynamic>>()
      .where((r) => r['author'] != prAuthor)
      .toList();
  return (
    lastReviewerActivityAt: reviews.isEmpty
        ? null
        : DateTime.tryParse(reviews.last['submittedAt'] as String? ?? ''),
    humanParticipants: {
      for (final r in reviews) r['author'] as String,
    }.toList(),
  );
}

List<String> _extractRequestedReviewers(Map<String, dynamic>? requestsObj) => [
  for (final r in requestsObj?['nodes'] as List<dynamic>? ?? [])
    if ((r as Map<String, dynamic>)['login'] case final String login) login,
];

({int total, int unresolved}) _extractReviewThreads(
  Map<String, dynamic>? reviewThreadsObj,
) {
  final totalThreads = reviewThreadsObj?['totalCount'] as int? ?? 0;
  final unresolved = (reviewThreadsObj?['nodes'] as List<dynamic>? ?? [])
      .whereType<Map<String, dynamic>>()
      .where((t) => t['isResolved'] != true)
      .length;
  return (total: totalThreads, unresolved: unresolved);
}

GhPr parsePrNode(Map<String, dynamic> node) {
  final prAuthor = node['author'] as String? ?? '';
  final humanRequested = _extractRequestedReviewers(
    node['reviewRequests'] as Map<String, dynamic>?,
  );
  final reviewerActivity = _extractReviewerActivity(
    node['reviews'] as Map<String, dynamic>?,
    prAuthor,
  );
  final authorComment = _extractAuthorComment(
    node['comments'] as Map<String, dynamic>?,
    prAuthor,
  );

  final lastAuthorCommentAt = authorComment.lastAuthorCommentAt;
  final lastReviewerActivityAt = reviewerActivity.lastReviewerActivityAt;
  final isAlreadyPinged =
      lastAuthorCommentAt != null &&
      (lastReviewerActivityAt == null ||
          lastAuthorCommentAt.isAfter(lastReviewerActivityAt));

  final activeReviewers = _resolveActiveReviewers(
    humanRequested: humanRequested,
    humanParticipants: reviewerActivity.humanParticipants,
    mentionedUsers: authorComment.mentionedUsers,
    isAlreadyPinged: isAlreadyPinged,
  );

  final threads = _extractReviewThreads(
    node['reviewThreads'] as Map<String, dynamic>?,
  );

  return (
    number: node['number'] as int? ?? 0,
    author: prAuthor,
    activeReviewers: activeReviewers,
    unresolvedReviewThreads: threads.unresolved,
  );
}

List<String> _resolveActiveReviewers({
  required List<String> humanRequested,
  required List<String> humanParticipants,
  required List<String> mentionedUsers,
  required bool isAlreadyPinged,
}) {
  if (isAlreadyPinged && mentionedUsers.isNotEmpty) {
    return {
      ...mentionedUsers,
      ...humanRequested,
      ...humanParticipants,
    }.toList();
  }
  return {...humanRequested, ...humanParticipants}.toList();
}
