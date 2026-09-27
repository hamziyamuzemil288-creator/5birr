import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/load_error_view.dart';

/// One fee, as reported by `admin_fee_catalogue()`.
///
/// Deliberately built from the server's answer rather than a list hardcoded
/// here: a fee that exists in `system_settings` but not in this screen is a
/// fee nobody can change, which is the exact failure this screen was built to
/// remove. `isMissing` covers the other direction — a fee the screen expects
/// that has no row yet, shown as missing rather than silently absent.
class _Fee {
  const _Fee({
    required this.key,
    required this.value,
    required this.description,
    required this.group,
    required this.isPercent,
    required this.minValue,
    required this.maxValue,
    required this.updatedAt,
    required this.isMissing,
  });

  final String key;
  final dynamic value;
  final String? description;
  final String group;
  final bool isPercent;
  final num? minValue;
  final num? maxValue;
  final DateTime? updatedAt;
  final bool isMissing;

  factory _Fee.fromRow(Map<String, dynamic> row) => _Fee(
        key: row['key'] as String,
        value: row['value'],
        description: row['description'] as String?,
        group: (row['fee_group'] as String?) ?? 'OTHER',
        isPercent: (row['is_percent'] as bool?) ?? false,
        minValue: row['min_value'] as num?,
        maxValue: row['max_value'] as num?,
        updatedAt: row['updated_at'] == null
            ? null
            : DateTime.tryParse(row['updated_at'] as String),
        isMissing: (row['is_missing'] as bool?) ?? false,
      );

  num? get numeric => value is num ? value as num : null;

  /// A readable name. Falls back to prettifying the key, so a fee added by a
  /// later migration still gets a sensible label instead of a raw identifier.
  String get label {
    const known = {
      'transaction_fee_percent': 'Platform commission',
      'transaction_fee_min': 'Minimum commission',
      'provider_registration_fee': 'Provider activation fee',
      'monthly_subscription_fee': 'Monthly provider subscription',
      'provider_subscription_fee': 'Monthly provider subscription',
      'ride_base_fare': 'Ride base fare',
      'ride_per_km': 'Ride price per kilometre',
      'ride_minimum_fare': 'Minimum ride fare',
    };
    if (known.containsKey(key)) return known[key]!;
    final words = key.split('_').where((w) => w.isNotEmpty).map(
          (w) => w[0].toUpperCase() + w.substring(1),
        );
    return words.join(' ');
  }

  String get unitLabel => isPercent ? '%' : 'birr';
}

class _FeeChange {
  const _FeeChange({
    required this.at,
    required this.key,
    required this.oldValue,
    required this.newValue,
    required this.actorName,
  });

  final DateTime at;
  final String key;
  final dynamic oldValue;
  final dynamic newValue;
  final String actorName;

  factory _FeeChange.fromRow(Map<String, dynamic> row) => _FeeChange(
        at: DateTime.parse(row['changed_at'] as String).toLocal(),
        key: (row['key'] as String?) ?? '',
        oldValue: row['old_value'],
        newValue: row['new_value'],
        actorName: (row['actor_name'] as String?) ?? 'Unknown',
      );
}

/// Fee & pricing control panel.
///
/// Every money value the platform charges is editable here, live: a change
/// writes `system_settings`, and the next charge reads it. Nothing on this
/// screen needs a deploy, and nothing on this screen is a display-only copy of
/// a number that lives somewhere else — the commission shown is the number
/// `platform_transaction_fee()` returns, which is the number the wallet is
/// debited by.
///
/// Editing is CEO/owner only, enforced server-side by `admin_update_setting()`
/// (the product already distinguishes the owner from ordinary admins via
/// `is_ceo()`). A non-owner admin sees the values and a reason, rather than
/// buttons that would fail.
class FeeSettingsScreen extends StatefulWidget {
  const FeeSettingsScreen({super.key});

  @override
  State<FeeSettingsScreen> createState() => _FeeSettingsScreenState();
}

class _FeeSettingsScreenState extends State<FeeSettingsScreen> {
  List<_Fee> _fees = const [];
  List<_FeeChange> _history = const [];
  List<Map<String, dynamic>> _vehicleCategories = const [];
  bool _canEdit = false;
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
      final fees = await client.rpc('admin_fee_catalogue');
      final canEdit = await client.rpc('is_fee_editor');
      final history = await client.rpc('admin_fee_change_history', params: {'p_limit': 25});
      final categories = await client
          .from('categories')
          .select('id,name,slug,metadata')
          .eq('sector', 'VEHICLE')
          .eq('is_active', true)
          .order('sort_order');

      if (!mounted) return;
      setState(() {
        _fees = (fees as List)
            .map((r) => _Fee.fromRow(Map<String, dynamic>.from(r as Map)))
            .toList();
        _canEdit = canEdit == true;
        _history = (history as List)
            .map((r) => _FeeChange.fromRow(Map<String, dynamic>.from(r as Map)))
            .toList();
        _vehicleCategories =
            List<Map<String, dynamic>>.from(categories as List);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e, context: 'Could not load the fee settings');
      });
    }
  }

  Future<void> _editFee(_Fee fee) async {
    final controller = TextEditingController(
      text: fee.numeric == null ? '' : _trim(fee.numeric!),
    );
    String? problem;

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(fee.label),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (fee.description != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    fee.description!,
                    style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary),
                  ),
                ),
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: InputDecoration(
                  labelText: fee.isPercent ? 'Percent' : 'Birr',
                  suffixText: fee.unitLabel,
                  helperText: fee.isPercent
                      ? 'Between 0 and 100'
                      : 'Between 0 and 1,000,000',
                  errorText: problem,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Applies to the next transaction. No deploy, no restart.',
                style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryGreen,
                foregroundColor: Colors.white,
              ),
              onPressed: () async {
                final raw = controller.text.trim();
                final parsed = num.tryParse(raw);
                // Mirrors admin_update_setting()'s server-side bounds, so the
                // CEO gets an instant answer instead of a round trip that
                // fails. The server check is still the one that counts.
                if (parsed == null) {
                  setDialogState(() => problem = 'Enter a number');
                  return;
                }
                if (parsed < 0) {
                  setDialogState(() => problem = 'Cannot be negative');
                  return;
                }
                if (fee.isPercent && parsed > 100) {
                  setDialogState(() => problem = 'Percent cannot exceed 100');
                  return;
                }
                if (!fee.isPercent && parsed > 1000000) {
                  setDialogState(() => problem = 'Above the 1,000,000 birr limit');
                  return;
                }
                setDialogState(() => problem = null);
                try {
                  await Supabase.instance.client.rpc('admin_update_setting', params: {
                    'p_key': fee.key,
                    'p_value': parsed,
                  });
                  if (dialogContext.mounted) Navigator.of(dialogContext).pop(true);
                } catch (e) {
                  setDialogState(() {
                    problem = friendlyError(e, context: 'Could not save this fee');
                  });
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (saved == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${fee.label} updated'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      await _load();
    }
  }

  Future<void> _editCategoryPricing(Map<String, dynamic> category) async {
    final meta = (category['metadata'] as Map?)?.cast<String, dynamic>() ?? const {};
    final base = TextEditingController(text: _trim(meta['base_fare']));
    final perKm = TextEditingController(text: _trim(meta['per_km']));
    final minimum = TextEditingController(text: _trim(meta['minimum_fare']));
    String? problem;

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text('${category['name']} pricing'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Leave a field empty to use the global ride pricing for that value.',
                  style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary),
                ),
                const SizedBox(height: 14),
                _pricingField(base, 'Base fare (birr)'),
                const SizedBox(height: 10),
                _pricingField(perKm, 'Per kilometre (birr)'),
                const SizedBox(height: 10),
                _pricingField(minimum, 'Minimum fare (birr)'),
                if (problem != null) ...[
                  const SizedBox(height: 10),
                  Text(problem!, style: const TextStyle(color: AppTheme.error, fontSize: 12.5)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryGreen,
                foregroundColor: Colors.white,
              ),
              onPressed: () async {
                num? parse(TextEditingController c) =>
                    c.text.trim().isEmpty ? null : num.tryParse(c.text.trim());

                final values = [parse(base), parse(perKm), parse(minimum)];
                if (values.any((v) => v != null && (v < 0 || v > 1000000))) {
                  setDialogState(() => problem = 'Values must be between 0 and 1,000,000');
                  return;
                }
                try {
                  await Supabase.instance.client.rpc('set_ride_category_pricing', params: {
                    'p_category_id': category['id'],
                    'p_base_fare': values[0],
                    'p_per_km': values[1],
                    'p_minimum_fare': values[2],
                  });
                  if (dialogContext.mounted) Navigator.of(dialogContext).pop(true);
                } catch (e) {
                  setDialogState(() {
                    problem = friendlyError(e, context: 'Could not save this pricing');
                  });
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (saved == true && mounted) await _load();
  }

  Widget _pricingField(TextEditingController controller, String label) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
    );
  }

  /// Trim a trailing `.0` so 5.0 reads as `5` in an input box.
  static String _trim(dynamic value) {
    if (value == null) return '';
    if (value is num) {
      final n = value.toDouble();
      return n == n.roundToDouble() ? n.toInt().toString() : n.toString();
    }
    return value.toString();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Fees & Pricing'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload',
            onPressed: _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : _error != null
              ? LoadErrorView(message: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  color: AppTheme.primaryGreen,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (!_canEdit) const _ReadOnlyBanner(),
                      ..._buildGroups(),
                      const SizedBox(height: 8),
                      _buildCategoryPricing(),
                      const SizedBox(height: 20),
                      _buildHistory(),
                    ],
                  ),
                ),
    );
  }

  List<Widget> _buildGroups() {
    final groups = <String, List<_Fee>>{};
    for (final fee in _fees) {
      groups.putIfAbsent(fee.group, () => []).add(fee);
    }
    const order = ['TRANSACTION', 'ACTIVATION', 'SUBSCRIPTION', 'RIDE DEFAULTS'];

    final keys = groups.keys.toList()
      ..sort((a, b) {
        final ai = order.indexOf(a);
        final bi = order.indexOf(b);
        if (ai == -1 && bi == -1) return a.compareTo(b);
        if (ai == -1) return 1;
        if (bi == -1) return -1;
        return ai.compareTo(bi);
      });

    return [
      for (final key in keys) ...[
        Padding(
          padding: const EdgeInsets.only(bottom: 8, top: 6),
          child: Text(
            key,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: AppTheme.textMuted,
            ),
          ),
        ),
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: AppTheme.cardBorder),
          ),
          child: Column(
            children: [
              for (var i = 0; i < groups[key]!.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                _feeTile(groups[key]![i]),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
      ],
    ];
  }

  Widget _feeTile(_Fee fee) {
    final valueLabel = fee.isMissing
        ? 'Not set'
        : fee.numeric == null
            ? '${fee.value}'
            : '${_trim(fee.numeric)}${fee.isPercent ? '%' : ' birr'}';

    return ListTile(
      title: Text(fee.label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      subtitle: Text(
        fee.description ?? fee.key,
        style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            valueLabel,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: fee.isMissing ? AppTheme.warning : AppTheme.primaryGreenDark,
            ),
          ),
          if (_canEdit) ...[
            const SizedBox(width: 6),
            const Icon(Icons.edit_outlined, size: 17, color: AppTheme.textMuted),
          ],
        ],
      ),
      onTap: _canEdit ? () => _editFee(fee) : null,
    );
  }

  Widget _buildCategoryPricing() {
    if (_vehicleCategories.isEmpty) return const SizedBox.shrink();
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppTheme.cardBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Per-vehicle-type ride pricing',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            const Text(
              'An override here beats the ride defaults above for that vehicle type only.',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 10),
            for (final category in _vehicleCategories)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  (category['name'] as String?) ?? 'Category',
                  style: const TextStyle(fontSize: 13.5),
                ),
                subtitle: Text(
                  _categoryPricingSummary(category),
                  style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                ),
                trailing: _canEdit
                    ? const Icon(Icons.edit_outlined, size: 17, color: AppTheme.textMuted)
                    : const Text('global', style: TextStyle(fontSize: 12, color: AppTheme.textMuted)),
                onTap: _canEdit ? () => _editCategoryPricing(category) : null,
              ),
          ],
        ),
      ),
    );
  }

  String _categoryPricingSummary(Map<String, dynamic> category) {
    final meta = (category['metadata'] as Map?)?.cast<String, dynamic>() ?? const {};
    final parts = <String>[];
    if (meta['base_fare'] != null) parts.add('base ${_trim(meta['base_fare'])}');
    if (meta['per_km'] != null) parts.add('${_trim(meta['per_km'])}/km');
    if (meta['minimum_fare'] != null) parts.add('min ${_trim(meta['minimum_fare'])}');
    return parts.isEmpty ? 'Using the global ride pricing' : parts.join(' • ');
  }

  Widget _buildHistory() {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppTheme.cardBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Fee change history',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            const Text(
              'Every fee change is recorded with who made it and the value before and after.',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 10),
            if (_history.isEmpty)
              const Text('No fee has been changed yet.',
                  style: TextStyle(fontSize: 12.5, color: AppTheme.textMuted))
            else
              for (final change in _history)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.history, size: 15, color: AppTheme.textMuted),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${_labelForKey(change.key)}: ${_valueText(change.oldValue)} → ${_valueText(change.newValue)}',
                              style: const TextStyle(fontSize: 12.5),
                            ),
                            Text(
                              '${change.actorName} • ${DateFormat('d MMM y, HH:mm').format(change.at)}',
                              style: const TextStyle(fontSize: 11.5, color: AppTheme.textMuted),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }

  String _labelForKey(String key) {
    final fee = _fees.where((f) => f.key == key).toList();
    return fee.isEmpty ? key : fee.first.label;
  }

  static String _valueText(dynamic value) {
    if (value == null) return '—';
    return _trim(value);
  }
}

class _ReadOnlyBanner extends StatelessWidget {
  const _ReadOnlyBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.info.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.info.withOpacity(0.25)),
      ),
      child: Row(
        children: [
          const Icon(Icons.lock_outline, size: 18, color: AppTheme.info),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Read-only. Platform fees and pricing can only be changed by the CEO/owner account.',
              style: TextStyle(fontSize: 12.5, color: AppTheme.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
