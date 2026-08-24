import 'dart:async';

/// Runs [action] in a [Zone] where [print] calls are intercepted, returning all
/// printed lines as a single string.
///
/// If any lines were printed, each line is terminated by a newline.
Future<String> capturePrints(FutureOr<void> Function() action) async {
  final buffer = StringBuffer();
  await runZoned(
    () async => await action(),
    zoneSpecification: ZoneSpecification(
      print: (_, _, _, line) {
        buffer.writeln(line);
      },
    ),
  );
  return buffer.toString();
}
