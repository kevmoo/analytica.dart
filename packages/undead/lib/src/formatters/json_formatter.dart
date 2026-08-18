import 'dart:convert';
import '../models.dart';

/// Formats a [UndeadReport] into pretty-printed JSON adhering to the PRD
/// schema.
class JsonFormatter {
  const JsonFormatter();

  String format(UndeadReport report) {
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(report.toJson());
  }
}
