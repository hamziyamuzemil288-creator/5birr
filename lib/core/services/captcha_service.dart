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

class CaptchaException implements Exception {
  final String message;

  const CaptchaException(this.message);

  @override
  String toString() => message;
}
