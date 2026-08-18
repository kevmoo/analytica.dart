# `pkg:undead`: Phase 2 & 3 Taxonomy (Internal Members & Enums)

> [!NOTE]
> This document specifies the **Phase 2 & Phase 3** design covering internal class members, constructors, fields, and enum constants.
> For the active Phase 1 (MVP) top-level declaration taxonomy, see [taxonomy.md](taxonomy.md).

---

## 1. Phase 2: Internal Class & Mixin Members

Phase 2 analyzes member-level reachability on classes, mixins, and extensions that are **already determined to be unexported/internal**.

### Covered Member Nodes
* Methods (`MethodDeclaration`)
* Fields & Getters/Setters (`FieldDeclaration`)
* Constructors (`ConstructorDeclaration`)

### Key Technical Challenges in Phase 2
1. **Subtype Polymorphism & Interface Overrides**:
   * If an internal class `class JsonReporter implements Reporter` implements `void report()`, and production code calls `(r as Reporter).report()`, `JsonReporter.report()` is live even if never referenced by name directly on `JsonReporter`.
   * **Required Engine**: Class Hierarchy Analysis (CHA) or Rapid Type Analysis (RTA) mapping interface calls to all concrete instantiated subtypes.
2. **Protocol & Core Overrides**:
   * `toJson()`, `toString()`, `operator ==`, `hashCode`, `compareTo()`, `noSuchMethod()`.
   * Must be hardcoded as exempt/live if the enclosing class is instantiated.
3. **Constructors & Initializer Dependencies**:
   * Default unnamed constructors (`ClassName()`) invoked implicitly via `super()` initializers.

---

## 2. Phase 3: Enum Constants & Fine-Grained Pruning

Phase 3 addresses individual enum values and fine-grained field parameters.

### Covered Nodes
* Enum constants (`EnumConstantDeclaration`)
* Positional constructor parameters

### Key Technical Challenges in Phase 3
1. **Dart 3 Switch Exhaustiveness**:
   * Removing an unreferenced enum value `Status.legacy` from an internal enum `enum Status { active, pending, legacy }` may break `switch (status)` statements that do not have a wildcard/default case.
2. **Enum Array Reflection**:
   * Code referencing `Status.values` (e.g. iterating over all values) dynamically touches all enum constants.
3. **Positional Parameter Impact**:
   * Removing an unused field initialized via `MyClass(this.unusedField, this.name)` alters constructor parameter indices and breaks call sites.

---

## 3. Phase 2/3 Classification Matrix

<!-- mdformat off(prevent table wrapping) -->
| Scenario / Code Pattern | Location | Exported? | Production Reachable? | Test Reachable? | Classification | Recommended Action |
| :--- | :--- | :---: | :---: | :---: | :--- | :--- |
| **Unused Method on Internal Class** | `lib/src/` | ❌ No | ❌ No | ❌ No | **Pure Zombie Member** | Delete method |
| **Tested-Only Method on Internal Class** | `lib/src/` | ❌ No | ❌ No | ✅ Yes | **Tested Zombie Member** | Delete method + remove orphan test calls |
| **Unused Enum Constant** | `lib/src/` | ❌ No | ❌ No | ❌ No | **Zombie Enum Value** | Check switch exhaustiveness before delete |
| **Polymorphic Interface Override** | `lib/src/` | ❌ No | (Via Interface) | N/A | **Exempt / Alive** | Preserve |
| **Suppressed via Custom Comment** | Any | ❌ No | ❌ No | ❌ No | **Ignored** | Skip (`// undead:ignore_for_class`) |
<!-- mdformat on -->
