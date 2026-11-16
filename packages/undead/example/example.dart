import 'package:undead/undead.dart';

void main() async {
  final options = UndeadOptions(packagePath: '.');
  final engine = UndeadEngine(options);
  final report = await engine.analyze();

  for (final finding in report.undead) {
    print('Unused: ${finding.name} (${finding.file}:L${finding.line})');
  }
}
