import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:realtime_client/realtime_client.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../../core/providers/auth_provider.dart' as auth_state;
import '../../core/services/staff_gateway_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';

class StaffDashboardScreen extends ConsumerStatefulWidget {
  const StaffDashboardScreen({super.key});

  @override
  ConsumerState<StaffDashboardScreen> createState() => _StaffDashboardScreenState();
}

class _StaffDashboardScreenState extends ConsumerState<StaffDashboardScreen> {
  final _service = const StaffGatewayService();
  List<Map<String, dynamic>> _tasks = [];
  Map<String, dynamic> _progress = const {};
  List<String> _permissions = const [];
  List<Map<String, dynamic>> _warnings = [];
  Map<String, dynamic>? _record;
  bool _loading = true;
  String? _error;

  /// Live task updates. Held so dispose() can cancel it — a channel that
  /// outlives its State keeps calling setState on a dead widget, and this
  /// screen is one people leave open all day.
  RealtimeChannel? _channel;

  /// Guards the re-fetch storm: a single approval decision can fire several
  /// postgres_changes events, and each one would otherwise start its own
  /// request.
  bool _refreshing = false;
  Timer? _coalesce;

  @override
  void initState() {
    super.initState();
    _load();
    _listen();
  }

  @override
  void dispose() {
    _coalesce?.cancel();
    final channel = _channel;
    if (channel != null) {
      Supabase.instance.client.removeChannel(channel);
    }
    _channel = null;
    super.dispose();
  }

  /// Subscribe to every table behind the task feed.
  ///
  /// The feed was a snapshot loaded once in initState with a manual refresh
  /// button, so work arriving in a staff member's queue was invisible until
  /// they thought to pull — on the one screen whose entire job is to tell them
  /// what to work on.
  Future<void> _listen() async {
    final channel = _service.subscribeToTaskFeed(_onFeedChanged);
    _channel = channel;
    await channel.subscribe();
  }

  /// Coalesce bursts into one re-read. Several of the five source tables are
  /// written inside a single transaction by the admin RPCs, so one decision
  /// arrives as several events within milliseconds.
  void _onFeedChanged() {
    _coalesce?.cancel();
    _coalesce = Timer(const Duration(milliseconds: 400), _refreshQuietly);
  }

  Future<void> _refreshQuietly() async {
    if (_refreshing || !mounted) return;
    _refreshing = true;
    try {
      await _load(silent: true);
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _load({bool silent = false}) async {
    try {
      final results = await Future.wait<dynamic>([
        _service.taskFeed(),
        _service.progress(),
        Supabase.instance.client.rpc('my_admin_permissions'),
        _service.myWarnings(),
        _service.myRecord(),
      ]);
      if (!mounted) return;
      setState(() {
        _tasks = (results[0] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        _progress = Map<String, dynamic>.from(results[1] as Map);
        _permissions = ((results[2] as List?) ?? const [])
            .map((e) => e.toString())
            .toList();
        _warnings = (results[3] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        _record = results[4] as Map<String, dynamic>?;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      // A silent re-read must never replace a good list with an error screen:
      // a realtime blip while somebody is watching their queue should leave
      // the last known state alone.
      if (!mounted || silent) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e, context: 'Could not load your tasks');
      });
    }
  }

  List<Map<String, dynamic>> get _pending => _tasks
      .where((task) => task['is_completed'] != true)
      .toList();
  List<Map<String, dynamic>> get _completed => _tasks
      .where((task) => task['is_completed'] == true)
      .toList();

  Future<void> _markDone(Map<String, dynamic> task) async {
    try {
      await _service.markDone(task['task_key'] as String);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_friendlyError(e.toString()))),
        );
      }
    }
  }

  String _friendlyError(String raw) {
    if (raw.contains('TASK_MUST_REACH_TERMINAL_STATE_FIRST')) {
      return 'Complete the work item first, then mark it done.';
    }
    if (raw.contains('TASK_NOT_FOUND')) {
      return 'This task is no longer available.';
    }
    return 'Could not update this task.';
  }

  void _openTask(Map<String, dynamic> task) {
    final route = task['action_route'] as String?;
    if (route == null || route.isEmpty) return;
    context.push(route);
  }

  Future<void> _changePassword() async {
    final current = TextEditingController();
    final next = TextEditingController();
    final confirm = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Change staff password'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: current,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Current password'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: next,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'New password'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: confirm,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Confirm new password'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Change password'),
          ),
        ],
      ),
    );
    if (ok == true) {
      if (next.text != confirm.text || next.text.length < 10) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('New passwords must match and be at least 10 characters.')),
          );
        }
        return;
      }
      try {
        await _service.changePassword(
          currentPassword: current.text,
          newPassword: next.text,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Password changed.')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_friendlyError(e.toString()))),
          );
        }
      }
    }
    current.dispose();
    next.dispose();
    confirm.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(auth_state.authProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Staff workspace'),
        actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'password') _changePassword();
              if (value == 'logout') {
                ref.read(auth_state.authProvider.notifier).signOut();
                context.go('/staff/login');
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'password', child: Text('Change password')),
              PopupMenuItem(value: 'logout', child: Text('Sign out')),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!, textAlign: TextAlign.center),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _welcome(auth),
                      if (_record != null) ...[
                        const SizedBox(height: 16),
                        _myJobsCard(),
                      ],
                      if (_warnings.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        _warningsCard(),
                      ],
                      const SizedBox(height: 16),
                      _metrics(),
                      const SizedBox(height: 20),
                      _permissionCard(),
                      const SizedBox(height: 20),
                      _section('Remaining / Pending Tasks', _pending, pending: true),
                      const SizedBox(height: 20),
                      _section('Completed Tasks', _completed, pending: false),
                    ],
                  ),
                ),
    );
  }

  Widget _welcome(auth_state.AuthState auth) {
    return Card(
      color: AppTheme.primaryGreenDark,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Staff Gateway',
                style: TextStyle(color: Colors.white70, fontSize: 13)),
            const SizedBox(height: 4),
            Text(auth.profile?.fullName ?? 'Staff member',
                style: const TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            const Text('Your work queues are limited by your assigned permissions.',
                style: TextStyle(color: Colors.white70)),
          ],
        ),
      ),
    );
  }

  Widget _metrics() {
    final completed = (_progress['completed_tasks'] as num?)?.toInt() ?? 0;
    final remaining = (_progress['remaining_tasks'] as num?)?.toInt() ?? 0;
    final total = (_progress['total_tasks'] as num?)?.toInt() ?? completed + remaining;
    final percent = (_progress['progress_percent'] as num?)?.toDouble() ?? 0;
    final avg = (_progress['average_resolution_hours'] as num?)?.toDouble() ?? 0;
    final recent = (_progress['completed_last_30_days'] as num?)?.toInt() ?? 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Progress', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 10),
            LinearProgressIndicator(value: (percent / 100).clamp(0, 1)),
            const SizedBox(height: 8),
            Text('${percent.toStringAsFixed(1)}% complete',
                style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.primaryGreen)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 18,
              runSpacing: 8,
              children: [
                _stat('Completed', '$completed'),
                _stat('Remaining', '$remaining'),
                _stat('Total', '$total'),
                _stat('30-day done', '$recent'),
                _stat('Avg hours', avg.toStringAsFixed(1)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// The staff member's own jobs, and the record of what they have done.
  ///
  /// The request was that their status and their work be visible to THEM and to
  /// the CEO. Until now the staff workspace showed a derived queue and nothing
  /// else: no list of what they are actually assigned, and no history of how
  /// that assignment changed, so "why can I not do X" and "when did they take
  /// that away" were both unanswerable from the inside.
  Widget _myJobsCard() {
    final record = _record!;
    final jobs = (record['jobs'] as List?) ?? const [];
    final history = (record['job_history'] as List?) ?? const [];
    final activity = (record['activity'] as List?) ?? const [];

    return Card(
      child: ExpansionTile(
        // The jobs are the answer to the question a staff member opens this
        // screen with, so they are visible without a tap. The history is the
        // answer to a rarer question, so it waits.
        initiallyExpanded: true,
        leading: const Icon(Icons.badge_outlined, color: AppTheme.teal),
        title: const Text('My jobs',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        subtitle: Text(jobs.isEmpty
            ? 'No jobs assigned — ask the CEO'
            : '${jobs.length} assigned'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (jobs.isEmpty)
                  const Text('You have no jobs assigned yet.',
                      style: TextStyle(
                          fontSize: 13, color: AppTheme.textSecondary))
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final job in jobs)
                        Chip(
                          avatar: const Icon(Icons.check, size: 15),
                          label: Text('${job['label'] ?? job['key']}',
                              style: const TextStyle(fontSize: 12)),
                          backgroundColor:
                              AppTheme.primaryGreen.withOpacity(0.08),
                          side: BorderSide(
                              color:
                                  AppTheme.primaryGreen.withOpacity(0.3)),
                        ),
                    ],
                  ),
                if (history.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  const Text('Job history',
                      style: TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  ...history.take(8).map(_historyLine),
                ],
                if (activity.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  const Text('What I have done',
                      style: TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  ...activity.take(8).map(_activityLine),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _historyLine(Map<String, dynamic> h) {
    final revoked = h['revoked_at'] != null;
    final when = h['assigned_at']?.toString() ?? '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        '${revoked ? "Removed" : "Added"}: ${h['label'] ?? h['job_key']}'
        '${when.isEmpty ? '' : ' · ${when.substring(0, 10)}'}'
        '${h['revoked_reason'] != null ? ' — ${h['revoked_reason']}' : ''}',
        style: TextStyle(
          fontSize: 11.5,
          color: revoked ? AppTheme.error : AppTheme.textSecondary,
        ),
      ),
    );
  }

  Widget _activityLine(Map<String, dynamic> a) {
    final when = a['created_at']?.toString() ?? '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        '${_humanAction(a['action']?.toString() ?? '')}'
        '${when.isEmpty ? '' : ' · ${when.substring(0, 10)}'}',
        style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary),
      ),
    );
  }

  String _humanAction(String action) {
    switch (action) {
      case 'task_completed':
        return 'Completed a work item';
      case 'jobs_added':
        return 'You were given new jobs';
      case 'jobs_removed':
        return 'A job was removed from you';
      case 'jobs_changed':
        return 'Your jobs were changed';
      case 'document_verified':
        return 'Verified an identity document';
      case 'document_rejected':
        return 'Rejected an identity document';
      default:
        return action.replaceAll('_', ' ');
    }
  }

  Widget _stat(String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
          Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        ],
      );

  /// Warnings addressed to this person.
  ///
  /// Sits ABOVE the progress card, not below it. A warning that arrives under
  /// a progress bar is a warning nobody reads, and the reason a manager sent
  /// it is precisely that the work is going badly.
  Widget _warningsCard() {
    final open = _warnings.where((w) => w['acknowledged_at'] == null).toList();
    final shown = (open.isNotEmpty ? open : _warnings).take(5).toList();
    final serious = open.any((w) => w['severity'] == 'SERIOUS');
    return Card(
      color: (serious ? AppTheme.error : AppTheme.warning).withOpacity(0.08),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: (serious ? AppTheme.error : AppTheme.warning).withOpacity(0.5),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  serious ? Icons.report_problem_outlined : Icons.warning_amber_rounded,
                  color: serious ? AppTheme.error : AppTheme.warning,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    open.isNotEmpty
                        ? '${open.length} open warning${open.length == 1 ? '' : 's'}'
                        : 'Warnings from management',
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 16),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ...shown.map(_warningTile),
          ],
        ),
      ),
    );
  }

  Widget _warningTile(Map<String, dynamic> warning) {
    final serious = warning['severity'] == 'SERIOUS';
    final acknowledged = warning['acknowledged_at'] != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            warning['reason'] as String? ?? '',
            style: const TextStyle(fontSize: 13.5),
          ),
          const SizedBox(height: 2),
          Text(
            '${serious ? 'Serious' : 'Warning'}'
            '${warning['warned_by_name'] != null ? ' · from ${warning['warned_by_name']}' : ''}',
            style: const TextStyle(
                fontSize: 11.5, color: AppTheme.textSecondary),
          ),
          if (!acknowledged)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _acknowledge(warning),
                icon: const Icon(Icons.done, size: 16),
                label: const Text('I have read this',
                    style: TextStyle(fontSize: 12.5)),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Acknowledging is server-enforced to this person only. A manager being
  /// able to tick it off would make the timestamp prove nothing, which is the
  /// only reason the column exists.
  Future<void> _acknowledge(Map<String, dynamic> warning) async {
    final id = warning['id'] as String?;
    if (id == null) return;
    try {
      await _service.acknowledge(id);
      await _refreshQuietly();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Marked as read.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not mark it as read. ${e.toString().split('\n').first}')),
        );
      }
    }
  }

  Widget _permissionCard() {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.verified_user_outlined, color: AppTheme.teal),
        title: const Text('Effective permissions'),
        subtitle: Text(_permissions.isEmpty || _permissions.contains('*')
            ? 'All staff permissions'
            : _permissions.join(', ')),
      ),
    );
  }

  Widget _section(String title, List<Map<String, dynamic>> tasks, {required bool pending}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
        const SizedBox(height: 8),
        if (tasks.isEmpty)
          const Card(child: Padding(
            padding: EdgeInsets.all(16),
            child: Text('No tasks in this list.'),
          ))
        else
          ...tasks.map((task) => _taskCard(task, pending: pending)),
      ],
    );
  }

  Widget _taskCard(Map<String, dynamic> task, {required bool pending}) {
    final terminal = task['is_terminal'] == true;
    // A hand-built row, not a ListTile — the same reasoning as
    // verification_status_tile.dart, and for the same reason it exists.
    //
    // ListTile(isThreeLine: true) has a FIXED height. The two-icon Row in the
    // trailing slot took its 96px first, which left the title and the
    // two-line subtitle roughly 150px on a 360px screen; at a 2.0 text scale
    // both wrapped past the three reserved lines and the card overflowed
    // vertically. This list has already produced that bug three times in
    // different screens, so it is built to lay out at any scale instead of
    // being tuned until it fits one.
    final meta =
        '${task['source_type'] ?? ''} · ${task['status'] ?? ''}'.trim();
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: pending ? () => _openTask(task) : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      task['title'] as String? ?? 'Task',
                      style: const TextStyle(
                          fontSize: 14.5, fontWeight: FontWeight.w600),
                    ),
                    if ((task['description'] as String?)?.isNotEmpty ?? false) ...[
                      const SizedBox(height: 3),
                      Text(
                        task['description'] as String,
                        style: const TextStyle(
                            fontSize: 12.5, color: AppTheme.textSecondary),
                      ),
                    ],
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Text(
                        meta,
                        style: const TextStyle(
                            fontSize: 11, color: AppTheme.textMuted),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 4),
              if (pending)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Open work item',
                      onPressed: () => _openTask(task),
                      icon: const Icon(Icons.open_in_new, size: 20),
                      visualDensity: VisualDensity.compact,
                    ),
                    IconButton(
                      tooltip: terminal
                          ? 'Mark done'
                          : 'Resolve the work item first',
                      onPressed: terminal ? () => _markDone(task) : null,
                      icon: Icon(
                        terminal ? Icons.check_circle : Icons.lock_clock,
                        size: 20,
                        color: terminal
                            ? AppTheme.primaryGreen
                            : AppTheme.textMuted,
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                )
              else
                const Padding(
                  padding: EdgeInsets.only(right: 8, top: 4),
                  child: Icon(Icons.check_circle,
                      color: AppTheme.success, size: 20),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
