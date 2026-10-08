import 'package:analytica/analyzer.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/source/line_info.dart';

import 'models.dart';

/// Extracts top-level [DeclarationUnit] nodes and their intra-file dependency
/// edges from a resolved [CompilationUnit].
Map<String, DeclarationUnit> harvestDeclarationUnits(
  CompilationUnit unit,
  LineInfo lineInfo,
) {
  final importMap = _buildImportDirectiveMap(unit);
  final (:units, :elementToDeclName) = _extractInitialUnits(unit, lineInfo);
  return _populateDeclarationEdges(unit, units, elementToDeclName, importMap);
}

Map<String, String> _buildImportDirectiveMap(CompilationUnit unit) {
  final map = <String, String>{};
  for (final directive in unit.directives.whereType<ImportDirective>()) {
    final uriStr = directive.libraryImport?.importedLibrary?.uri.toString();
    if (uriStr != null) {
      map[uriStr] = directive.toSource();
    }
  }
  return map;
}

({Map<String, DeclarationUnit> units, Map<Element, String> elementToDeclName})
_extractInitialUnits(CompilationUnit unit, LineInfo lineInfo) {
  final units = <String, DeclarationUnit>{};
  final elementToDeclName = <Element, String>{};

  for (final member in unit.declarations) {
    final info = _describeCompilationUnitMember(member);
    if (info == null) continue;

    final startLoc = lineInfo.getLocation(member.offset);
    final endLoc = lineInfo.getLocation(member.end);
    final metrics = _measureDeclarationMetrics(member, lineInfo);
    units[info.name] = DeclarationUnit(
      name: info.name,
      kind: info.kind,
      startLine: startLoc.lineNumber,
      endLine: endLoc.lineNumber,
      isPublic: !info.name.startsWith('_'),
      isSealed: info.isSealed,
      staticMethodCount: metrics.staticCount,
      staticMethodLines: metrics.staticLines,
      stringLiteralLines: metrics.stringLines,
      memberCount: metrics.memberCount,
      overrideMemberCount: metrics.overrideCount,
      supertypeLabel: metrics.supertypeLabel,
      outgoingIntraFileRefs: const {},
      privateMemberAccessesByTarget: const {},
      requiredImportDirectives: const {},
      hardPinnedPeers: const {},
    );

    for (final elem in info.elements) {
      elementToDeclName[elem] = info.name;
    }
  }
  return (units: units, elementToDeclName: elementToDeclName);
}

({
  int staticCount,
  int staticLines,
  int stringLines,
  int memberCount,
  int overrideCount,
  String? supertypeLabel,
})
_measureDeclarationMetrics(CompilationUnitMember member, LineInfo lineInfo) {
  final visitor = _DeclarationMetricsVisitor(lineInfo);
  member.accept(visitor);
  return (
    staticCount: visitor.staticCount,
    staticLines: visitor.staticLines,
    stringLines: visitor.stringLines,
    memberCount: visitor.memberCount,
    overrideCount: visitor.overrideCount,
    supertypeLabel: _supertypeLabel(member),
  );
}

/// `implements A, B` when the class declares interfaces, else `extends X`,
/// else `null`. Mixins (`with`) are intentionally not reported.
String? _supertypeLabel(CompilationUnitMember member) {
  if (member is! ClassDeclaration) return null;
  final interfaces = member.implementsClause?.interfaces;
  if (interfaces != null && interfaces.isNotEmpty) {
    return 'implements ${interfaces.map((t) => t.toSource()).join(', ')}';
  }
  final superclass = member.extendsClause?.superclass;
  return superclass == null ? null : 'extends ${superclass.toSource()}';
}

class _DeclarationMetricsVisitor extends RecursiveAstVisitor<void> {
  final LineInfo lineInfo;
  int staticCount = 0;
  int staticLines = 0;
  int stringLines = 0;
  int memberCount = 0;
  int overrideCount = 0;

  _DeclarationMetricsVisitor(this.lineInfo);

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    _recordMember(node);
    if (node.isStatic) {
      staticCount++;
      final start = lineInfo.getLocation(node.offset).lineNumber;
      final end = lineInfo.getLocation(node.end).lineNumber;
      staticLines += end >= start ? end - start + 1 : 0;
    }
    super.visitMethodDeclaration(node);
  }

  @override
  void visitFieldDeclaration(FieldDeclaration node) {
    _recordMember(node);
    super.visitFieldDeclaration(node);
  }

  void _recordMember(ClassMember node) {
    memberCount++;
    if (node.metadata.any((a) => a.name.name == 'override')) {
      overrideCount++;
    }
  }

  @override
  void visitAdjacentStrings(AdjacentStrings node) {
    _recordStringSpan(node);
  }

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    _recordStringSpan(node);
  }

  @override
  void visitStringInterpolation(StringInterpolation node) {
    _recordStringSpan(node);
  }

  void _recordStringSpan(AstNode node) {
    final start = lineInfo.getLocation(node.offset).lineNumber;
    final end = lineInfo.getLocation(node.end).lineNumber;
    final span = end - start + 1;
    if (span >= 5) {
      stringLines += span;
    }
  }
}

({String name, String kind, bool isSealed, List<Element> elements})?
_describeCompilationUnitMember(CompilationUnitMember member) {
  if (member is TopLevelVariableDeclaration) {
    return _describeVariableDeclaration(member);
  }
  final rawName = extractNodeName(member);
  if (rawName == null || rawName.isEmpty || rawName == '<unnamed>') return null;
  final elem = member.declaredFragment?.element;
  final isSealed = member is ClassDeclaration && member.sealedKeyword != null;
  return (
    name: rawName,
    kind: _memberKindLabel(member),
    isSealed: isSealed,
    elements: elem == null ? const [] : [elem],
  );
}

({String name, String kind, bool isSealed, List<Element> elements})?
_describeVariableDeclaration(TopLevelVariableDeclaration member) {
  final vars = member.variables.variables;
  if (vars.isEmpty) return null;
  final elems = <Element>[];
  for (final v in vars) {
    final el = v.declaredFragment?.element;
    if (el is TopLevelVariableElement) {
      elems.addAll([el, ?el.getter, ?el.setter]);
    } else if (el != null) {
      elems.add(el);
    }
  }
  return (
    name: vars.first.name.lexeme,
    kind: 'variable',
    isSealed: false,
    elements: elems,
  );
}

String _memberKindLabel(CompilationUnitMember member) => switch (member) {
  ClassDeclaration() || ClassTypeAlias() => 'class',
  EnumDeclaration() => 'enum',
  MixinDeclaration() => 'mixin',
  ExtensionDeclaration() => 'extension',
  ExtensionTypeDeclaration() => 'extension type',
  GenericTypeAlias() || FunctionTypeAlias() => 'typedef',
  FunctionDeclaration() => 'function',
  _ => 'declaration',
};

Map<String, DeclarationUnit> _populateDeclarationEdges(
  CompilationUnit unit,
  Map<String, DeclarationUnit> initial,
  Map<Element, String> elementToDeclName,
  Map<String, String> importMap,
) {
  final sealedNames = initial.values
      .where((u) => u.isSealed)
      .map((u) => u.name)
      .toSet();
  final hardPinsByDecl = <String, Set<String>>{
    for (final name in initial.keys) name: <String>{},
  };
  final extractedByDecl = <String, _ExtractedDeclRefs>{};

  for (final member in unit.declarations) {
    final info = _describeCompilationUnitMember(member);
    if (info == null || !initial.containsKey(info.name)) continue;

    extractedByDecl[info.name] = _extractMemberRefs(
      member,
      info.name,
      elementToDeclName,
      importMap,
    );
    _detectHardPins(
      member,
      info.name,
      sealedNames,
      elementToDeclName,
      hardPinsByDecl,
    );
  }

  return {
    for (final entry in initial.entries)
      entry.key: _mergeUnitWithRefs(
        entry.value,
        extractedByDecl[entry.key],
        hardPinsByDecl[entry.key] ?? const {},
      ),
  };
}

class _ExtractedDeclRefs {
  final Set<String> outgoing;
  final Map<String, Set<String>> privAccess;
  final Set<String> reqImports;

  const _ExtractedDeclRefs({
    required this.outgoing,
    required this.privAccess,
    required this.reqImports,
  });
}

_ExtractedDeclRefs _extractMemberRefs(
  CompilationUnitMember member,
  String selfName,
  Map<Element, String> elementToDeclName,
  Map<String, String> importMap,
) {
  final extractor = ElementReferenceExtractor();
  member.accept(extractor);

  final outgoing = <String>{
    for (final targetElem in extractor.referencedTopLevelElements)
      if (elementToDeclName[targetElem] case final targetName?
          when targetName != selfName)
        targetName,
  };

  final privAccess = <String, Set<String>>{};
  for (final entry in extractor.privateMemberAccessesByTarget.entries) {
    final targetName = elementToDeclName[entry.key];
    if (targetName != null && targetName != selfName) {
      privAccess.putIfAbsent(targetName, () => <String>{}).addAll(entry.value);
    }
  }

  final reqImports = <String>{
    for (final uri in extractor.referencedLibraryUris) ?importMap[uri],
  };

  return _ExtractedDeclRefs(
    outgoing: outgoing,
    privAccess: privAccess,
    reqImports: reqImports,
  );
}

DeclarationUnit _mergeUnitWithRefs(
  DeclarationUnit base,
  _ExtractedDeclRefs? refs,
  Set<String> hardPins,
) => DeclarationUnit(
  name: base.name,
  kind: base.kind,
  startLine: base.startLine,
  endLine: base.endLine,
  isPublic: base.isPublic,
  isSealed: base.isSealed,
  staticMethodCount: base.staticMethodCount,
  staticMethodLines: base.staticMethodLines,
  stringLiteralLines: base.stringLiteralLines,
  memberCount: base.memberCount,
  overrideMemberCount: base.overrideMemberCount,
  supertypeLabel: base.supertypeLabel,
  outgoingIntraFileRefs: refs == null
      ? const {}
      : Set.unmodifiable(refs.outgoing),
  privateMemberAccessesByTarget: refs == null || refs.privAccess.isEmpty
      ? const {}
      : Map.unmodifiable({
          for (final entry in refs.privAccess.entries)
            entry.key: Set.unmodifiable(entry.value),
        }),
  requiredImportDirectives: refs == null
      ? const {}
      : Set.unmodifiable(refs.reqImports),
  hardPinnedPeers: hardPins.isEmpty ? const {} : Set.unmodifiable(hardPins),
);

void _detectHardPins(
  CompilationUnitMember member,
  String declName,
  Set<String> sealedNames,
  Map<Element, String> elementToDeclName,
  Map<String, Set<String>> hardPinsByDecl,
) {
  for (final st in _extractSuperNamedTypes(member)) {
    final targetName = elementToDeclName[st.element];
    if (targetName != null && sealedNames.contains(targetName)) {
      hardPinsByDecl[declName]?.add(targetName);
      hardPinsByDecl[targetName]?.add(declName);
    }
  }

  if (declName.startsWith('_') && declName.endsWith('State')) {
    final widgetCandidate = declName.substring(1, declName.length - 5);
    if (hardPinsByDecl.containsKey(widgetCandidate)) {
      hardPinsByDecl[declName]?.add(widgetCandidate);
      hardPinsByDecl[widgetCandidate]?.add(declName);
    }
  }
}

List<NamedType> _extractSuperNamedTypes(CompilationUnitMember member) {
  if (member is ClassDeclaration) {
    return [
      ?member.extendsClause?.superclass,
      ...?member.withClause?.mixinTypes,
      ...?member.implementsClause?.interfaces,
    ];
  }
  if (member is MixinDeclaration) {
    return [
      ...?member.onClause?.superclassConstraints,
      ...?member.implementsClause?.interfaces,
    ];
  }
  return const [];
}
