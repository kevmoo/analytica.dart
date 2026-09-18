import 'dart:io';

import 'package:cognitive_complexity/src/file_split/cli.dart';
import 'package:stack_trace/stack_trace.dart';

Future<void> main(List<String> args) async {
  await Chain.capture(
    () async {
      exitCode = await runFileSplitCli(args);
    },
    onError: (Object error, Chain chain) {
      stderr.writeln('Fatal error: $error');
      stderr.writeln(chain.terse);
      exitCode = 1;
    },
  );
}
