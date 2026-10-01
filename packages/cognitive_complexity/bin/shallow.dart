import 'dart:io';

import 'package:cognitive_complexity/src/shallow/cli.dart';
import 'package:stack_trace/stack_trace.dart';

void main(List<String> args) {
  Chain.capture(
    () async {
      exitCode = await runShallowCli(args);
    },
    onError: (Object error, Chain chain) {
      stderr.writeln('Fatal error: $error');
      stderr.writeln(chain.terse);
      exitCode = 1;
    },
  );
}
