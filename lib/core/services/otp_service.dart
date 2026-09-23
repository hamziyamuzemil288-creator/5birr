import 'package:supabase_flutter/supabase_flutter.dart';

/// Email OTP verification (signup gate, Task 7).
///
/// Server flow (nothing is trusted client-side):
///   1. sendOtp()   -> POST /functions/v1/send-otp. The Edge Function
///      generates the code, stores only its SHA-256 hash (10-min expiry,
///      5 attempts, 60 s resend window) and — while no email provider is
///      connected — returns `dev_code` so the flow is testable.
///   2. verifyOtp() -> rpc verify_email_otp(email, code). Consumes the code.
///   3. signUp()    -> the handle_new_user trigger refuses to create the
///      account unless a verified OTP exists for the email.
class OtpService {
  OtpService._();
  static final OtpService instance = OtpService._();

  SupabaseClient get _client => Supabase.instance.client;

  /// Requests a code for [email].
  ///
  /// Returns the plaintext code when the server runs in stub mode (no email
  /// provider connected — dev aid so the flow completes), otherwise null.
  /// Throws [OtpCooldownException] when the 60-second resend window is open.
  Future<String?> sendOtp(String email) async {
    final res = await _client.functions.invoke(
      'send-otp',
      body: {'email': email.trim().toLowerCase()},
    );
    final data = res.data as Map<String, dynamic>?;

    if (data == null) throw Exception('send-otp returned no data');

    if (data['retry_after_seconds'] != null) {
      throw OtpCooldownException((data['retry_after_seconds'] as num).toInt());
    }
    if (data['error'] != null) {
      throw Exception('send-otp error: ${data['error']}');
    }

    return data['dev_code'] as String?;
  }

  /// Verifies [code] for [email]. Throws on wrong/expired/exhausted codes.
  Future<void> verifyOtp(String email, String code) async {
    final res = await _client.rpc(
      'verify_email_otp',
      params: {'p_email': email.trim().toLowerCase(), 'p_code': code.trim()},
    );
    final data = Map<String, dynamic>.from(res as Map<dynamic, dynamic>);
    if (data['ok'] != true) {
      throw OtpVerifyException(data['error'] as String? ?? 'UNKNOWN');
    }
  }
}

/// 60-second resend window still open.
class OtpCooldownException implements Exception {
  final int retryAfterSeconds;
  OtpCooldownException(this.retryAfterSeconds);

  @override
  String toString() => 'OtpCooldownException($retryAfterSeconds)';
}

/// Verification failure: WRONG_CODE / NO_ACTIVE_CODE / TOO_MANY_ATTEMPTS.
class OtpVerifyException implements Exception {
  final String code;
  OtpVerifyException(this.code);

  @override
  String toString() => code;
}
