import 'dart:io';
import 'package:undead/src/cli.dart';

Future<void> main(List<String> args) async {
  final runner = UndeadCliRunner();
  final code = await runner.run(args);
  if (code != 0) {
    exitCode = code;
  }
}
