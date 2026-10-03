import 'package:supabase_flutter/supabase_flutter.dart';

/// Single place where shop and service providers move an order through its
/// lifecycle: accept, reject, request payment, start work, complete.
///
/// Each action is delegated to the existing `order-transition` Edge Function,
/// which is the only actor allowed to call `transition_order_status()`. That
/// function re-checks the transition whitelist and the payment-proof gate
/// server-side, so none of these buttons can be used to skip a rule.
class OrderActionService {
  OrderActionService._();

  /// Move an order to a new status. The server decides whether the actor is
  /// allowed to make that move.
  static Future<void> transition({
    required String orderId,
    required String newStatus,
    required String actor,
    String? note,
  }) async {
    final response = await Supabase.instance.client.functions.invoke('order-transition', body: {
      'order_id': orderId,
      'new_status': newStatus,
      'actor': actor,
      'note': note,
    });

    if (response.status >= 400) {
      final error = response.data['error'] as String? ?? 'Unknown error';
      throw Exception(error);
    }

    final order = response.data['order'] as Map<String, dynamic>?;
    if (order == null || order['status'] == null) {
      throw Exception('Order transition returned no status');
    }
  }
}
