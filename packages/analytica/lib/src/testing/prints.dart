import 'dart:async';

import 'package:checks/context.dart';

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

/// Extensions on synchronous function [Subject]s for checking printed output.
extension SyncPrintsChecks on Subject<void Function()> {
  /// Extracts the captured output from [print] calls during the synchronous
  /// execution of this function as a [Subject<String>].
  Subject<String> get prints {
    return context.nest<String>(() => ['prints output'], (actual) {
      final buffer = StringBuffer();
      try {
        runZoned(
          actual,
          zoneSpecification: ZoneSpecification(
            print: (_, _, _, line) {
              buffer.writeln(line);
            },
          ),
        );
        return Extracted.value(buffer.toString());
      } catch (e, st) {
        return Extracted.rejection(
          actual: ['a function that throws'],
          which: [
            ...prefixFirst('threw ', literal(e)),
            ...st.toString().split('\n'),
          ],
        );
      }
    });
  }
}

/// Extensions on asynchronous function [Subject]s for checking printed output.
extension AsyncPrintsChecks on Subject<Future<void> Function()> {
  /// Checks expectations on the output captured from [print] calls during the
  /// execution of this asynchronous function.
  Future<void> prints([AsyncCondition<String>? outputCondition]) async {
    await context.nestAsync<String>(() => ['prints output'], (actual) async {
      final buffer = StringBuffer();
      try {
        await runZoned(
          actual,
          zoneSpecification: ZoneSpecification(
            print: (_, _, _, line) {
              buffer.writeln(line);
            },
          ),
        );
        return Extracted.value(buffer.toString());
      } catch (e, st) {
        return Extracted.rejection(
          actual: ['a function that throws'],
          which: [
            ...prefixFirst('threw ', literal(e)),
            ...st.toString().split('\n'),
          ],
        );
      }
    }, outputCondition);
  }
}
