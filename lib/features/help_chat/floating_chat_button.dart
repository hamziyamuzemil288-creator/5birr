import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers/auth_provider.dart';
import '../../routing/app_router.dart' show appRouterProvider;

/// Draggable floating chat bubble, visible on every signed-in screen.
///
/// Rendered declaratively in a Stack layered above the route content
/// (`MaterialApp.builder` wraps the Router's Navigator), so no imperative
/// Overlay bookkeeping is needed — the bubble simply exists whenever
/// [_visibleFor] says it should.
///
/// - Drag to reposition anywhere on screen; clamped inside safe areas and
///   clear of system nav bars.
/// - Position persists for the current app session (in-memory only).
/// - Tap opens the in-app help chat at /help.
class FloatingChatOverlay extends ConsumerStatefulWidget {
  const FloatingChatOverlay({super.key, this.child});

  final Widget? child;

  @override
  ConsumerState<FloatingChatOverlay> createState() =>
      _FloatingChatOverlayState();
}

class _FloatingChatOverlayState extends ConsumerState<FloatingChatOverlay> {
  /// Routes where the bubble must never appear: auth/onboarding/splash
  /// screens, the chat screen itself, and the full-screen live ride map
  /// (chat stays reachable there via Profile → Help & Support).
  bool _visibleFor(GoRouter router, AuthState auth) {
    if (!auth.isAuthenticated || auth.isAdmin) return false;

    String loc;
    try {
      // The builder's context sits ABOVE the Router widget, so Inherited
      // lookups (GoRouter.of) fail here. Use the router instance directly —
      // its delegate's current match list is the same source of truth.
      loc = router.routerDelegate.currentConfiguration.uri.toString();
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

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(appRouterProvider);
    final auth = ref.watch(authProvider);

    return Stack(
      children: [
        // The MaterialApp's entire content (Router → Navigator → page).
        // Keyed by the router so the element survives page transitions
        // without being rebuilt from scratch.
        KeyedSubtree(
          key: ValueKey(router.hashCode),
          child: widget.child ?? const SizedBox.shrink(),
        ),
        if (_visibleFor(router, auth)) const _DraggableChatBubble(),
      ],
    );
  }
}

/// Session-persistent bubble position (survives overlay entry recreation
/// while the app runs; intentionally NOT persisted to disk).
Offset? _lastBubblePosition;

class _DraggableChatBubble extends ConsumerStatefulWidget {
  const _DraggableChatBubble();

  @override
  ConsumerState<_DraggableChatBubble> createState() =>
      _DraggableChatBubbleState();
}

class _DraggableChatBubbleState extends ConsumerState<_DraggableChatBubble> {
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
        onTap: () {
          // This bubble is rendered in MaterialApp.builder, ABOVE the
          // Router — GoRouter.of(context) cannot resolve from here (no
          // Router widget above this context). Push via the router
          // instance itself, the same source _visibleFor uses.
          ref.read(appRouterProvider).push('/help');
        },
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
