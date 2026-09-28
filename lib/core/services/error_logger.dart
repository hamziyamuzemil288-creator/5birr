/// Ships app crashes and handled failures to the `client_error_logs` table so
/// the CEO can see what actually breaks on real phones.
///
/// ## Why this is a singleton rather than a Riverpod provider
///
/// It is called from `FlutterError.onError` and
/// `PlatformDispatcher.instance.onError` in `main()`, which run before and
/// outside the provider tree. A provider could not be read from there.
///
/// ## Why nothing is ever awaited on the failure path
///
/// Every call here is fire-and-forget. When the app is crashing, the network
/// is usually the thing that just failed, and a logger that can itself throw
/// turns a degraded app into a loop. Every call is additionally wrapped so a
/// failure to log can never escape.
///
/// ## Log-flood protection
///
/// A crash in a `build()` method fires once per frame — potentially 60 times
/// a second — which would turn one bug into tens of thousands of rows and
/// lock the user out of their own app. Three guards, in order of cost:
/// identical fingerprints are deduped, a hard per-session cap applies, and
/// the per-key cooldown stops a repeating message being re-sent every minute.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A single reportable error.
class ClientErrorReport {
  const ClientErrorReport({
    required this.message,
    this.stackTrace,
    this.source = 'app',
    this.context,
    this.isFatal = false,
  });

  final String message;
  final String? stackTrace;

  /// Where it came from: 'flutter_error', 'platform_error', 'screen', 'rpc'…
  final String source;

  /// Free-form context (screen name, action). Never user data.
  final Map<String, Object?>? context;

  final bool isFatal;
}

class ErrorLogger {
  ErrorLogger._();

  static final ErrorLogger instance = ErrorLogger._();

  /// Hard cap per app session. Even a genuine crash loop stops here.
  static const int _maxPerSession = 20;

  int _sentThisSession = 0;

  /// fingerprint -> last time we sent it.
  final Map<String, DateTime> _lastSent = {};

  /// Identical errors repeat forever within the cooldown window.
  static const Duration _dedupeWindow = Duration(minutes: 5);

  /// Stack traces are the useful part and also the bulk. Truncated so one
  /// pathological recursive error cannot produce a 5 MB row.
  static const int _maxStackChars = 4000;

  /// Message cap for the same reason.
  static const int _maxMessageChars = 500;

  bool get hasLoggedThisSession => _sentThisSession > 0;

  /// Convenience for the common call site: a caught [error] and its [stack].
  ///
  /// The overwhelming majority of call sites are "I already have an exception
  /// object, just log it" — forcing each one to unpack it into a
  /// [ClientErrorReport] by hand is how call sites end up omitting the source
  /// or the context, which is exactly the information that makes a log row
  /// useful.
  void logError(
    Object error,
    StackTrace? stack, {
    String source = 'app',
    String? context,
    Map<String, Object?>? details,
    bool isFatal = false,
  }) {
    log(ClientErrorReport(
      message: error.toString(),
      stackTrace: stack?.toString(),
      source: source,
      context: details == null && context == null
          ? null
          : {...?details, if (context != null) 'where': context},
      isFatal: isFatal,
    ));
  }

  /// Queue a report. Never throws, never blocks.
  void log(ClientErrorReport report) {
    try {
      if (_sentThisSession >= _maxPerSession) return;

      final message = _clip(report.message, _maxMessageChars);
      final fingerprint = _fingerprint(report.source, message);
      final now = DateTime.now();
      final last = _lastSent[fingerprint];
      if (last != null && now.difference(last) < _dedupeWindow) return;
      _lastSent[fingerprint] = now;
      _sentThisSession++;

      unawaited(_send(report, message, fingerprint));
    } catch (_) {
      // Logging must never be the reason the app fails.
    }
  }

  Future<void> _send(ClientErrorReport report, String message, String fingerprint) async {
    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;

      await client.from('client_error_logs').insert({
        'user_id': userId,
        'error_source': report.source,
        'error_message': message,
        'stack_trace': report.stackTrace == null
            ? null
            : _clip(report.stackTrace!, _maxStackChars),
        'error_context': report.context == null
            ? null
            : jsonEncode(_sanitise(report.context!)),
        'is_fatal': report.isFatal,
        'fingerprint': fingerprint,
      });
    } catch (_) {
      // Swallowed on purpose. See the library docs: the most likely reason
      // this failed is the outage we are reporting.
    }
  }

  /// Strip anything that could carry personal data out of the context map.
  ///
  /// Context is developer-supplied, but "log this screen's state" is an easy
  /// thing to write and a phone number in a log row is a privacy incident.
  static Map<String, Object?> _sanitise(Map<String, Object?> input) {
    const blocked = {'email', 'phone', 'password', 'token', 'otp', 'address', 'full_name'};
    final out = <String, Object?>{};
    input.forEach((key, value) {
      if (blocked.contains(key.toLowerCase())) {
        out[key] = '[redacted]';
      } else if (value is num || value is bool || value == null) {
        out[key] = value;
      } else {
        final s = value.toString();
        out[key] = s.length > 200 ? '${s.substring(0, 200)}…' : s;
      }
    });
    return out;
  }

  /// Stable identity for dedupe: source plus the first line of the message.
  ///
  /// Deliberately NOT the stack trace. A crash inside a list rebuild produces
  /// a different stack every frame but the same message, and including the
  /// stack would defeat the dedupe entirely.
  static String _fingerprint(String source, String message) {
    final firstLine = message.split('\n').first.trim();
    final basis = firstLine.length > 120 ? firstLine.substring(0, 120) : firstLine;
    return '$source|$basis';
  }

  static String _clip(String s, int max) => s.length <= max ? s : '${s.substring(0, max)}…';

  /// Visible in debug builds only. In production the user's own screen is the
  /// feedback mechanism and a console dump on a release build helps nobody.
  void logDebug(ClientErrorReport report) {
    if (kDebugMode) {
      debugPrint('[ErrorLogger] ${report.source}: ${report.message}');
    }
  }
}
