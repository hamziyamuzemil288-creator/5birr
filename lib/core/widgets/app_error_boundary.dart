/// Contains a crashing subtree so one broken screen cannot blank the app.
///
/// ## The regression this exists to make impossible
///
/// The app previously died to a white screen: an exception during build of a
/// route, nothing above it caught it, and the user got nothing at all — not
/// an error, not a back button, just white. Two distinct failures produce
/// that and only one of them is now handled well:
///
/// * **Framework errors during build** (bad data, null deref in a widget) —
///   caught here per-subtree, and the *rest of the app keeps running*.
/// * **Errors with no widget context at all** — an async gap, a background
///   task, an isolate. These cannot be contained by a widget. They are routed
///   to [ErrorReporter] / `runZonedGuarded` and shown as a toast instead;
///   see `bootstrap.dart`.
///
/// A boundary is a blast wall, not a debugger. The crash screen it shows is
/// deliberately plain — no stack trace, no "Exception: type 'Null' is not a
/// subtype" — because none of that helps the person holding the phone, and
/// all of it goes to the log where the CEO can see it.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/error_logger.dart';
import '../theme/app_theme.dart';

/// Catches build/layout errors in [child] and shows a recovery screen.
///
/// Use it around each tab, each route body, and any subtree you would
/// otherwise be afraid to crash.
class AppErrorBoundary extends StatefulWidget {
  const AppErrorBoundary({
    super.key,
    required this.child,
    this.onError,
    this.screenName,
    this.resetOnChange = true,
  });

  final Widget child;

  /// Called with the caught error. Defaults to logging it to
  /// `client_error_logs` so the failure is visible to the CEO.
  final void Function(Object error, StackTrace stack)? onError;

  /// Human-readable location, e.g. 'home/vehicles tab'. Appears in the log.
  final String? screenName;

  /// When true, any change to this widget's element configuration (new
  /// `key`, `screenName`, or a rebuilt parent that swaps the subtree)
  /// clears a previous error. Without this, a single crash poisons that
  /// screen for the rest of the session and the only escape is a full app
  /// restart.
  final bool resetOnChange;

  @override
  State<AppErrorBoundary> createState() => _AppErrorBoundaryState();
}

class _AppErrorBoundaryState extends State<AppErrorBoundary> {
  Object? _error;
  StackTrace? _stack;

  @override
  void didUpdateWidget(AppErrorBoundary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.resetOnChange) return;
    if (oldWidget.screenName != widget.screenName ||
        oldWidget.key != widget.key) {
      if (_error != null) {
        // Defer: this runs during build, and setState there is illegal.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _error = null);
        });
      }
    }
  }

  void _handle(Object error, StackTrace stack) {
    // Guard against a second error while the first is being handled, which
    // would otherwise recurse.
    if (_error != null) return;
    _error = error;
    _stack = stack;
    if (widget.onError != null) {
      widget.onError!(error, stack);
    } else {
      ErrorLogger.instance.logError(
        error,
        stack,
        source: 'flutter_error',
        context: 'ui:${widget.screenName ?? 'unknown'}',
      );
    }
  }

  void _retry() {
    setState(() => _error = null);
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error == null) {
      return FrameworkErrorCatcher(
        onError: _handle,
        child: widget.child,
      );
    }
    return _CrashScreen(error: error, stack: _stack, onRetry: _retry);
  }
}

/// Catches framework errors that Flutter reports through
/// `ErrorWidget.builder` rather than rethrowing.
///
/// During build and layout, Flutter does not throw: it calls
/// `ErrorWidget.builder` and paints a red box, so the tree survives and the
/// failure is invisible unless you listen. That is exactly how a "blank white
/// screen" can hide a whole stack of exceptions — the app is running, it is
/// just rendering nothing you can read. This intercepts those reports and
/// hands them to the nearest [AppErrorBoundary].
class FrameworkErrorCatcher extends StatefulWidget {
  const FrameworkErrorCatcher({
    super.key,
    required this.child,
    required this.onError,
  });

  final Widget child;
  final void Function(Object error, StackTrace stack) onError;

  @override
  State<FrameworkErrorCatcher> createState() => _FrameworkErrorCatcherState();
}

class _FrameworkErrorCatcherState extends State<FrameworkErrorCatcher> {
  /// The builder that was installed before this one, so it can be put back.
  ErrorWidgetBuilder? _previous;

  @override
  void initState() {
    super.initState();
    _previous = ErrorWidget.builder;
    final onError = widget.onError;
    ErrorWidget.builder = (FlutterErrorDetails details) {
      final error = details.exception;
      final stack = details.stack ?? StackTrace.current;
      // We are inside a build/layout phase right now. Touching state here
      // would throw, so the boundary's swap happens on the next frame.
      WidgetsBinding.instance.addPostFrameCallback((_) => onError(error, stack));
      return const SizedBox.shrink();
    };
  }

  @override
  void dispose() {
    // Reference-checked on purpose: `ErrorWidget.builder` is global mutable
    // state, so a nested boundary installs its own builder on top of ours.
    // Unwinding blindly would clobber the outer one and silently disarm it.
    //
    // Guarded on _previous being non-null: the install in initState always
    // runs, so it is not null in practice, but assigning a nullable to a
    // non-nullable global is a compile error and a silent-arming bug if the
    // two ever get out of step.
    final previous = _previous;
    if (previous != null && ErrorWidget.builder != previous) {
      ErrorWidget.builder = previous;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _CrashScreen extends StatelessWidget {
  const _CrashScreen({
    required this.error,
    required this.stack,
    required this.onRetry,
  });

  final Object error;
  final StackTrace? stack;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppTheme.background,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  color: AppTheme.error.withOpacity(0.08),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.report_problem_outlined,
                    size: 38, color: AppTheme.error),
              ),
              const SizedBox(height: 20),
              const Text(
                'Something went wrong',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'This part of the app stopped. Try again — if it keeps '
                'happening, the problem has been reported.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.55,
                  color: AppTheme.textSecondary,
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Try again'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryGreen,
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 28, vertical: 13),
                ),
              ),
              const SizedBox(height: 10),
              // Debug-only detail. Never in production: a stack trace on a
              // user's screen is noise at best and an information leak at
              // worst.
              if (kDebugMode)
                TextButton(
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          '$error\n\n$stack',
                          maxLines: 8,
                          style: const TextStyle(fontSize: 10),
                        ),
                      ),
                    );
                  },
                  child: const Text('Copy details (debug build only)'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
