// #region in-memory
import 'package:args/args.dart';
import 'package:cli_readme/cli_readme.dart';
import 'package:test/test.dart';

// #endregion in-memory
/// Stands in for your package's own `ArgParser` factory.
ArgParser buildArgParser() => ArgParser()..addFlag('verbose');

// #region in-memory
void main() {
  test(
    'readme',
    () => expectReadmeHelpClean(
      targets: [
        CliTarget.parser(
          id: 'main',
          commandName: 'my_tool',
          argParser: buildArgParser(),
          description: 'My awesome command line tool.',
        ),
      ],
    ),
  );
  // #endregion in-memory

  // #region multiple-binaries
  test(
    'readme',
    () => expectReadmeHelpClean(
      targets: [
        CliTarget.executable(
          id: 'server',
          executablePath: 'bin/server.dart',
          commandName: 'my_server',
        ),
        CliTarget.executable(
          id: 'client',
          executablePath: 'bin/client.dart',
          commandName: 'my_client',
        ),
      ],
    ),
  );
  // #endregion multiple-binaries
  // #region in-memory
}
// #endregion in-memory
