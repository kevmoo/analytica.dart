import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:path/path.dart' as p;

/// An import of the source file that links back to the source file, directly
/// or through one re-export hop.
///
/// `via` describes the link, e.g. `imports a.dart` or
/// `re-exports b.dart, which re-exports a.dart`. `isBarrel` is `true` when the
/// link consists only of re-exports, so a cut copying the import would import
/// a barrel that re-exports the cut itself (through the source file's
/// `export ... show` bridge). Otherwise the cut merely carries over a cycle
/// the source file already has.
typedef InheritedImportCycle = ({String import, String via, bool isBarrel});

/// Maps each import directive of [unitResult] (as `directive.toSource()`, the
/// same text a cut's `requiredImports` copies) to the [InheritedImportCycle]
/// it would bring into a cut, if any.
Map<String, InheritedImportCycle> inheritedImportCycles(
  ResolvedUnitResult unitResult,
) {
  final source = unitResult.libraryElement;
  final sourceName = p.basename(unitResult.path);
  return {
    for (final directive
        in unitResult.unit.directives.whereType<ImportDirective>())
      if (directive.libraryImport?.importedLibrary case final imported?
          when imported.uri != source.uri)
        if (_reachBack(imported, source.uri, sourceName) case (
          final via,
          final isBarrel,
        ))
          directive.toSource(): (
            import: directive.uri.stringValue ?? directive.uri.toSource(),
            via: via,
            isBarrel: isBarrel,
          ),
  };
}

/// The warning text for a barrel [cycle].
String barrelCycleWarning(InheritedImportCycle cycle) =>
    "cut imports '${cycle.import}', which ${cycle.via}; move the declarations "
    'this cut uses out of the barrel to break the cycle';

/// Splits the [cycles] a cut's [requiredImports] bring in into barrel
/// warnings and informational inherited cycles.
({List<String> warnings, List<({String import, String via})> info})
splitInheritedCycles(
  Iterable<String> requiredImports,
  Map<String, InheritedImportCycle> cycles,
) {
  final found = [for (final imp in requiredImports) ?cycles[imp]];
  return (
    warnings: List.unmodifiable([
      for (final c in found)
        if (c.isBarrel) barrelCycleWarning(c),
    ]),
    info: List.unmodifiable([
      for (final c in found)
        if (!c.isBarrel) (import: c.import, via: c.via),
    ]),
  );
}

/// `(via, isBarrel)` for a link from [lib] back to the source, or `null`.
(String, bool)? _reachBack(
  LibraryElement lib,
  Uri sourceUri,
  String sourceName,
) {
  if (_directLink(lib, sourceUri) case final verb?) {
    return ('$verb $sourceName', verb == _reExports);
  }
  for (final hop in _exported(lib)) {
    if (hop.uri == sourceUri) continue;
    if (_directLink(hop, sourceUri) case final verb?) {
      return (
        '$_reExports ${p.url.basename(hop.uri.path)}, which $verb $sourceName',
        verb == _reExports,
      );
    }
  }
  return null;
}

const _reExports = 're-exports';

String? _directLink(LibraryElement lib, Uri sourceUri) {
  if (_exported(lib).any((l) => l.uri == sourceUri)) return _reExports;
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
