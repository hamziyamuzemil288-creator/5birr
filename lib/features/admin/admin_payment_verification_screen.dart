import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/load_error_view.dart';

class AdminPaymentVerificationScreen extends StatefulWidget {
  const AdminPaymentVerificationScreen({super.key});
  @override
  State<AdminPaymentVerificationScreen> createState() => _State();
}

class _State extends State<AdminPaymentVerificationScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  List<Map<String, dynamic>> _pending = [];
  List<Map<String, dynamic>> _approved = [];
  List<Map<String, dynamic>> _rejected = [];
  bool _loading = true;
  // This is the queue admins work through to release people's money. A
  // failed load previously rendered an empty Pending tab, which reads as
  // "nobody is waiting" while real recharge requests sit unapproved.
  String? _error;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 3, vsync: this);
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      final p = await client
          .from('wallet_recharge_requests')
          .select('*, provider_profiles(business_name, user_id, profiles(full_name, phone)), payment_methods(name)')
          .eq('status', 'PENDING')
          .order('created_at');
      final a = await client
          .from('wallet_recharge_requests')
          .select('*, provider_profiles(business_name, user_id, profiles(full_name, phone)), payment_methods(name)')
          .eq('status', 'APPROVED')
          .order('approved_at', ascending: false)
          .limit(50);
      final r = await client
          .from('wallet_recharge_requests')
          .select('*, provider_profiles(business_name, user_id, profiles(full_name, phone)), payment_methods(name)')
          .eq('status', 'REJECTED')
          .order('approved_at', ascending: false)
          .limit(50);
      if (mounted) {
        setState(() {
          _pending = List<Map<String, dynamic>>.from(p as List);
          _approved = List<Map<String, dynamic>>.from(a as List);
          _rejected = List<Map<String, dynamic>>.from(r as List);
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e, context: 'Could not load pending payments');
        });
      }
    }
  }

  Future<void> _approve(String rechargeId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Approve Recharge'),
        content: const Text('Credit the wallet with this amount?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Approve',
                  style: TextStyle(color: AppTheme.success))),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await Supabase.instance.client.functions
          .invoke('admin-wallet-recharge', body: {
        'action': 'approve',
        'recharge_id': rechargeId,
      });
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e, context: 'Could not verify this payment'))));
      }
    }
  }

  Future<void> _reject(String rechargeId) async {
    final reasonCtrl = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Reject Recharge'),
        content: TextField(
          controller: reasonCtrl,
          maxLines: 2,
          decoration: const InputDecoration(hintText: 'Reason *'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Reject',
                  style: TextStyle(color: AppTheme.error))),
        ],
      ),
    );
    if (result != true || reasonCtrl.text.isEmpty) return;
    try {
      await Supabase.instance.client.functions
          .invoke('admin-wallet-recharge', body: {
        'action': 'reject',
        'recharge_id': rechargeId,
        'reason': reasonCtrl.text.trim(),
      });
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e, context: 'Could not verify this payment'))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Payment Verification'),
        bottom: TabBar(
          controller: _tabCtrl,
          tabs: [
            Tab(text: 'Pending (${_pending.length})'),
            Tab(text: 'Approved'),
            Tab(text: 'Rejected'),
          ],
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : _error != null
              ? LoadErrorView(message: _error!, onRetry: _load)
              : TabBarView(
              controller: _tabCtrl,
              children: [
                _list(_pending, showActions: true),
                _list(_approved),
                _list(_rejected),
              ],
            ),
    );
  }

  Widget _list(List<Map<String, dynamic>> items, {bool showActions = false}) {
    if (items.isEmpty) {
      return const Center(
          child: Text('No records', style: TextStyle(color: AppTheme.textMuted)));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: items.length,
        itemBuilder: (_, i) => _card(items[i], showActions: showActions),
      ),
    );
  }

  Widget _card(Map<String, dynamic> r, {bool showActions = false}) {
    final provider = r['provider_profiles'] as Map<String, dynamic>?;
    final profile =
        provider != null ? provider['profiles'] as Map<String, dynamic>? : null;
    final method =
        r['payment_methods'] as Map<String, dynamic>?;
    final amount = (r['amount'] as num?)?.toDouble() ?? 0;
    final date = r['created_at'] != null
        ? DateTime.parse(r['created_at'])
        : DateTime.now();

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(provider?['business_name'] ?? 'Provider',
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                      Text(profile?['full_name'] ?? '',
                          style: const TextStyle(
                              fontSize: 13, color: AppTheme.textSecondary)),
                      Text(profile?['phone'] ?? '',
                          style: const TextStyle(
                              fontSize: 12, color: AppTheme.textMuted)),
                    ],
                  ),
                ),
                Text('${amount.toStringAsFixed(2)} ETB',
                    style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.primaryGreen)),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _chip(method?['name'] ?? 'Unknown'),
                const SizedBox(width: 8),
                _chip('${date.day}/${date.month}/${date.year}'),
                if (r['payment_reference'] != null) ...[
                  const SizedBox(width: 8),
                  _chip('Ref: ${r['payment_reference']}'),
                ],
              ],
            ),
            if (r['screenshot_storage_path'] != null) ...[
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () => _viewScreenshot(r['screenshot_storage_path']),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppTheme.teal.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text('View Screenshot',
                      style: TextStyle(
                          fontSize: 12,
                          color: AppTheme.teal,
                          fontWeight: FontWeight.w500)),
                ),
              ),
            ],
            if (r['status'] == 'REJECTED' && r['rejection_reason'] != null) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.error.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('Rejected: ${r['rejection_reason']}',
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.error)),
              ),
            ],
            if (showActions) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => _approve(r['id']),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.success),
                      child: const Text('APPROVE'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _reject(r['id']),
                      style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: AppTheme.error)),
                      child: const Text('REJECT',
                          style: TextStyle(color: AppTheme.error)),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _chip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppTheme.creamDark,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text,
          style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
    );
  }

  Future<void> _viewScreenshot(String path) async {
    try {
      final url = await Supabase.instance.client.storage
          .from('payment-screenshots')
          .createSignedUrl(path, 3600);
      if (mounted) {
        showDialog(
          context: context,
          builder: (_) => Dialog(
            child: InteractiveViewer(
              child: Image.network(url),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e, context: 'Could not load the payment screenshot'))));
      }
    }
  }
}
