import 'package:supabase_flutter/supabase_flutter.dart';

/// One-time provider activation (registration fee) status.
///
/// A provider must complete a first wallet recharge that covers the one-time
/// registration fee (default 100 birr — set via system_settings
/// 'provider_registration_fee') before they can upload listings or receive
/// order-location reveals. The admin's approval of that first recharge
/// withholds the fee and flips provider_profiles.registration_fee_paid.
///
/// [load] returns null when the signed-in user has no provider profile
/// (e.g. a plain buyer) — callers treat that as "no gate".
class ProviderActivation {
  final String providerId;
  final bool registrationFeePaid;
  final double registrationFee;

  const ProviderActivation({
    required this.providerId,
    required this.registrationFeePaid,
    required this.registrationFee,
  });

  bool get isActivated => registrationFeePaid;

  /// Human-readable blocking reason shown on listing forms.
  String get blockingMessage =>
      'Your account is not activated yet. Complete your first wallet recharge '
      '(includes the one-time ${registrationFee.toStringAsFixed(0)} birr '
      'registration fee) to upload listings.';

  /// Loads activation status for the signed-in provider, or null if the user
  /// has no provider profile. Settings lookups are non-fatal (default 100).
  static Future<ProviderActivation?> load() async {
    final client = Supabase.instance.client;
    final uid = client.auth.currentUser?.id;
    if (uid == null) return null;
    final prov = await client
        .from('provider_profiles')
        .select('id, registration_fee_paid')
        .eq('user_id', uid)
        .maybeSingle();
    if (prov == null) return null;
    double fee = 100;
    try {
      final s = await client
          .from('system_settings')
          .select('value')
          .eq('key', 'provider_registration_fee')
          .maybeSingle();
      final v = (s?['value'] as num?)?.toDouble();
      if (v != null && v > 0) fee = v;
    } catch (_) {}
    return ProviderActivation(
      providerId: prov['id'] as String,
      registrationFeePaid: (prov['registration_fee_paid'] as bool?) ?? false,
      registrationFee: fee,
    );
  }
}
