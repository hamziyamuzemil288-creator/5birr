import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../services/app_update_service.dart';
import '../theme/app_theme.dart';

/// The forced-update gate.
///
/// Mounted in `MaterialApp.router`'s `builder`, which runs ABOVE the Navigator
/// — the same place the connectivity banner lives — so it is not a route: it
/// cannot be popped, cannot be covered by a pushed screen, and shows over
/// every route including `/auth`. That is deliberate: a build below the
/// minimum must be told to update before it can sign in, or the user reaches a
/// login form whose writes the server will reject.
///
/// Two behaviours, one widget:
///
/// * [UpdateVerdict.required] — a full-screen, non-dismissible gate. Back is
///   disabled ([PopScope] with `canPop: false`), there is no X, and the only
///   button runs the update. It covers the app; it is not a dialog over it.
/// * [UpdateVerdict.recommended] — a dismissible prompt, at most once a day.
///   The date it was dismissed is remembered on disk, so closing it does not
///   require seeing it again on the next launch.
///
/// Fail-open: the verdict comes from [AppUpdateService], which keeps its last
/// known policy (or the open default) when the server is unreachable, so a
/// user is never locked out because our policy could not be read.
class AppUpdateGate extends StatefulWidget {
  const AppUpdateGate({super.key, required this.child});

  final Widget child;

  @override
  State<AppUpdateGate> createState() => _AppUpdateGateState();
}

class _AppUpdateGateState extends State<AppUpdateGate>
    with WidgetsBindingObserver {
  bool _updating = false;
  bool _storeFailed = false;
  /// The yyyy-MM-dd the recommended prompt was dismissed, or null.
  String? _dismissedOn;
  bool _promptShownThisSession = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppUpdateService.instance.config.addListener(_onChanged);
    AppUpdateService.instance.lastCheckReachedServer.addListener(_onChanged);
    AppUpdateService.instance.serverRefusedThisBuild.addListener(_onChanged);
    unawaited(_dismissedLoad().then((_) => AppUpdateService.instance.start()));
  }

  @override
  void dispose() {
    AppUpdateService.instance.config.removeListener(_onChanged);
    AppUpdateService.instance.lastCheckReachedServer.removeListener(_onChanged);
    AppUpdateService.instance.serverRefusedThisBuild.removeListener(_onChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Resume is one of the three moments the spec asks for, alongside cold
    // start and the periodic timer the service owns.
    if (state == AppLifecycleState.resumed) {
      unawaited(AppUpdateService.instance.refresh());
    }
  }

  Future<void> _runUpdate() async {
    if (_updating) return;
    setState(() {
      _updating = true;
      _storeFailed = false;
    });
    final ok = await AppUpdateService.instance.startImmediateUpdate();
    if (!mounted) return;
    setState(() {
      _updating = false;
      // Only a failure needs a message; success has left the app for the store.
      _storeFailed = !ok;
    });
  }

  Future<void> _dismissRecommended() async {
    final today = _today();
    setState(() {
      _dismissedOn = today;
      _promptShownThisSession = true;
    });
    await _dismissedSave(today);
  }

  static String _today() {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  Future<File?> _dismissFile() async {
    try {
      final dir = await getApplicationSupportDirectory();
      return File('${dir.path}/app_update_prompt.json');
    } catch (_) {
      return null;
    }
  }

  Future<void> _dismissedLoad() async {
    final f = await _dismissFile();
    if (f == null) return;
    try {
      if (!await f.exists()) return;
      final decoded = jsonDecode(await f.readAsString());
      if (decoded is Map && decoded['dismissed_on'] is String) {
        _dismissedOn = decoded['dismissed_on'] as String;
      }
    } catch (_) {}
  }

  Future<void> _dismissedSave(String day) async {
    final f = await _dismissFile();
    if (f == null) return;
    try {
      await f.writeAsString(jsonEncode({'dismissed_on': day}));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final service = AppUpdateService.instance;
    final verdict = service.verdict;

    if (verdict == UpdateVerdict.required) {
      return _RequiredUpdateScreen(
        message: service.message,
        updating: _updating,
        storeFailed: _storeFailed,
        onUpdate: _runUpdate,
      );
    }

    // The dismissible prompt, at most once a day. Shown as a post-frame dialog
    // so it never runs during a build.
    if (verdict == UpdateVerdict.recommended &&
        !_promptShownThisSession &&
        _dismissedOn != _today()) {
      _promptShownThisSession = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showRecommendedDialog(service.message);
      });
    }

    return widget.child;
  }

  Future<void> _showRecommendedDialog(String message) async {
    if (!mounted) return;
    final update = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Update available'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style:
                FilledButton.styleFrom(backgroundColor: AppTheme.primaryGreen),
            child: const Text('Update'),
          ),
        ],
      ),
    );
    if (update == true) {
      await _runUpdate();
    } else {
      // "Later" is a dismissal and must be remembered, or the prompt would
      // reappear on every rebuild. Once a day is the whole contract.
      await _dismissRecommended();
    }
  }
}

/// The non-dismissible screen. Deliberately a full `Scaffold` that replaces the
/// app rather than an overlay, so nothing behind it is reachable, and wrapped
/// in a [PopScope] that refuses the system back gesture.
class _RequiredUpdateScreen extends StatelessWidget {
  const _RequiredUpdateScreen({
    required this.message,
    required this.updating,
    required this.storeFailed,
    required this.onUpdate,
  });

  final String message;
  final bool updating;
  final bool storeFailed;
  final VoidCallback onUpdate;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // The whole point: back, swipe-back and any dismissal gesture do
      // nothing. The only way past this screen is to update.
      canPop: false,
      child: Scaffold(
        backgroundColor: AppTheme.cream,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      color: AppTheme.primaryGreen.withOpacity(0.10),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.system_update_alt_rounded,
                        size: 44, color: AppTheme.primaryGreen),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Update required',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 14.5,
                      height: 1.55,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 28),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: updating ? null : onUpdate,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.primaryGreen,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 15),
                      ),
                      icon: updating
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.download_rounded, size: 20),
                      label: Text(updating ? 'Opening…' : 'Update now'),
                    ),
                  ),
                  if (storeFailed) ...[
                    const SizedBox(height: 14),
                    const Text(
                      'We could not open the store. Open the Play Store and '
                      'search for Aliob to update, then come back.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.45,
                        color: AppTheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  const Text(
                    'Your data and sign-in are kept.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
