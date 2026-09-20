import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Provider presence: online / last-seen status.
///
/// While a provider is signed in and the app is foregrounded, a heartbeat
/// calls the SECURITY DEFINER RPC touch_provider_activity() (own rows only)
/// at most every 45 seconds. Consumers read get_provider_online_status():
/// a provider is "online" when last_active_at is within the last 3 minutes.
class ProviderPresence {
  ProviderPresence._();
  static final ProviderPresence instance = ProviderPresence._();

  Timer? _heartbeat;

  static const _heartbeatInterval = Duration(seconds: 45);

  /// Starts (or restarts) the periodic heartbeat for the signed-in provider.
  /// Safe to call multiple times; only one timer is ever active. Each tick
  /// touches own provider_profiles rows (RPC no-ops for non-providers).
  void startHeartbeat() {
    _heartbeat?.cancel();
    _touch(); // immediate first beat
    _heartbeat = Timer.periodic(_heartbeatInterval, (_) => _touch());
  }

  void stopHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  void _touch() {
    Supabase.instance.client.rpc('touch_provider_activity').then((_) {},
        onError: (_) {});
  }

  /// online + last_seen for one provider profile. lastSeen is null when the
  /// provider has never been active.
  static Future<({bool online, DateTime? lastSeen})> fetchStatus(
      String providerId) async {
    final rows = await Supabase.instance.client.rpc(
      'get_provider_online_status',
      params: {'p_provider_id': providerId},
    ) as List?;
    if (rows == null || rows.isEmpty) {
      return (online: false, lastSeen: null);
    }
    final r = Map<String, dynamic>.from(rows.first as Map);
    return (
      online: (r['online'] as bool?) ?? false,
      lastSeen: r['last_seen'] == null
          ? null
          : DateTime.parse(r['last_seen'] as String).toLocal(),
    );
  }

  /// "Online" / "Last seen X ago" label for profiles and listings.
  static String labelFor({required bool online, DateTime? lastSeen}) {
    if (online) return 'Online';
    if (lastSeen == null) return 'Last seen a while ago';
    final d = DateTime.now().difference(lastSeen);
    if (d.inSeconds < 60) return 'Last seen just now';
    if (d.inMinutes < 60) return 'Last seen ${d.inMinutes} min ago';
    if (d.inHours < 24) {
      final h = d.inHours;
      return 'Last seen $h ${h == 1 ? 'hour' : 'hours'} ago';
    }
    final days = d.inDays;
    if (days == 1) return 'Last seen yesterday';
    return 'Last seen $days days ago';
  }
}
