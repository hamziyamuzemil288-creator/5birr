import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Utility class for exporting data to CSV files.
class CsvExport {
  CsvExport._();

  /// Generate CSV content from a list of maps and a list of column headers.
  static String generateCsv({
    required List<String> columns,
    required List<Map<String, dynamic>> rows,
    String? title,
  }) {
    final buffer = StringBuffer();
    
    // Optional title row
    if (title != null) {
      buffer.writeln('"$title"');
      buffer.writeln();
    }
    
    // Header row
    buffer.writeln(columns.map((c) => '"$c"').join(','));
    
    // Data rows
    for (final row in rows) {
      final values = columns.map((col) {
        final val = row[col];
        if (val == null) return '""';
        final str = val.toString().replaceAll('"', '""');
        return '"$str"';
      });
      buffer.writeln(values.join(','));
    }
    
    return buffer.toString();
  }

  /// Save CSV to a temporary file and share it.
  static Future<void> exportAndShare({
    required List<String> columns,
    required List<Map<String, dynamic>> rows,
    required String fileName,
    String? title,
  }) async {
    final csv = generateCsv(columns: columns, rows: rows, title: title);
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$fileName.csv');
    await file.writeAsString(csv);
    await Share.shareXFiles([XFile(file.path)], subject: fileName);
  }

  /// Format a DateTime for DD/MM/YYYY display.
  static String formatDate(DateTime dt) {
    return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';
  }

  /// Format a DateTime for CSV (ISO 8601).
  static String formatDateIso(DateTime dt) {
    return dt.toIso8601String().substring(0, 10);
  }

  /// Format a currency amount.
  static String formatCurrency(double amount) {
    return 'ETB ${amount.toStringAsFixed(2)}';
  }
}
