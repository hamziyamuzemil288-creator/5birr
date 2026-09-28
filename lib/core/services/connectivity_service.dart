/// Global connectivity awareness.
///
/// A phone on a lift loses its connection constantly. The app's job is not
/// to prevent that but to stop *punishing* it: show a slim, quiet banner
/// rather than an error screen, and refresh what the user was looking at the
/// moment the connection returns.
///
/// ## Why this is evidence-driven, not plugin-driven
///
/// `connectivity_plus` reports whether a network *interface* exists. It
/// answers "is Wi-Fi on", not "can we reach the internet" — a captive portal
/// or a dead uplink behind a connected interface both look fine, and a
/// plugin-driven banner would sit there saying "you're online" while every
/// request fails. It is also a dependency this project does not otherwise
/// carry.
///
/// So the signal here is the one that actually matters: [reportRequestFailed]
/// and [reportRequestSucceeded] are called from the retry helper, which sees
/// every real response. The banner therefore appears on a confirmed failure
/// and clears on a confirmed success, and never lies in either direction.
///
/// Nothing is ever *blocked* on this. It is a hint to the user and a trigger
/// for a refetch, never a gate — a wrong answer here must not be able to
/// stop someone using the app.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

/// Coarse connection state shown in the banner.
enum ConnectionStatus {
  /// Working, or not yet measured. Starts here on purpose: a user should
  /// never be greeted with a banner about a problem we have not confirmed.
  online,

  /// At least one real request has failed in a transport way and nothing has
  /// succeeded since.
  offline,

  /// A request has succeeded again, but the screen that was showing stale
  /// data has not yet refreshed. Deliberately not cleared automatically — the
  /// honest statement is "we have not yet restored your data".
  reconnecting,
}

/// Broadcasts connectivity changes for the whole app.
///
/// Deliberately not a Riverpod provider: it has to be listenable from
/// `main()` before the widget tree exists, and from widgets deep in the
/// tree. A single [ValueNotifier] is simpler and cheaper here.
class ConnectivityService {
  ConnectivityService();

  static final ConnectivityService instance = ConnectivityService();

  final ValueNotifier<ConnectionStatus> status =
      ValueNotifier<ConnectionStatus>(ConnectionStatus.online);

  final StreamController<void> _reconnected = StreamController<void>.broadcast();

  /// Fires once per outage, when a request succeeds again. Screens listen to
  /// refetch.
  Stream<void> get onReconnected => _reconnected.stream;

  /// Consecutive transport failures. Exposed for tests and for deciding how
  /// loudly to complain: one blip is not an outage.
  int _consecutiveFailures = 0;

  /// Failures required before the banner appears. Two, because a single
  /// failed request on mobile is routine — a tunnel, a lift, a handover — and
  /// flashing a banner for it is worse than staying quiet.
  static const int _failureThreshold = 2;

  int get consecutiveFailures => _consecutiveFailures;

  bool get isOffline => status.value == ConnectionStatus.online ? false : true;

  /// A real request came back successfully.
  void reportRequestSucceeded() {
    _consecutiveFailures = 0;
    if (status.value == ConnectionStatus.online) return;
    _set(ConnectionStatus.reconnecting);
    if (!_reconnected.isClosed) _reconnected.add(null);
  }

  /// A real request failed in a transport way (network/timeout/server busy).
  ///
  /// Business failures must not call this: a validation error means the
  /// connection is fine, and treating it as an outage would put a banner over
  /// the screen while the user is simply being told their input was wrong.
  void reportRequestFailed() {
    _consecutiveFailures++;
    if (_consecutiveFailures >= _failureThreshold) {
      _set(ConnectionStatus.offline);
    }
  }

  /// Called by a screen once it has actually refetched after [onReconnected],
  /// so the banner can clear.
  void reportRefreshed() {
    _consecutiveFailures = 0;
    _set(ConnectionStatus.online);
  }

  void _set(ConnectionStatus next) {
    if (status.value == next) return;
    status.value = next;
  }

  Future<void> dispose() async {
    await _reconnected.close();
  }
}
