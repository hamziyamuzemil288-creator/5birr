/// The one-time "turn on location" prompt, and the wording for every
/// location state.
///
/// ## The bug this exists to fix
///
/// With phone location off, the app said **"you are offline"**. It is not:
/// the phone is on a perfectly good network and the GPS radio is off. The
/// user is told their internet is broken, they go and troubleshoot the
/// router, and nothing changes. The same confusion runs the other way — a
/// user with no data connection but location on is told location is off.
///
/// Connectivity and location are two independent facts and each has to be
/// reported in its own words. [LocationPrompt] never says "offline"; the
/// connectivity layer never mentions GPS.
///
/// ## Why it is asked ONCE
///
/// A permission prompt that reappears every time someone toggles a switch
/// is a prompt people learn to dismiss without reading, which is worse than
/// not asking. So the choice is remembered for the session, the user may
/// still go available without a fix, and a small persistent hint replaces
/// the dialog. It is re-asked only when they deliberately change their mind
/// by toggling availability again — at which point they are choosing to
/// receive rides, and the location question is on point.
library;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'location_service.dart';

/// Accurately worded copy for each location state.
///
/// Every string names the actual problem. None of them say "offline", and
/// none say "internet" — those words belong to a different failure and
/// sending a user to the wrong setting is the whole problem.
class LocationMessages {
  const LocationMessages._();

  static const serviceDisabled =
      'Location is off. Turn on location services to get nearby requests.';

  static const denied =
      'Location permission is needed to show your position on the map.';

  static const deniedForever =
      'Location permission is blocked. Allow it in Settings to use live '
      'location.';

  static const error =
      'We could not read your location. Please try again.';

  static const timeout =
      'Location is taking too long. Move somewhere with a clearer view of '
      'the sky and try again.';

  /// The plain sentence for a status, used by snackbars and inline hints.
  static String forStatus(LocationStatus status) => switch (status) {
        LocationStatus.ready => 'Location is on.',
        LocationStatus.serviceDisabled => serviceDisabled,
        LocationStatus.denied => denied,
        LocationStatus.deniedForever => deniedForever,
        LocationStatus.error => error,
      };

  /// True when the user can fix this by opening the OS settings screen,
  /// as opposed to one they can retry in place.
  static bool needsSettings(LocationStatus status) =>
      status == LocationStatus.serviceDisabled ||
      status == LocationStatus.deniedForever;
}

/// Remembers whether the prompt has been shown, for this app session.
///
/// Deliberately in-memory rather than persisted, and that is the requirement
/// rather than a shortcut: the brief is "do not ask again this session".
/// Persisting it would mean a driver who said "Not now" in March is never
/// asked again, which is a different and worse product — the one person who
/// most needs the explanation is the one who has already declined it.
///
/// In-memory also avoids adding a dependency for one boolean. The cost is
/// that a cold start re-arms the offer, which is the correct behaviour.
class LocationPrompt {
  LocationPrompt._();

  static final LocationPrompt instance = LocationPrompt._();

  /// True once the user has answered, in either direction, this session.
  bool _answered = false;

  bool get answered => _answered;

  /// Re-arms the offer. Called when a driver deliberately toggles
  /// availability again — that is the moment the question is on point, and
  /// the brief asks for exactly this re-ask.
  void rearm() => _answered = false;

  /// Offers location once, returning true if the user chose to turn it on.
  ///
  /// Returns false without showing anything if the offer was already
  /// answered this session, so a call site can invoke it unconditionally
  /// before every availability toggle.
  ///
  /// "Not now" is a real answer, not a dismissal: it records the choice and
  /// the caller lets the user proceed with a hint instead of a dialog.
  static Future<bool> offerOnce(
    BuildContext context, {
    required String reason,
    String? title,
  }) async {
    if (instance._answered) return false;

    final answer = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.location_on_outlined,
            color: AppTheme.primaryGreen, size: 30),
        title: Text(title ?? 'Turn on location?'),
        content: Text(reason, style: const TextStyle(height: 1.45)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.my_location, size: 17),
            label: const Text('Turn on'),
          ),
        ],
      ),
    );

    instance._answered = true;
    return answer ?? false;
  }
}

/// A small, persistent, non-blocking hint for someone who chose "Not now".
///
/// Deliberately not a dialog and not a snackbar: a snackbar disappears and
/// the driver then wonders why no requests arrive. This stays, says why,
/// and offers both the fix and a way to be asked again.
class LocationHintBar extends StatelessWidget {
  const LocationHintBar({
    super.key,
    required this.status,
    this.onOpenSettings,
    this.onDismiss,
  });

  final LocationStatus status;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final needsSettings = LocationMessages.needsSettings(status);
    return Material(
      color: AppTheme.gold.withOpacity(0.14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 9, 8, 9),
        child: Row(
          children: [
            const Icon(Icons.location_off_outlined,
                size: 16, color: AppTheme.textSecondary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                LocationMessages.forStatus(status),
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.35,
                  color: AppTheme.textSecondary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (onOpenSettings != null)
              TextButton(
                onPressed: onOpenSettings,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: Text(needsSettings ? 'Settings' : 'Retry'),
              ),
            if (onDismiss != null)
              IconButton(
                onPressed: onDismiss,
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, color: AppTheme.textMuted),
              ),
          ],
        ),
      ),
    );
  }
}
