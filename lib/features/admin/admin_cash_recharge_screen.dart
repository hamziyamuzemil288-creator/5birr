import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/birr_text_field.dart';
import '../../core/widgets/primary_button.dart';
import '../../core/utils/friendly_error.dart';

class AdminCashRechargeScreen extends StatefulWidget {
  final String providerId;
  const AdminCashRechargeScreen({super.key, required this.providerId});
  @override
  State<AdminCashRechargeScreen> createState() => _State();
}

class _State extends State<AdminCashRechargeScreen> {
  final _amountCtrl = TextEditingController();
  final _reasonCtrl = TextEditingController();
  bool _saving = false;
  String? _error;
  String? _success;
  Map<String, dynamic>? _wallet;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final w = await Supabase.instance.client
        .from('wallets')
        .select()
        .eq('provider_id', widget.providerId)
        .maybeSingle();
    if (mounted) setState(() => _wallet = w);
  }

  Future<void> _cashRecharge() async {
    final amount = double.tryParse(_amountCtrl.text);
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Enter a valid amount');
      return;
    }
    if (_reasonCtrl.text.isEmpty) {
      setState(() => _error = 'Reason is required');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
      _success = null;
    });
    try {
      await Supabase.instance.client.rpc('admin_cash_recharge', params: {
        'p_provider_id': widget.providerId,
        'p_amount': amount,
        'p_reason': _reasonCtrl.text.trim(),
        'p_admin_id': Supabase.instance.client.auth.currentUser?.id,
      });
      await _load();
      if (mounted) {
        setState(() {
          _saving = false;
          _success = '${amount.toStringAsFixed(2)} ETB credited successfully';
          _amountCtrl.clear();
          _reasonCtrl.clear();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = friendlyError(e, context: 'Could not record the recharge');
        });
      }
    }
  }

  Future<void> _adjust({required bool isCredit}) async {
    final amount = double.tryParse(_amountCtrl.text);
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Enter a valid amount');
      return;
    }
    if (_reasonCtrl.text.isEmpty) {
      setState(() => _error = 'Reason is required');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
      _success = null;
    });
    try {
      final adjAmount = isCredit ? amount : -amount;
      await Supabase.instance.client
          .rpc('admin_wallet_adjustment', params: {
        'p_provider_id': widget.providerId,
        'p_amount': adjAmount,
        'p_reason': _reasonCtrl.text.trim(),
        'p_admin_id': Supabase.instance.client.auth.currentUser?.id,
      });
      await _load();
      if (mounted) {
        setState(() {
          _saving = false;
          _success =
              'Wallet adjusted by ${isCredit ? '+' : '-'}${amount.toStringAsFixed(2)} ETB';
          _amountCtrl.clear();
          _reasonCtrl.clear();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = friendlyError(e, context: 'Could not record the recharge');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final balance = (_wallet?['balance'] as num?)?.toDouble() ?? 0;

    return Scaffold(
      appBar: AppBar(title: const Text('Wallet Management')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Current balance
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.primaryGreen.withOpacity(0.06),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.primaryGreen.withOpacity(0.15)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Current Balance',
                      style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                  const SizedBox(height: 4),
                  Text('${balance.toStringAsFixed(2)} ETB',
                      style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.primaryGreen)),
                ],
              ),
            ),
            const SizedBox(height: 24),
            if (_success != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.success.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(_success!,
                    style: const TextStyle(fontSize: 13, color: AppTheme.success)),
              ),
              const SizedBox(height: 16),
            ],
            if (_error != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.error.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(_error!,
                    style: const TextStyle(fontSize: 13, color: AppTheme.error)),
              ),
              const SizedBox(height: 16),
            ],
            BirrTextField(
              label: 'Amount (ETB)',
              controller: _amountCtrl,
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 16),
            BirrTextField(
              label: 'Reason / Note',
              controller: _reasonCtrl,
              maxLines: 2,
            ),
            const SizedBox(height: 24),
            // Cash recharge
            const Text('Cash Recharge',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: PrimaryButton(
                label: 'CASH RECHARGE',
                isLoading: _saving,
                onPressed: _cashRecharge,
              ),
            ),
            const SizedBox(height: 20),
            // Adjustment
            const Text('Wallet Adjustment',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _saving ? null : () => _adjust(isCredit: true),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.success),
                    child: const Text('CREDIT'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _saving ? null : () => _adjust(isCredit: false),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.error),
                    child: const Text('DEBIT'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
