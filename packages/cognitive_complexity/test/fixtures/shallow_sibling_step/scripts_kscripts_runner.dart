// Trimmed from kevmoo/scripts.dart `lib/src/kscripts_runner.dart` at
// f97ecee.
//
// Expected: `_reportStaleShim` is SIBLING_STEP (sibling
// `_reportUnknownSubcommand` shares its verb and arity).
import 'dart:io';

typedef KScriptSubcommand = ({
  String name,
  Future<void> Function(List<String>) run,
});

const _subcommands = <KScriptSubcommand>[];

KScriptSubcommand? findKScriptSubcommand(String name) {
  for (final s in _subcommands) {
    if (s.name == name) return s;
  }
  return null;
}

String? suggestKScriptSubcommand(String name) => null;

void setError({required String message, required int exitCode}) {
  stderr.writeln('$message (exit $exitCode)');
}

Future<void> runKScriptsCli(List<String> args, {String? invokedAs}) async {
  if (invokedAs != null && findKScriptSubcommand(invokedAs) == null) {
    _reportStaleShim(invokedAs);
    return;
  }

  if (args.isEmpty || args.first == '--help' || args.first == '-h') {
    stdout.writeln('usage');
    return;
  }

  if (args.first == 'help' && args.length > 1) {
    final targetName = args[1];
    final subcommand = findKScriptSubcommand(targetName);
    if (subcommand == null) {
      _reportUnknownSubcommand(targetName);
      return;
    }
    await subcommand.run(const ['--help']);
    return;
  }

  final commandName = args.first;
  final subcommand = findKScriptSubcommand(commandName);
  if (subcommand == null) {
    _reportUnknownSubcommand(commandName);
    return;
  }

  await subcommand.run(args.sublist(1));
}

void _reportStaleShim(String name) {
  setError(
    message:
        'kscripts was invoked as "$name", but this build of kscripts has no '
        '"$name" subcommand.\n'
        'The dotfiles are newer than the installed binary. Refresh it with '
        '"upkeep update dart_install", or directly:\n\n'
        "  dart install 'kevmoo_scripts@{git: https://github.com/kevmoo/scripts.dart}'",
    exitCode: 78,
  );
}

void _reportUnknownSubcommand(String commandName) {
  final suggestion = suggestKScriptSubcommand(commandName);
  final hint = suggestion != null
      ? ' Did you mean "kscripts $suggestion"?'
      : '';
  setError(
    message:
        'Unknown subcommand "$commandName".$hint\n\n'
        'Run "kscripts --help" to see available subcommands.',
    exitCode: 64,
  );
}
