import 'dart:io';

import 'package:lower_bound/src/cli.dart';

void main(List<String> args) async {
  final exitCode = await runLowerBoundCli(args);
  exit(exitCode);
}
