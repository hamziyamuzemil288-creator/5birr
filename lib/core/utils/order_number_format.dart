/// Shared display formatting for category-coded order numbers
/// (Vh00001, Ht00001, Fd00001, Pr00001, Sv00001, Ot00001).
///
/// Numbers are generated server-side in create_order_secure (migration
/// 0037); this helper only renders them consistently across screens.
library;

/// Returns the order number formatted for display, or null when the row
/// predates migration 0037 (no order_number stored).
String? formatOrderNumber(dynamic orderNumber) {
  if (orderNumber is String && orderNumber.trim().isNotEmpty) {
    return orderNumber.trim();
  }
  return null;
}

/// Best-effort label for order rows: prefers the human-readable number and
/// falls back to the old short-UUID style for legacy orders.
String orderLabel(Map<String, dynamic> order) {
  final n = formatOrderNumber(order['order_number']);
  if (n != null) return n;
  final id = order['id'] as String?;
  if (id != null && id.length >= 8) return '#${id.substring(0, 8)}';
  return '#Order';
}
