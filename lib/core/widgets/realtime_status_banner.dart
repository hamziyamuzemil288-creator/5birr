import 'package:flutter/material.dart';

import '../services/resilient_subscription.dart';
import '../theme/app_theme.dart';

/// AppBar host for [RealtimeStatusBanner]. Slotted into `AppBar.bottom` so a
/// screen can surface its live-feed state without having to restructure its
/// body widget (these screens build via long ternaries).
class RealtimeStatusBar extends StatelessWidget implements PreferredSizeWidget {
  const RealtimeStatusBar({super.key, required this.state});

  final RealtimeConnState state;

  @override
  Size get preferredSize => const Size.fromHeight(38);

  @override
  Widget build(BuildContext context) {
    final child = RealtimeStatusBanner(state: state);
    // While live/connecting the banner collapses to zero height, so the AppBar
    // must collapse too or it leaves a permanent empty strip.
    final visible = state == RealtimeConnState.retrying ||
        state == RealtimeConnState.offline;
    return SizedBox(
      height: visible ? 38 : 0,
      child: child,
    );
  }
}

/// A quiet, non-blocking strip that reports realtime connection state.
///
/// Shows nothing while [state] is live or still connecting on the first
/// attempt — the screen is usable, so there is no reason to interrupt it.
/// Only a retry or a give-up is worth telling the user about, because both
/// mean the data on screen may be stale. Never modal, never full-screen:
/// losing a realtime feed is a degradation, not a crash.
class RealtimeStatusBanner extends StatelessWidget {
  const RealtimeStatusBanner({super.key, required this.state});

  final RealtimeConnState state;

  @override
  Widget build(BuildContext context) {
    final String message;
    final Color color;
    switch (state) {
      case RealtimeConnState.retrying:
        message = 'Reconnecting to live updates…';
        color = AppTheme.gold;
      case RealtimeConnState.offline:
        message = 'Live updates paused. Pull to refresh.';
        color = AppTheme.error;
      case RealtimeConnState.connecting:
      case RealtimeConnState.live:
        return const SizedBox.shrink();
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 12, color: color),
            ),
          ),
        ],
      ),
    );
  }
}
