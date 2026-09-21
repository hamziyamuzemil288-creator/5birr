import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers/auth_provider.dart';

/// Draggable floating chat bubble, visible on every signed-in screen.
///
/// - Drag to reposition anywhere on screen; clamped inside safe areas and
///   clear of system nav bars.
/// - Position persists for the current app session (in-memory only).
/// - Sits at the top of the global Overlay, above all route content.
/// - Tap opens the in-app help chat at /help.
class FloatingChatOverlay extends ConsumerStatefulWidget {
  const FloatingChatOverlay({super.key, this.child});

  final Widget? child;

  @override
  ConsumerState<FloatingChatOverlay> createState() =>
      _FloatingChatOverlayState();
}

class _FloatingChatOverlayState extends ConsumerState<FloatingChatOverlay> {
  OverlayEntry? _entry;

  @override
  void dispose() {
    _entry?.remove();
    _entry = null;
    super.dispose();
  }

  /// Routes where the bubble must never appear: auth/onboarding/splash
  /// screens, the chat screen itself, and the full-screen live ride map
  /// (chat stays reachable there via Profile → Help & Support).
  bool _visibleFor(BuildContext context) {
    final auth = ref.read(authProvider);
    if (!auth.isAuthenticated || auth.isAdmin) return false;

    final String loc;
    try {
      loc = GoRouter.of(context)
          .routerDelegate
          .currentConfiguration
          .uri
          .toString();
    } catch (_) {
      return false;
    }
    const hiddenExact = {
      '/',
      '/login',
      '/role-select',
      '/admin-login',
      '/terms',
      '/pending-approval',
      '/rejected',
      '/help',
    };
    if (hiddenExact.contains(loc)) return false;
    if (loc.startsWith('/signup')) return false;
    // Live map screens: keep controls unobstructed.
    if (loc.startsWith('/user/ride-active') ||
        loc.startsWith('/vehicle/trip')) {
      return false;
    }
    return true;
  }

  void _syncEntry(BuildContext context) {
    final visible = _visibleFor(context);
    if (visible && _entry == null) {
      final entry = OverlayEntry(builder: (_) => const _DraggableChatBubble());
      _entry = entry;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _entry == entry) {
          Overlay.of(context, rootOverlay: true).insert(entry);
        }
      });
    } else if (!visible && _entry != null) {
      _entry!.remove();
      _entry = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    _syncEntry(context);
    return widget.child ?? const SizedBox.shrink();
  }
}

/// Session-persistent bubble position (survives overlay entry recreation
/// while the app runs; intentionally NOT persisted to disk).
Offset? _lastBubblePosition;

class _DraggableChatBubble extends StatefulWidget {
  const _DraggableChatBubble();

  @override
  State<_DraggableChatBubble> createState() => _DraggableChatBubbleState();
}

class _DraggableChatBubbleState extends State<_DraggableChatBubble> {
  static const double _size = 56;
  static const double _margin = 10;
  static const double _navBarClearance = 24;

  Offset _clamp(Offset pos, double maxWidth, double maxHeight) {
    final maxLeft = maxWidth - _size - _margin;
    final maxTop = maxHeight - _size - _margin - _navBarClearance;
    return Offset(
      pos.dx.clamp(_margin, maxLeft < _margin ? _margin : maxLeft),
      pos.dy.clamp(_margin, maxTop < _margin ? _margin : maxTop),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);

    var pos = _lastBubblePosition ??
        Offset(
          size.width - _size - _margin,
          size.height - _size - _margin - 96,
        );
    pos = _clamp(pos, size.width, size.height);

    return Positioned(
      left: pos.dx,
      top: pos.dy,
      child: GestureDetector(
        onPanUpdate: (d) {
          setState(() {
            _lastBubblePosition =
                _clamp(pos + d.delta, size.width, size.height);
          });
        },
        onTap: () => GoRouter.of(context).push('/help'),
        child: Container(
          width: _size,
          height: _size,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [scheme.primary, scheme.tertiary],
            ),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: scheme.shadow.withValues(alpha: 0.3),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Icon(
            Icons.chat_bubble_rounded,
            color: scheme.onPrimary,
            size: 26,
          ),
        ),
      ),
    );
  }
}
