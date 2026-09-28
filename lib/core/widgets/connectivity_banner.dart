/// Slim banner for connection problems, shown once at the top of the app.
///
/// WHY ONE BANNER, NOT PER-SCREEN ERRORS
///
/// Connectivity is global: a lift, a tunnel, a dead uplink. When it happens,
/// six screens are all going to fail at once. Six error states would mean
/// six identical red blocks, each replacing content the user could still
/// read. Instead there is one quiet strip at the top, and the screens keep
/// showing whatever they had.
///
/// The banner is also not allowed to interrupt. No blocking dialog, no
/// "retry?" prompt that stops you scrolling. A user in a tunnel should be
/// able to keep reading the ride quote they already have.
///
/// [ConnectivityService] is evidence-driven (see that file), so this appears
/// after a *confirmed* transport failure and clears on a confirmed success —
/// it never guesses and never lies in the reassuring direction.
library;

import 'package:flutter/material.dart';

import '../services/connectivity_service.dart';
import '../theme/app_theme.dart';

/// Wrap the app below the MaterialApp with this.
///
/// ```dart
/// MaterialApp(
///   builder: (context, child) => Column(
///     children: [const ConnectivityBanner(), Expanded(child: child!)],
///   ),
/// )
/// ```
///
/// Safe to place above the Navigator: it is not a route and does not
/// participate in navigation, so it cannot be popped away or stacked.
class ConnectivityBanner extends StatelessWidget {
  const ConnectivityBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ConnectionStatus>(
      valueListenable: ConnectivityService.instance.status,
      builder: (context, status, _) {
        final model = _modelFor(status);
        if (model == null) return const SizedBox.shrink();

        return AnimatedSize(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: Material(
            color: model.color,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                child: Row(
                  children: [
                    SizedBox(
                      width: 13,
                      height: 13,
                      child: model.spinning
                          ? CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation(
                                Colors.white.withOpacity(0.9),
                              ),
                            )
                          : Icon(model.icon,
                              size: 14, color: Colors.white.withOpacity(0.95)),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        model.message,
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          height: 1.3,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  static _BannerModel? _modelFor(ConnectionStatus status) => switch (status) {
        ConnectionStatus.online => null,
        ConnectionStatus.offline => const _BannerModel(
            icon: Icons.wifi_off_rounded,
            message: 'No connection. We\'ll keep trying.',
            color: AppTheme.textPrimary,
            spinning: false,
          ),
        // Reconnecting says so plainly: the network came back but your data
        // has not been re-fetched yet. Claiming success here would be a lie
        // the user can disprove a second later.
        ConnectionStatus.reconnecting => const _BannerModel(
            icon: Icons.sync_rounded,
            message: 'Back online. Refreshing…',
            color: AppTheme.info,
            spinning: true,
          ),
      };
}

class _BannerModel {
  const _BannerModel({
    required this.icon,
    required this.message,
    required this.color,
    required this.spinning,
  });

  final IconData icon;
  final String message;
  final Color color;
  final bool spinning;
}
