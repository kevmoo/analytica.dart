/// Exceptions thrown during lower-bound validation and pubspec parsing.
abstract class LowerBoundException implements Exception {
  final String message;
  final String? path;

  const LowerBoundException(this.message, {this.path});

  @override
  String toString() => path != null ? '$message ($path)' : message;
}

/// Thrown when an expected input file or directory is missing.
class MissingInputException extends LowerBoundException {
  const MissingInputException(super.message, {super.path});
}

/// Thrown when pubspec.yaml resolution or parsing fails.
class PackageResolutionException extends LowerBoundException {
  const PackageResolutionException(super.message, {super.path});
}
