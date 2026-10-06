import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/bank_account_rules.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/load_error_view.dart';

/// Admin: the two halves of item 5 that belong to the platform rather than
/// to one provider.
///
///  * **Banks** — the table that decides what a valid account number IS
///    (digit length + prefix). CBE is seeded 13 digits starting 1000; every
///    other bank is a generic 8–16. Editing a row here changes what the
///    provider's form validates AND what the database trigger enforces, from
///    one source of truth.
///  * **Provider accounts** — every account on the platform, newest first,
///    with the power to disable one that is being used to dodge the rules
///    (a disabled account disappears from checkout immediately; the row and
///    its history stay).
///
/// Both halves are read/write through RLS: admins get `is_admin()` policies
/// on `banks` (migration 20261006000007) and the admin-write policy on
/// `provider_payment_methods`.
class AdminPaymentAccountsScreen extends StatefulWidget {
  const AdminPaymentAccountsScreen({super.key});

  @override
  State<AdminPaymentAccountsScreen> createState() =>
      _AdminPaymentAccountsScreenState();
}

class _AdminPaymentAccountsScreenState
    extends State<AdminPaymentAccountsScreen> {
  List<Map<String, dynamic>> _banks = [];
  List<Map<String, dynamic>> _accounts = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = Supabase.instance.client;
      final banks = await client
          .from('banks')
          .select()
          .order('name')
          .timeout(const Duration(seconds: 12));
      final accounts = await client
          .from('provider_payment_methods')
          .select(
              '*, provider_profiles(business_name), banks(name, digit_min, digit_max)')
          .order('created_at', ascending: false)
          .limit(300)
          .timeout(const Duration(seconds: 12));
      if (!mounted) return;
      setState(() {
        _banks = List<Map<String, dynamic>>.from(banks as List);
        _accounts = List<Map<String, dynamic>>.from(accounts as List);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e, context: 'Could not load payment accounts');
      });
    }
  }

  Future<void> _setAccountActive(Map<String, dynamic> row, bool active) async {
    try {
      await Supabase.instance.client
          .from('provider_payment_methods')
          .update({'is_active': active})
          .eq('id', row['id'] as String)
          .timeout(const Duration(seconds: 12));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(active
                ? 'Account re-enabled'
                : 'Account disabled — buyers no longer see it'),
          ),
        );
      }
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
                Text(friendlyError(e, context: 'Could not update account'))),
      );
    }
  }

  Future<void> _editBank(Map<String, dynamic> bank) async {
    final minCtrl = TextEditingController(text: '${bank['digit_min']}');
    final maxCtrl = TextEditingController(text: '${bank['digit_max']}');
    final prefixCtrl =
        TextEditingController(text: (bank['prefix'] as String?) ?? '');
    var active = (bank['is_active'] as bool?) ?? true;

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text(bank['name'] as String? ?? 'Bank'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: minCtrl,
                  keyboardType: TextInputType.number,
                  decoration:
                      const InputDecoration(labelText: 'Minimum digits'),
                ),
                TextFormField(
                  controller: maxCtrl,
                  keyboardType: TextInputType.number,
                  decoration:
                      const InputDecoration(labelText: 'Maximum digits'),
                ),
                TextFormField(
                  controller: prefixCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: 'Required prefix (optional)'),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Active (providers can pick it)'),
                  value: active,
                  onChanged: (v) => setDialog(() => active = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx, false),
              child: const Text('CANCEL'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogCtx, true),
              child: const Text('SAVE'),
            ),
          ],
        ),
      ),
    );
    if (saved != true || !mounted) return;

    final min = int.tryParse(minCtrl.text.trim());
    final max = int.tryParse(maxCtrl.text.trim());
    if (min == null || max == null || min < 4 || max < min) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Digits must be at least 4, and min ≤ max')),
      );
      return;
    }
    try {
      await Supabase.instance.client
          .from('banks')
          .update({
            'digit_min': min,
            'digit_max': max,
            'prefix': prefixCtrl.text.trim().isEmpty
                ? null
                : prefixCtrl.text.trim(),
            'is_active': active,
          })
          .eq('id', bank['id'] as String)
          .timeout(const Duration(seconds: 12));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(friendlyError(e, context: 'Could not save bank'))),
      );
    }
  }

  Future<void> _addBank() async {
    final nameCtrl = TextEditingController();
    final minCtrl = TextEditingController(text: '8');
    final maxCtrl = TextEditingController(text: '16');
    final prefixCtrl = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Add bank'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Bank name'),
              ),
              TextField(
                controller: minCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Minimum digits'),
              ),
              TextField(
                controller: maxCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Maximum digits'),
              ),
              TextField(
                controller: prefixCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'Required prefix (optional)'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('ADD'),
          ),
        ],
      ),
    );
    if (saved != true || !mounted) return;
    final name = nameCtrl.text.trim();
    final min = int.tryParse(minCtrl.text.trim());
    final max = int.tryParse(maxCtrl.text.trim());
    if (name.isEmpty || min == null || max == null || min < 4 || max < min) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Enter a name and a valid digit range (min 4)')),
      );
      return;
    }
    try {
      await Supabase.instance.client.from('banks').insert({
        'name': name,
        'digit_min': min,
        'digit_max': max,
        'prefix': prefixCtrl.text.trim().isEmpty
            ? null
            : prefixCtrl.text.trim(),
      }).timeout(const Duration(seconds: 12));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(friendlyError(e, context: 'Could not add bank'))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Payment Accounts & Banks')),
      body: _error != null
          ? LoadErrorView(message: _error!, onRetry: _load)
          : _loading
              ? const Center(
                  child:
                      CircularProgressIndicator(color: AppTheme.primaryGreen))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _sectionHeader('Banks', subtitle: 'The rules an account '
                          'number must satisfy', action: _addBank),
                      ..._banks.map(_bankTile),
                      const SizedBox(height: 20),
                      _sectionHeader('Provider accounts',
                          subtitle:
                              '${_accounts.length} total — disable any of them'),
                      ..._accounts.map(_accountTile),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
    );
  }

  Widget _sectionHeader(String title,
      {required String subtitle, VoidCallback? action}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
                Text(subtitle,
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textSecondary)),
              ],
            ),
          ),
          if (action != null)
            TextButton.icon(
              onPressed: action,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add'),
            ),
        ],
      ),
    );
  }

  Widget _bankTile(Map<String, dynamic> bank) {
    final prefix = (bank['prefix'] as String?)?.trim();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(bank['name'] as String? ?? '',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        subtitle: Text(
          '${bank['digit_min']}–${bank['digit_max']} digits'
          '${prefix == null || prefix.isEmpty ? '' : ' · starts with $prefix'}'
          '${(bank['is_active'] as bool?) == false ? ' · inactive' : ''}',
          style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
        ),
        trailing: const Icon(Icons.edit_outlined, size: 18),
        onTap: () => _editBank(bank),
      ),
    );
  }

  Widget _accountTile(Map<String, dynamic> row) {
    final provider =
        row['provider_profiles'] as Map<String, dynamic>?;
    final bank = row['banks'] as Map<String, dynamic>?;
    final active = (row['is_active'] as bool?) ?? false;
    final number = row['account_number'] as String? ?? '';
    final digits = normalizeDigits(number);
    final masked = digits.isEmpty
        ? '—'
        : digits.length <= 4
            ? digits
            : '${digits.substring(0, 2)}${'•' * (digits.length - 4)}${digits.substring(digits.length - 2)}';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: active ? AppTheme.cardBorder : AppTheme.error.withOpacity(0.35),
        ),
      ),
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(
          (provider?['business_name'] as String?) ?? 'Provider',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${bank?['name'] as String? ?? 'No bank'} · $masked'
          '${row['is_default'] == true ? ' · default' : ''}'
          '${active ? '' : ' · disabled'}',
          style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
        ),
        trailing: Switch(
          value: active,
          activeColor: AppTheme.primaryGreen,
          onChanged: (v) => _setAccountActive(row, v),
        ),
      ),
    );
  }
}
