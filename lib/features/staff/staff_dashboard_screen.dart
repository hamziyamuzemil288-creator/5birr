import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../../core/providers/auth_provider.dart' as auth_state;
import '../../core/services/staff_gateway_service.dart';
import '../../core/theme/app_theme.dart';

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
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait<dynamic>([
        _service.taskFeed(),
        _service.progress(),
        Supabase.instance.client.rpc('my_admin_permissions'),
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
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
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

  Widget _stat(String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
          Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        ],
      );

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
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text(task['title'] as String? ?? 'Task'),
        subtitle: Text('${task['description'] ?? ''}\n${task['source_type']} · ${task['status']}'),
        isThreeLine: true,
        trailing: pending
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Open work item',
                    onPressed: () => _openTask(task),
                    icon: const Icon(Icons.open_in_new),
                  ),
                  IconButton(
                    tooltip: terminal ? 'Mark done' : 'Resolve the work item first',
                    onPressed: terminal ? () => _markDone(task) : null,
                    icon: Icon(terminal ? Icons.check_circle : Icons.lock_clock),
                  ),
                ],
              )
            : const Icon(Icons.check_circle, color: AppTheme.success),
      ),
    );
  }
}
