import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_build.dart';

/// What the platform says about the running build.
enum UpdateVerdict {
  /// Nothing to do: this build is the latest the platform knows about.
  ok,

  /// A newer build exists. A dismissible prompt, at most once a day.
  recommended,

  /// This build is below the minimum the platform still accepts and the admin
  /// has turned force on. A full-screen, non-dismissible gate.
  required,
}

/// The platform's release policy, as returned by `app_release_config_for()`.
///
/// Immutable and self-contained so the verdict can be computed in a unit test
/// without a database — see [verdictFor].
@immutable
class AppReleaseConfig {
  const AppReleaseConfig({
    required this.platform,
    required this.latestBuild,
    required this.minRequiredBuild,
    required this.forceEnabled,
    this.storeUrl,
    this.packageId,
    this.messageEn = 'A new version of Aliob is available.',
    this.messageAm,
    this.messageOm,
  });

  final String platform;
  final int latestBuild;
  final int minRequiredBuild;
  final bool forceEnabled;
  final String? storeUrl;
  final String? packageId;
  final String messageEn;
  final String? messageAm;
  final String? messageOm;

  /// The fail-open default: no update required, nothing to show.
  static const AppReleaseConfig open = AppReleaseConfig(
    platform: 'android',
    latestBuild: 0,
    minRequiredBuild: 0,
    forceEnabled: false,
  );

  static AppReleaseConfig fromJson(Map<String, dynamic> json) {
    int asInt(Object? v) => (v as num?)?.toInt() ?? 0;
    bool asBool(Object? v) => v == true || v == 'true';
    String? asText(Object? v) {
      if (v is! String) return null;
      final t = v.trim();
      return t.isEmpty ? null : t;
    }

    return AppReleaseConfig(
      platform: asText(json['platform']) ?? 'android',
      latestBuild: asInt(json['latest_build']),
      minRequiredBuild: asInt(json['min_required_build']),
      forceEnabled: asBool(json['force_enabled']),
      storeUrl: asText(json['store_url']),
      packageId: asText(json['package_id']),
      messageEn:
          asText(json['message_en']) ?? 'A new version of Aliob is available.',
      messageAm: asText(json['message_am']),
      messageOm: asText(json['message_om']),
    );
  }

  Map<String, dynamic> toJson() => {
        'platform': platform,
        'latest_build': latestBuild,
        'min_required_build': minRequiredBuild,
        'force_enabled': forceEnabled,
        'store_url': storeUrl,
        'package_id': packageId,
        'message_en': messageEn,
        'message_am': messageAm,
        'message_om': messageOm,
      };

  /// The verdict for [build]. Pure, so the rule is testable without a network:
  ///
  /// * below the minimum AND force on -> [UpdateVerdict.required]
  /// * below the latest                 -> [UpdateVerdict.recommended]
  /// * otherwise                        -> [UpdateVerdict.ok]
  ///
  /// A config with a zero minimum (no row, or an unreadable one) is always
  /// `ok`: fail OPEN, never gate a user because the policy could not be read.
  UpdateVerdict verdictFor(int build) {
    if (forceEnabled && build < minRequiredBuild) {
      return UpdateVerdict.required;
    }
    if (build < latestBuild) return UpdateVerdict.recommended;
    return UpdateVerdict.ok;
  }

  /// The message for a language code, falling back to English, then to a
  /// built-in sentence. A blank translation is not shown as blank.
  String messageFor(String languageCode) {
    switch (languageCode) {
      case 'am':
        final am = messageAm;
        if (am != null && am.isNotEmpty) return am;
        break;
      case 'om':
      case 'or':
        final om = messageOm;
        if (om != null && om.isNotEmpty) return om;
        break;
    }
    return messageEn.isEmpty
        ? 'A new version of Aliob is available.'
        : messageEn;
  }
}

/// The forced-update client.
///
/// Checks the platform's release policy on cold start, on app resume and
/// periodically; caches the last successful answer to disk so an offline
/// launch still has a policy to evaluate; and fails OPEN on every error, so a
/// user is never locked out because OUR server was unreachable.
///
/// Opening the store is the documented fallback. `startImmediateUpdate()`
/// first asks the native side (a `birr/app_update` channel) to run the Play
/// Core immediate in-app update flow and, when that plugin is not present —
/// which is the case until the Android build adds the Play Core dependency —
/// falls through to the store listing, which is what the update button does
/// today either way.
class AppUpdateService {
  AppUpdateService._();
  static final AppUpdateService instance = AppUpdateService._();

  static const MethodChannel _channel = MethodChannel('birr/app_update');

  /// The last config we hold, from the network or from disk. Never null —
  /// [AppReleaseConfig.open] until something better arrives.
  final ValueNotifier<AppReleaseConfig> config =
      ValueNotifier<AppReleaseConfig>(AppReleaseConfig.open);

  /// Set when the last check actually reached the server. A false here means
  /// the gate is working from cache (or from the open default).
  final ValueNotifier<bool> lastCheckReachedServer = ValueNotifier<bool>(false);

  /// Set when a WRITE was refused with `APP_UPDATE_REQUIRED` — the server's
  /// own verdict that this build is below its minimum. The gate treats this
  /// as [UpdateVerdict.required] regardless of the cached policy, so a refused
  /// write gates the app immediately instead of waiting for the next check.
  final ValueNotifier<bool> serverRefusedThisBuild = ValueNotifier<bool>(false);

  /// Note a failure that may be the server's version refusal. Cheap and safe:
  /// anything that is not that refusal is ignored.
  void notePossibleRefusal(Object error) {
    if (error.toString().toLowerCase().contains('app_update_required')) {
      serverRefusedThisBuild.value = true;
    }
  }

  Timer? _timer;
  bool _checking = false;

  /// The running build. One accessor so every caller — the gate, the refresh
  /// timer, the tests — reads the same number.
  int get buildNumber => kAppBuildNumber;

  /// `android` or `ios`, from the running OS and not from a constant.
  String get platform {
    if (kIsWeb) return 'android';
    return Platform.isIOS ? 'ios' : 'android';
  }

  UpdateVerdict get verdict {
    // The server's direct refusal outranks the cached policy: it is the same
    // authority, but spoken this second rather than read hours ago.
    if (serverRefusedThisBuild.value) return UpdateVerdict.required;
    return config.value.verdictFor(buildNumber);
  }

  /// The message in the device's language.
  String get message {
    final code = PlatformDispatcher.instance.locale.languageCode;
    return config.value.messageFor(code);
  }

  /// Load the cached policy (so the first frame can gate even offline), then
  /// refresh from the server and start the periodic check.
  Future<void> start() async {
    await _loadCache();
    // Fire and forget: the caller is a widget's initState and must not await
    // a network round trip before the app is on screen.
    unawaited(refresh());
    _timer ??= Timer.periodic(const Duration(hours: 6), (_) => refresh());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Re-read the policy. Never throws. On success the answer is cached; on
  /// failure the previous (cached or default) config is kept, which is the
  /// fail-open path.
  Future<void> refresh() async {
    if (_checking) return;
    _checking = true;
    try {
      final res = await Supabase.instance.client
          .rpc('app_release_config_for', params: {'p_platform': platform})
          .timeout(const Duration(seconds: 10));
      final parsed = AppReleaseConfig.fromJson(
        Map<String, dynamic>.from(res as Map),
      );
      config.value = parsed;
      lastCheckReachedServer.value = true;
      await _saveCache(parsed);
    } catch (e) {
      // Offline, RPC missing (a deployment that has not run 20261007000006),
      // or a malformed answer: keep whatever we had and stay open.
      lastCheckReachedServer.value = false;
      debugPrint('AppUpdateService.refresh failed: ${e.runtimeType}');
    } finally {
      _checking = false;
    }
  }

  /// Open the store listing (or run the native immediate update when the
  /// Android build provides one). Returns false when neither worked, so the
  /// gate can say so instead of appearing to do nothing on a tap.
  Future<bool> startImmediateUpdate() async {
    // 1. The Play Core immediate update, when the native side has it.
    try {
      final started = await _channel.invokeMethod<bool>('startImmediateUpdate');
      if (started == true) return true;
    } on MissingPluginException {
      // Expected until the Android build adds the Play Core update flow.
    } catch (_) {}

    // 2. The store listing.
    return openStore();
  }

  /// Open the configured store URL. Falls back to the package id on the Play
  /// Store when no URL is configured.
  Future<bool> openStore() async {
    final c = config.value;
    var url = c.storeUrl;
    if (url == null || url.isEmpty) {
      final pkg = c.packageId;
      url = (pkg == null || pkg.isEmpty)
          ? null
          : 'https://play.google.com/store/apps/details?id=$pkg';
    }
    if (url == null || url.isEmpty) return false;
    try {
      return await launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  // ---- cache -------------------------------------------------------------

  static const _cacheFileName = 'app_release_config.json';

  Future<File?> _cacheFile() async {
    try {
      final dir = await getApplicationSupportDirectory();
      return File('${dir.path}/$_cacheFileName');
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveCache(AppReleaseConfig c) async {
    final f = await _cacheFile();
    if (f == null) return;
    try {
      await f.writeAsString(jsonEncode(c.toJson()));
    } catch (_) {}
  }

  Future<void> _loadCache() async {
    final f = await _cacheFile();
    if (f == null) return;
    try {
      if (!await f.exists()) return;
      final raw = await f.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        config.value = AppReleaseConfig.fromJson(
          Map<String, dynamic>.from(decoded),
        );
      }
    } catch (_) {
      // A corrupt cache is not a reason to gate anyone: stay open.
    }
  }

  /// Test seam: replace the held config without touching the network or disk.
  @visibleForTesting
  void debugSetConfig(AppReleaseConfig c) {
    config.value = c;
  }
}
