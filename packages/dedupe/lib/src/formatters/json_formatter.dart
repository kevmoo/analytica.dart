import 'dart:convert';

import '../models.dart';

/// Formatter that outputs [DedupeReport] as pretty-printed JSON.
class JsonFormatter {
  const JsonFormatter();

  String format(DedupeReport report) {
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(report.toJson());
  }
}
