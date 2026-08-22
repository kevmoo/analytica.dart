import 'dart:io';
import 'package:dedupe/src/cli.dart';

Future<void> main(List<String> args) async {
  final runner = DedupeCliRunner();
  final code = await runner.run(args);
  if (code != 0) {
    exitCode = code;
  }
}
