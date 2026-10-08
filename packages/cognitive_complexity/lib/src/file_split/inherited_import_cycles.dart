import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:path/path.dart' as p;

/// Maps each import directive of [unitResult] (as `directive.toSource()`, the
/// same text a cut's `requiredImports` copies) to an inherited-cycle warning
/// when the imported library imports or re-exports this library, directly or
/// through one re-export hop.
///
/// A cut that copies such an import would import a library that (via the
/// source file's `export ... show` bridge) re-exports the cut itself.
Map<String, String> inheritedImportCycleWarnings(
  ResolvedUnitResult unitResult,
) {
  final source = unitResult.libraryElement;
  final sourceName = p.basename(unitResult.path);
  return {
    for (final directive
        in unitResult.unit.directives.whereType<ImportDirective>())
      if (directive.libraryImport?.importedLibrary case final imported?
          when imported.uri != source.uri)
        if (_reachBack(imported, source.uri, sourceName) case final reason?)
          directive.toSource():
              "cut imports '${directive.uri.stringValue}', which $reason "
              '(inherited import cycle)',
  };
}

/// `re-exports <source>`, `imports <source>`, or
/// `re-exports <hop>, which imports|re-exports <source>`; `null` otherwise.
String? _reachBack(LibraryElement lib, Uri sourceUri, String sourceName) {
  if (_directLink(lib, sourceUri) case final verb?) return '$verb $sourceName';
  for (final hop in _exported(lib)) {
    if (hop.uri == sourceUri) continue;
    if (_directLink(hop, sourceUri) case final verb?) {
      return 're-exports ${p.url.basename(hop.uri.path)}, which '
          '$verb $sourceName';
    }
  }
  return null;
}

String? _directLink(LibraryElement lib, Uri sourceUri) {
  if (_exported(lib).any((l) => l.uri == sourceUri)) return 're-exports';
  final imported = [
    for (final f in lib.fragments)
      for (final i in f.libraryImports) ?i.importedLibrary,
  ];
  return imported.any((l) => l.uri == sourceUri) ? 'imports' : null;
}

List<LibraryElement> _exported(LibraryElement lib) => [
  for (final f in lib.fragments)
    for (final e in f.libraryExports) ?e.exportedLibrary,
];
