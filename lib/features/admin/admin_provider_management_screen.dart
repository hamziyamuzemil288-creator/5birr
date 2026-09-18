import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/services/points_service.dart';

class AdminProviderManagementScreen extends StatefulWidget {
  const AdminProviderManagementScreen({super.key});
  @override
  State<AdminProviderManagementScreen> createState() => _State();
}

class _State extends State<AdminProviderManagementScreen> {
  List<Map<String, dynamic>> _providers = [];
  bool _loading = true;
  String _filter = 'PENDING_APPROVAL';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await Supabase.instance.client
          .from('provider_profiles')
          .select('*, profiles(full_name, phone)')
          .eq('status', _filter)
          .order('created_at', ascending: false);
      if (mounted) {
        setState(() {
          _providers = List<Map<String, dynamic>>.from(data as List);
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _approve(String providerId) async {
    try {
      await Supabase.instance.client.functions.invoke('provider-approval',
          body: {'provider_id': providerId, 'action': 'APPROVE'});
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _reject(String providerId) async {
    final reason = await _showReasonDialog('Reject Reason');
    if (reason == null || reason.isEmpty) return;
    try {
      await Supabase.instance.client.functions.invoke('provider-approval',
          body: {
            'provider_id': providerId,
            'action': 'REJECT',
            'reason': reason,
          });
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _requestCorrection(String providerId) async {
    final reason = await _showReasonDialog('Correction Required');
    if (reason == null || reason.isEmpty) return;
    try {
      await Supabase.instance.client.functions.invoke('provider-approval',
          body: {
            'provider_id': providerId,
            'action': 'REQUEST_CORRECTION',
            'reason': reason,
          });
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<String?> _showReasonDialog(String title) async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          maxLines: 3,
          decoration: const InputDecoration(hintText: 'Enter reason...'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, ctrl.text),
              child: const Text('Submit')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Provider Management')),
      body: Column(
        children: [
          // Filter chips
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _chip('PENDING_APPROVAL', 'Pending'),
                  _chip('APPROVED', 'Approved'),
                  _chip('REJECTED', 'Rejected'),
                  _chip('SUSPENDED', 'Suspended'),
                ],
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(
                        color: AppTheme.primaryGreen))
                : _providers.isEmpty
                    ? const Center(
                        child: Text('No providers found',
                            style: TextStyle(color: AppTheme.textMuted)))
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.builder(
                          padding: const EdgeInsets.all(16),
                          itemCount: _providers.length,
                          itemBuilder: (_, i) {
                            final p = _providers[i];
                            final profile = p['profiles'] as Map<String, dynamic>?;
                            return Card(
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                              p['business_name'] ?? '',
                                              style: const TextStyle(
                                                  fontSize: 16,
                                                  fontWeight:
                                                      FontWeight.w600)),
                                        ),
                                        Container(
                                          padding:
                                              const EdgeInsets.symmetric(
                                                  horizontal: 8,
                                                  vertical: 3),
                                          decoration: BoxDecoration(
                                            color: AppTheme.primaryGreen
                                                .withOpacity(0.1),
                                            borderRadius:
                                                BorderRadius.circular(12),
                                          ),
                                          child: Text(
                                              p['provider_type']
                                                  .toString()
                                                  .replaceAll('_', ' '),
                                              style: const TextStyle(
                                                  fontSize: 11,
                                                  color:
                                                      AppTheme.primaryGreen)),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    Text(profile?['full_name'] ?? '',
                                        style: const TextStyle(
                                            fontSize: 13,
                                            color: AppTheme.textSecondary)),
                                    Text(profile?['phone'] ?? '',
                                        style: const TextStyle(
                                            fontSize: 12,
                                            color: AppTheme.textMuted)),
                                    const SizedBox(height: 6),
                                    _ProviderPointsLine(
                                        providerId: p['id'] as String),
                                    if (_filter == 'PENDING_APPROVAL') ...[
                                      const SizedBox(height: 12),
                                      Row(
                                        children: [
                                          Expanded(
                                            child: ElevatedButton(
                                              onPressed: () =>
                                                  _approve(p['id']),
                                              style:
                                                  ElevatedButton.styleFrom(
                                                backgroundColor:
                                                    AppTheme.success,
                                                padding:
                                                    const EdgeInsets
                                                        .symmetric(
                                                        vertical: 10),
                                              ),
                                              child: const Text('Approve',
                                                  style: TextStyle(
                                                      fontSize: 13)),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: OutlinedButton(
                                              onPressed: () =>
                                                  _requestCorrection(
                                                      p['id']),
                                              style:
                                                  OutlinedButton.styleFrom(
                                                padding:
                                                    const EdgeInsets
                                                        .symmetric(
                                                        vertical: 10),
                                              ),
                                              child: const Text(
                                                  'Correction',
                                                  style: TextStyle(
                                                      fontSize: 13)),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: OutlinedButton(
                                              onPressed: () =>
                                                  _reject(p['id']),
                                              style:
                                                  OutlinedButton.styleFrom(
                                                side: const BorderSide(
                                                    color:
                                                        AppTheme.error),
                                                padding:
                                                    const EdgeInsets
                                                        .symmetric(
                                                        vertical: 10),
                                              ),
                                              child: const Text('Reject',
                                                  style: TextStyle(
                                                      fontSize: 13,
                                                      color: AppTheme
                                                          .error)),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String value, String label) {
    final selected = _filter == value;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) {
          setState(() => _filter = value);
          _load();
        },
        selectedColor: AppTheme.primaryGreen,
        labelStyle: TextStyle(
            color: selected ? Colors.white : AppTheme.textPrimary,
            fontSize: 13),
      ),
    );
  }
}

/// Live points total for one provider row (Feature 3 admin view).
class _ProviderPointsLine extends StatefulWidget {
  final String providerId;
  const _ProviderPointsLine({required this.providerId});
  @override
  State<_ProviderPointsLine> createState() => _ProviderPointsLineState();
}

class _ProviderPointsLineState extends State<_ProviderPointsLine> {
  int? _points;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final map =
          await PointsService.instance.getProviderPointsBulk([widget.providerId]);
      if (mounted) setState(() => _points = map[widget.providerId] ?? 0);
    } catch (_) {
      if (mounted) setState(() => _points = 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.stars_rounded,
            size: 15, color: AppTheme.primaryGreen),
        const SizedBox(width: 5),
        Text('Points: ${_points ?? "…"}',
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppTheme.textSecondary)),
      ],
    );
  }
}
