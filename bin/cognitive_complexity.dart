import 'dart:io';

import 'package:cognitive_complexity/src/complexity/cli.dart';
import 'package:stack_trace/stack_trace.dart';

void main(List<String> args) {
  Chain.capture(
    () async {
      final code = await runCli(args);
      exitCode = code;
      if (code != 0) {
        exit(code);
      }
    },
    onError: (Object error, Chain chain) {
      stderr.writeln('Fatal error: $error');
      stderr.writeln(chain.terse);
      exit(1);
    },
  );
}
