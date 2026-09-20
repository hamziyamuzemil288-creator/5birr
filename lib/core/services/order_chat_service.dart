import 'package:supabase_flutter/supabase_flutter.dart';

/// One chat message inside an order's conversation.
class OrderChatMessage {
  final String id;
  final String orderId;
  final String senderId;
  final String kind; // 'TEXT' | 'LOCATION'
  final String? body;
  final double? lat;
  final double? lng;
  final String? locationLabel;
  final DateTime createdAt;

  const OrderChatMessage({
    required this.id,
    required this.orderId,
    required this.senderId,
    required this.kind,
    this.body,
    this.lat,
    this.lng,
    this.locationLabel,
    required this.createdAt,
  });

  bool get isLocation => kind == 'LOCATION';

  factory OrderChatMessage.fromRow(Map<String, dynamic> row) {
    final loc = row['location'] as Map<String, dynamic>?;
    final coords = loc?['coordinates'] as List?;
    return OrderChatMessage(
      id: row['id'] as String,
      orderId: row['order_id'] as String,
      senderId: row['sender_id'] as String,
      kind: (row['kind'] as String?) ?? 'TEXT',
      body: row['body'] as String?,
      lat: coords != null && coords.length >= 2
          ? (coords[1] as num).toDouble()
          : (row['lat'] as num?)?.toDouble(),
      lng: coords != null && coords.length >= 2
          ? (coords[0] as num).toDouble()
          : (row['lng'] as num?)?.toDouble(),
      locationLabel: row['location_label'] as String?,
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }
}

/// Chat between buyer and provider on one order, backed by the
/// `order_messages` table (migration 0036). Participants only per RLS;
/// LOCATION messages are escrow-gated server-side (APPROVED/STARTED) in
/// line with the existing GPS reveal rules — surfaced here as a friendly
/// exception.
class OrderChatService {
  OrderChatService._();
  static final instance = OrderChatService._();

  final _client = Supabase.instance.client;

  /// Live stream of the conversation, oldest first.
  Stream<List<Map<String, dynamic>>> streamMessages(String orderId) {
    return _client
        .from('order_messages')
        .stream(primaryKey: ['id'])
        .eq('order_id', orderId)
        .order('created_at');
  }

  /// Fetch existing messages once (used to seed before the stream warms up).
  Future<List<Map<String, dynamic>>> getMessages({
    required String orderId,
    int limit = 100,
  }) async {
    final data = await _client
        .from('order_messages')
        .select()
        .eq('order_id', orderId)
        .order('created_at', ascending: true)
        .limit(limit);
    return List<Map<String, dynamic>>.from(data as List);
  }

  /// Send a text message as the current user.
  Future<void> sendText({
    required String orderId,
    required String body,
  }) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) throw Exception('Not authenticated');
    await _client.from('order_messages').insert({
      'order_id': orderId,
      'sender_id': userId,
      'kind': 'TEXT',
      'body': body.trim(),
    });
  }

  /// Send a one-shot live GPS location message as the current user.
  ///
  /// Throws [LocationNotRevealedException] when the order has not reached
  /// the escrow reveal statuses yet (payment verified / delivery started).
  Future<void> sendLocation({
    required String orderId,
    required double lat,
    required double lng,
    String? label,
  }) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) throw Exception('Not authenticated');
    try {
      await _client.from('order_messages').insert({
        'order_id': orderId,
        'sender_id': userId,
        'kind': 'LOCATION',
        'location': 'SRID=4326;POINT($lng $lat)',
        if (label != null && label.trim().isNotEmpty)
          'location_label': label.trim(),
      });
    } on PostgrestException catch (e) {
      if (e.message.contains('LOCATION_NOT_REVEALED')) {
        throw LocationNotRevealedException();
      }
      if (e.message.contains('NOT_YOUR_ORDER')) {
        throw Exception('You are not part of this order.');
      }
      rethrow;
    }
  }
}

/// The order has not reached the escrow reveal statuses, so live location
/// cannot be shared yet.
class LocationNotRevealedException implements Exception {
  const LocationNotRevealedException();
  @override
  String toString() => 'LOCATION_NOT_REVEALED';
}
