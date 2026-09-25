import 'package:supabase_flutter/supabase_flutter.dart';

/// A short-lived server-generated anti-bot challenge.
///
/// The answer stays in Postgres. The app only receives the public id and the
/// math question, then asks [CaptchaService.verify] to check the user's answer.
class CaptchaChallenge {
  final String id;
  final String question;

  const CaptchaChallenge({required this.id, required this.question});
}

/// Client for the zero-setup CAPTCHA RPCs from migration 0003.
class CaptchaService {
  CaptchaService._();

  static final CaptchaService instance = CaptchaService._();

  SupabaseClient get _client => Supabase.instance.client;

  /// Whether the owner has enabled CAPTCHA enforcement.
  ///
  /// A lookup failure defaults to true so a network problem cannot silently
  /// bypass the server-side signup/appeal gate.
  Future<bool> isRequired() async {
    try {
      return await _client.rpc('captcha_required') == true;
    } catch (_) {
      return true;
    }
  }

  /// Requests a fresh challenge. Answers are generated and stored server-side.
  Future<CaptchaChallenge> request() async {
    final data = await _client.rpc('request_captcha');
    final raw = data is List && data.isNotEmpty ? data.first : data;
    final row = Map<String, dynamic>.from(raw as Map<dynamic, dynamic>);
    final id = row['captcha_id']?.toString();
    final question = row['question']?.toString();
    if (id == null || id.isEmpty || question == null || question.isEmpty) {
      throw const CaptchaException('The security check could not be loaded.');
    }
    return CaptchaChallenge(id: id, question: question);
  }

  /// Verifies [answer]. A wrong answer burns the challenge and requires a new
  /// one; callers should display [CaptchaException.message] and refresh.
  Future<void> verify(String captchaId, String answer) async {
    final data = await _client.rpc(
      'verify_captcha',
      params: {'p_captcha_id': captchaId, 'p_answer': answer},
    );
    final raw = data is List && data.isNotEmpty ? data.first : data;
    final row = Map<String, dynamic>.from(raw as Map<dynamic, dynamic>);
    if (row['ok'] == true) return;

    final code = row['error']?.toString() ?? 'WRONG_ANSWER';
    throw CaptchaException(switch (code) {
      'EXPIRED' => 'This security check expired. Please solve a new one.',
      'ALREADY_USED' =>
        'This security check was already used. Please try again.',
      _ => 'That answer is not correct. Please try a new challenge.',
    });
  }
}

// ---------------------------------------------------------------------------
// Login gate (Task 13 item 2): the password sign-in itself is a protected
// action. The gate lives in the `login-gate` Edge Function (service role):
// CAPTCHA enforcement + per-account failure lockout that clients cannot
// bypass or reset.
// ---------------------------------------------------------------------------
extension LoginGate on CaptchaService {
  /// Server check BEFORE the credential attempt: consumes [captchaId] when
  /// CAPTCHA is enforced and refuses when the account is temporarily locked
  /// (too many recent failures). Throws:
  ///  • [LoginLockedException] — locked; message carries the retry window
  ///  • [CaptchaException]     — challenge missing/failed
  /// A gate outage fails CLOSED (the login is refused) — never open.
  Future<void> gateLogin({required String email, String? captchaId}) async {
    try {
      final res = await _client.functions.invoke('login-gate', body: {
        'action': 'gate',
        'email': email.trim().toLowerCase(),
        'captcha_id': captchaId,
      });
      final data = res.data as Map<String, dynamic>?;
      if (data == null) {
        throw const CaptchaException(
            'Sign-in is temporarily unavailable. Try again shortly.');
      }
      if (data['ok'] == true) return;
      _throwLoginGateError(data);
    } on FunctionsHttpException catch (e) {
      // supabase_flutter throws before returning FunctionResponse for every
      // non-2xx response. Map the JSON error here so a rejected CAPTCHA or
      // lockout never leaks as a raw FunctionsHttpException to the login UI.
      final details = e.details;
      final data = details is Map
          ? Map<String, dynamic>.from(details)
          : const <String, dynamic>{};
      _throwLoginGateError(data);
    }
  }

  Never _throwLoginGateError(Map<String, dynamic> data) {
    final code = data['error']?.toString() ?? 'UNKNOWN';
    switch (code) {
      case 'temporarily_locked':
        final secs = (data['retry_after_seconds'] as num?)?.toInt() ?? 900;
        throw LoginLockedException(secs);
      case 'captcha_required':
        throw const CaptchaException(
            'Complete the security check before signing in.');
      case 'captcha_failed':
        throw const CaptchaException(
            'That security check is not valid. Solve a new one.');
      default:
        throw const CaptchaException(
            'Sign-in is temporarily unavailable. Try again shortly.');
    }
  }

  /// Reports the sign-in outcome. Never throws — a bookkeeping failure must
  /// not mask the real login result.
  Future<void> recordLoginAttempt(
      {required String email, required bool success}) async {
    try {
      await _client.functions.invoke('login-gate', body: {
        'action': 'record',
        'email': email.trim().toLowerCase(),
        'success': success,
      });
    } catch (_) {
      // Fire-and-forget.
    }
  }
}

/// The account is locked after repeated failures. [retryAfterSeconds] is the
/// server's authoritative cool-off window.
class LoginLockedException implements Exception {
  final int retryAfterSeconds;
  const LoginLockedException(this.retryAfterSeconds);

  String get message {
    final mins = (retryAfterSeconds / 60).ceil();
    return 'Too many failed attempts. Try again in '
        '${mins <= 1 ? 'a minute' : '$mins minutes'}.';
  }

  @override
  String toString() => message;
}

class CaptchaException implements Exception {
  final String message;

  const CaptchaException(this.message);

  @override
  String toString() => message;
}
