import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/birr_text_field.dart';
import '../../core/widgets/load_error_view.dart';
import '../../core/widgets/primary_button.dart';

/// One editable system setting.
class _Setting {
  final String key;
  final dynamic value;
  final String? description;
  final DateTime? updatedAt;

  const _Setting({
    required this.key,
    required this.value,
    this.description,
    this.updatedAt,
  });

  /// 'number' | 'boolean' | 'string' | 'json'
  String get kind {
    if (value is bool) return 'boolean';
    if (value is num) return 'number';
    if (value is String) return 'string';
    return 'json';
  }
}

/// The generic system_settings editor.
///
/// It exists because there was no way to change a business rule without a
/// migration. Fees, thresholds, the points awards and the points-to-birr rate
/// all live in `system_settings`, and until now the only way to retune one was
/// to write SQL. Values are read straight from the table (authenticated has
/// SELECT on it) and every write goes through admin_update_setting(), which is
/// admin-gated, type-checked per key, and audited — the table itself has no
/// client write path, and its own trigger refuses a non-admin write anyway.
///
/// What this screen deliberately does not do: delete a key. A key that is gone
/// is a feature that is gone, and that decision deserves more than a tap in a
/// list.
class AdminSettingsScreen extends StatefulWidget {
  const AdminSettingsScreen({super.key});

  @override
  State<AdminSettingsScreen> createState() => _AdminSettingsScreenState();
}

class _AdminSettingsScreenState extends State<AdminSettingsScreen> {
  List<_Setting> _settings = [];
  bool _loading = true;
  String? _error;
  String _filter = '';
  bool _saving = false;

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
      final rows = await Supabase.instance.client
          .from('system_settings')
          .select('key, value, description, updated_at')
          .order('key');
      final settings = <_Setting>[];
      for (final raw in rows as List) {
        final row = Map<String, dynamic>.from(raw as Map);
        settings.add(_Setting(
          key: row['key'] as String,
          value: row['value'],
          description: row['description'] as String?,
          updatedAt: row['updated_at'] != null
              ? DateTime.tryParse(row['updated_at'] as String)
              : null,
        ));
      }
      if (mounted) {
        setState(() {
          _settings = settings;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e, context: 'Could not load the settings');
        });
      }
    }
  }

  List<_Setting> get _visible {
    final needle = _filter.trim().toLowerCase();
    if (needle.isEmpty) return _settings;
    return _settings
        .where((s) =>
            s.key.toLowerCase().contains(needle) ||
            (s.description ?? '').toLowerCase().contains(needle))
        .toList();
  }

  _Setting? _byKey(String key) {
    for (final s in _settings) {
      if (s.key == key) return s;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('System Settings'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : _error != null
              ? LoadErrorView(message: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  color: AppTheme.primaryGreen,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _pointsRateCard(),
                      const SizedBox(height: 16),
                      BirrTextField(
                        label: 'Filter settings',
                        hint: 'Search by key or description',
                        onChanged: (v) => setState(() => _filter = v),
                      ),
                      const SizedBox(height: 12),
                      if (_visible.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Text('No settings match that search.',
                              style: TextStyle(color: AppTheme.textMuted)),
                        )
                      else
                        for (final setting in _visible) ...[
                          _settingTile(setting),
                          const SizedBox(height: 8),
                        ],
                      const SizedBox(height: 12),
                      PrimaryButton(
                        label: 'Add a setting',
                        icon: Icons.add,
                        isOutlined: true,
                        onPressed: _saving ? null : () => _editSetting(null),
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
    );
  }

  /// The one setting with a direct consequence on money moving between
  /// accounts, so it is surfaced above the list rather than buried in it.
  Widget _pointsRateCard() {
    final setting = _byKey('points_to_birr_rate');
    final rate = (setting?.value as num?)?.toDouble();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.primaryGreen.withOpacity(0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.primaryGreen.withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.swap_horiz_rounded,
                  size: 18, color: AppTheme.primaryGreen),
              SizedBox(width: 8),
              Text('Points to wallet rate',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textPrimary)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            rate == null
                ? 'Not configured'
                : '${rate.toStringAsFixed(4)} ETB per point'
                    '  ·  ${rate <= 0 ? '—' : '${(1 / rate).round()} points = 1 ETB'}',
            style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: AppTheme.primaryGreenDark),
          ),
          const SizedBox(height: 4),
          const Text(
            'Changing this changes what every future conversion pays out. '
            'Conversions already made keep the rate they were paid at.',
            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 10),
          PrimaryButton(
            label: 'Edit rate',
            isOutlined: true,
            onPressed: setting == null || _saving
                ? null
                : () => _editSetting(setting),
          ),
        ],
      ),
    );
  }

  Widget _settingTile(_Setting setting) {
    final isPoints = setting.key.startsWith('points_');
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _saving ? null : () => _editSetting(setting),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.cardBorder),
          ),
          child: Row(
            children: [
              Icon(
                isPoints ? Icons.stars_rounded : Icons.tune,
                size: 18,
                color: isPoints ? AppTheme.gold : AppTheme.textMuted,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      setting.key,
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _display(setting.value),
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.primaryGreenDark),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (setting.description != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        setting.description!,
                        style: const TextStyle(
                            fontSize: 11, color: AppTheme.textMuted),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (setting.updatedAt != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        'Updated ${DateFormat('d MMM yyyy').format(setting.updatedAt!.toLocal())}',
                        style: const TextStyle(
                            fontSize: 10, color: AppTheme.textMuted),
                      ),
                    ],
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: AppTheme.textMuted),
            ],
          ),
        ),
      ),
    );
  }

  String _display(dynamic value) {
    if (value == null) return 'null';
    if (value is String) return value;
    if (value is num || value is bool) return '$value';
    final encoded = jsonEncode(value);
    return encoded.length > 90 ? '${encoded.substring(0, 90)}…' : encoded;
  }

  /// Edit an existing setting, or create one when [existing] is null.
  ///
  /// The editor's shape follows the value already stored, because the readers
  /// are typed: get_setting_numeric() casts the value, so a number that
  /// becomes a string breaks every reader of that key at runtime. The server
  /// refuses that too — this just makes it hard to attempt.
  Future<void> _editSetting(_Setting? existing) async {
    final keyController = TextEditingController(text: existing?.key ?? '');
    final valueController =
        TextEditingController(text: existing == null ? '' : _editable(existing.value));
    final descriptionController =
        TextEditingController(text: existing?.description ?? '');
    final formKey = GlobalKey<FormState>();

    final kind = existing?.kind ?? 'string';
    var boolValue = existing?.value is bool ? existing!.value as bool : false;

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(existing == null ? 'Add a setting' : existing.key),
              content: SingleChildScrollView(
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (existing == null)
                        BirrTextField(
                          label: 'Key',
                          hint: 'e.g. points_per_order',
                          controller: keyController,
                          validator: (v) =>
                              (v ?? '').trim().isEmpty ? 'A key is required' : null,
                        ),
                      if (existing == null) const SizedBox(height: 12),
                      if (kind == 'boolean')
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Enabled'),
                          value: boolValue,
                          onChanged: (v) => setDialogState(() => boolValue = v),
                        )
                      else
                        BirrTextField(
                          label: 'Value',
                          hint: kind == 'json'
                              ? 'Valid JSON, e.g. [{"code":"BRONZE","name":"Bronze",'
                                  '"min_points":100,"color":"#A9714B"}]'
                              : null,
                          controller: valueController,
                          maxLines: kind == 'json' ? 6 : 1,
                          keyboardType: kind == 'number'
                              ? const TextInputType.numberWithOptions(decimal: true)
                              : TextInputType.text,
                          validator: (raw) => _validate(kind, raw ?? ''),
                        ),
                      const SizedBox(height: 12),
                      BirrTextField(
                        label: 'Description (optional)',
                        controller: descriptionController,
                        maxLines: 2,
                      ),
                      if (existing?.kind == 'json') ...[
                        const SizedBox(height: 8),
                        const Text(
                          'Stored as JSON. The server validates the shape of '
                          'rank_tiers before saving it.',
                          style:
                              TextStyle(fontSize: 11, color: AppTheme.textMuted),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () {
                    if (formKey.currentState?.validate() ?? false) {
                      Navigator.of(dialogContext).pop(true);
                    }
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );

    if (saved != true) return;

    final key = existing?.key ?? keyController.text.trim();
    dynamic value;
    switch (kind) {
      case 'boolean':
        value = boolValue;
        break;
      case 'number':
        value = num.tryParse(valueController.text.trim());
        break;
      case 'json':
        value = jsonDecode(valueController.text.trim());
        break;
      default:
        value = valueController.text;
    }

    setState(() => _saving = true);
    try {
      await Supabase.instance.client.rpc('admin_update_setting', params: {
        'p_key': key,
        'p_value': value,
        'p_description': descriptionController.text.trim().isEmpty
            ? null
            : descriptionController.text.trim(),
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Saved $key'),
        backgroundColor: AppTheme.success,
      ));
      await _load();
    } catch (e) {
      if (!mounted) return;
      // The server's refusals are the useful ones here — a rate out of range,
      // a rank ladder that does not ascend, a key that must stay numeric —
      // and friendlyError keeps them readable.
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(friendlyError(e, context: 'Could not save $key')),
        backgroundColor: AppTheme.error,
        duration: const Duration(seconds: 6),
      ));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _editable(dynamic value) {
    if (value == null) return '';
    if (value is String) return value;
    if (value is num || value is bool) return '$value';
    return const JsonEncoder.withIndent('  ').convert(value);
  }

  String? _validate(String kind, String raw) {
    final text = raw.trim();
    if (kind == 'number') {
      if (num.tryParse(text) == null) return 'Enter a number';
      return null;
    }
    if (kind == 'json') {
      if (text.isEmpty) return 'A value is required';
      try {
        jsonDecode(text);
      } catch (_) {
        return 'That is not valid JSON';
      }
      return null;
    }
    return null;
  }
}
