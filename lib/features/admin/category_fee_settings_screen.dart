import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/ethiopia_cities.dart' as cities;
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/load_error_view.dart';

/// One editable money value.
///
/// [value] is the EFFECTIVE number the server resolver returns -- the
/// override if one is configured, otherwise whatever it falls back to. That
/// is deliberately not the same as "what was typed": an editor showing the
/// stored value would show a blank for every provider still on the platform
/// default, which reads as "this fee is free" rather than "this fee follows
/// the global setting".
class _FeeField {
  const _FeeField({
    required this.param,
    required this.label,
    required this.column,
    this.isPercent = false,
    this.hint,
  });

  /// The named argument of admin_save_category_fee().
  final String param;
  final String label;
  /// The catalogue column this value is read from.
  final String column;
  final bool isPercent;
  final String? hint;

  String get unit => isPercent ? '%' : 'ETB';
}

/// The money values a provider category can be charged, grouped the way an
/// administrator thinks about them rather than by database column order.
const List<_FeeField> _rideFields = [
  _FeeField(
      param: 'p_ride_base_fare',
      label: 'Base fare',
      column: 'ride_base_fare',
      hint: 'The starting amount before distance'),
  _FeeField(
      param: 'p_ride_per_km',
      label: 'Per kilometre',
      column: 'ride_per_km',
      hint: 'Added per km travelled — this is the bajaj-vs-truck number'),
  _FeeField(
      param: 'p_ride_minimum_fare',
      label: 'Minimum fare',
      column: 'ride_minimum_fare',
      hint: 'Floor, however short the trip'),
];

const List<_FeeField> _bookingFields = [
  _FeeField(
      param: 'p_booking_base_fare',
      label: 'Booking base fee',
      column: 'booking_base_fare'),
  _FeeField(
      param: 'p_booking_per_km',
      label: 'Booking per km', column: 'booking_per_km'),
  _FeeField(
      param: 'p_booking_minimum_fee',
      label: 'Booking minimum',
      column: 'booking_minimum_fee'),
];

const List<_FeeField> _commissionFields = [
  _FeeField(
      param: 'p_commission_percent',
      label: 'Commission',
      column: 'commission_percent',
      isPercent: true,
      hint: 'Share of the sale the platform keeps'),
  _FeeField(
      param: 'p_commission_min',
      label: 'Minimum commission',
      column: 'commission_min',
      hint: 'Applies instead of the percentage when it is larger'),
  _FeeField(
      param: 'p_subscription_fee',
      label: 'Monthly subscription',
      column: 'subscription_fee'),
  _FeeField(
      param: 'p_activation_fee',
      label: 'One-time activation',
      column: 'activation_fee'),
];

const List<_FeeField> _productFields = [
  _FeeField(
      param: 'p_product_commission_percent',
      label: 'Product commission',
      column: 'product_commission_percent',
      isPercent: true),
  _FeeField(
      param: 'p_product_commission_min',
      label: 'Product minimum commission',
      column: 'product_commission_min'),
  _FeeField(
      param: 'p_product_listing_fee',
      label: 'Product listing fee',
      column: 'product_listing_fee'),
];

/// Per-category, per-city fee editor.
///
/// Reached from the admin sidebar as "Category & City Fees". The sibling
/// screen at /admin/fees edits the GLOBAL rates in `system_settings`; this
/// one edits the overrides that make bajaj differ from a big truck and
/// Addis Ababa differ from Hawassa.
///
/// THE INHERITANCE RULE, AND WHY THE UI IS BUILT AROUND IT
/// ------------------------------------------------------
/// Leaving a field BLANK means "use the platform default for this category and
/// city". Only a filled-in field overrides anything. So this screen must
/// never invent a value to put in a box: an editor that pre-filled every
/// field with the current effective number would save those numbers as hard
/// overrides on the first unrelated edit, silently freezing the platform
/// default at whatever it happened to be today. The effective numbers are
/// shown as HINTS under each field for that reason -- visible, never saved.
///
/// Editing is owner-only server-side (`is_fee_editor()` -> `is_ceo()`). A
/// non-owner admin sees the numbers and a reason rather than inputs that
/// would fail on save.
class CategoryFeeSettingsScreen extends StatefulWidget {
  const CategoryFeeSettingsScreen({super.key});

  @override
  State<CategoryFeeSettingsScreen> createState() =>
      _CategoryFeeSettingsScreenState();
}

class _CategoryFeeSettingsScreenState extends State<CategoryFeeSettingsScreen> {
  List<Map<String, dynamic>> _rows = const [];
  bool _loading = true;
  bool _canEdit = false;
  String? _error;

  String? _categoryId;
  String _city = '';
  bool _saving = false;

  /// field param -> text. Absent key = inherit.
  final Map<String, String> _drafts = {};

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
          .rpc('admin_category_fee_catalogue');
      if (!mounted) return;
      setState(() {
        _rows = List<Map<String, dynamic>>.from(rows as List);
        _loading = false;
      });
      _canEdit = await _readEditorFlag();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e, context: 'Could not load category fees');
      });
    }
  }

  Future<bool> _readEditorFlag() async {
    try {
      return (await Supabase.instance.client.rpc('is_fee_editor')) == true;
    } catch (_) {
      // A failed lookup must not offer buttons that will be refused. Default
      // to read-only, which is the safe direction.
      return false;
    }
  }

  /// The catalogue row for the selected (category, city) pair.
  Map<String, dynamic>? get _current {
    final id = _categoryId;
    if (id == null) return null;
    for (final r in _rows) {
      if (r['category_id'] == id && (r['city'] ?? '') == _city) return r;
    }
    return null;
  }

  /// Categories that actually have at least one row, so the picker does not
  /// offer 40 categories that all resolve to the same platform default.
  List<Map<String, dynamic>> get _categories {
    final byId = <String, Map<String, dynamic>>{};
    for (final r in _rows) {
      final id = r['category_id'] as String;
      byId.putIfAbsent(id, () => r);
    }
    final list = byId.values.toList()
      ..sort((a, b) => (a['category_name'] as String)
          .compareTo(b['category_name'] as String));
    return list;
  }

  /// Cities that already have a bespoke rate somewhere, offered first so an
  /// administrator does not have to know to go looking for them.
  List<String> get _configuredCities {
    final set = <String>{
      for (final r in _rows)
        if ((r['city'] ?? '').isNotEmpty) r['city'] as String,
    };
    final sorted = set.toList()..sort();
    return sorted;
  }

  void _selectCategory(String? id) {
    setState(() {
      _categoryId = id;
      _drafts.clear();
    });
  }

  void _selectCity(String? city) {
    setState(() {
      _city = city ?? '';
      _drafts.clear();
    });
  }

  Future<void> _save() async {
    final id = _categoryId;
    if (id == null || _saving) return;
    setState(() => _saving = true);

    // Blank text is sent as NULL, which is the server's word for "inherit".
    num? parse(String param) {
      final raw = _drafts[param]?.trim();
      if (raw == null || raw.isEmpty) return null;
      return num.tryParse(raw);
    }

    try {
      await Supabase.instance.client.rpc('admin_save_category_fee', params: {
        'p_category_id': id,
        'p_city': _city,
        for (final f in [
          ..._rideFields,
          ..._bookingFields,
          ..._commissionFields,
          ..._productFields
        ])
          f.param: parse(f.param),
      });
      if (!mounted) return;
      // The effective numbers just changed, so the row behind the form is
      // stale. Re-read rather than guessing what the new fallback resolves to.
      await _load();
      if (!mounted) return;
      setState(() => _drafts.clear());
      _snack('Saved. The next charge uses the new rate.');
    } catch (e) {
      if (mounted) {
        _snack(friendlyError(e, context: 'Could not save these fees'));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _clearOverride() async {
    final id = _categoryId;
    if (id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Go back to the platform default?'),
        content: Text(
          _city.isEmpty
              ? 'Every fee for this category will follow the global setting '
                  'again. This cannot be undone.'
              : 'Every fee for this category in $_city will follow the '
                  'category-wide rate, or the global setting where that has '
                  'no override. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear override'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    try {
      await Supabase.instance.client.rpc('admin_clear_category_fee', params: {
        'p_category_id': id,
        'p_city': _city,
      });
      if (!mounted) return;
      await _load();
      if (mounted) {
        setState(() => _drafts.clear());
        _snack('Override cleared.');
      }
    } catch (e) {
      if (mounted) _snack(friendlyError(e, context: 'Could not clear'));
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
      ));
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;
    final configured = (current?['is_configured'] ?? false) as bool;
    final dirty = _drafts.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Category & City Fees'),
        actions: [
          IconButton(
            tooltip: 'Reload',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : _error != null
              ? LoadErrorView(message: _error!, onRetry: _load)
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                  children: [
                    _explainer(),
                    const SizedBox(height: 16),
                    _categoryPicker(),
                    const SizedBox(height: 12),
                    _cityPicker(),
                    const SizedBox(height: 16),
                    if (_categoryId == null)
                      const Padding(
                        padding: EdgeInsets.only(top: 40),
                        child: Center(
                          child: Text(
                            'Choose a category to set its fees',
                            style: TextStyle(
                                fontSize: 13, color: AppTheme.textMuted),
                          ),
                        ),
                      )
                    else ...[
                      _statusRow(current, configured),
                      const SizedBox(height: 16),
                      _section('Ride fares', _rideFields, current),
                      const SizedBox(height: 16),
                      _section('Booking / service fees', _bookingFields, current),
                      const SizedBox(height: 16),
                      _section('Commission & subscriptions',
                          _commissionFields, current),
                      const SizedBox(height: 16),
                      _section('Products', _productFields, current),
                      const SizedBox(height: 24),
                      _actions(configured, dirty),
                    ],
                  ],
                ),
    );
  }

  Widget _explainer() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surfaceVariant,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline,
              size: 18, color: AppTheme.primaryGreenDark),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Leave a field blank to follow the platform default. Only a '
              'filled-in field overrides it. The greyed number under each '
              'field is what will be charged if you leave it blank.',
              style: TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: AppTheme.textSecondary.withOpacity(1)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _categoryPicker() {
    final cats = _categories;
    return DropdownButtonFormField<String>(
      value: _categoryId,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Category',
        prefixIcon: Icon(Icons.category_outlined),
        isDense: true,
      ),
      items: cats
          .map((c) => DropdownMenuItem<String>(
                value: c['category_id'] as String,
                child: Text(c['category_name'] as String,
                    overflow: TextOverflow.ellipsis),
              ))
          .toList(),
      onChanged: _canEdit ? _selectCategory : null,
    );
  }

  Widget _cityPicker() {
    final configured = _configuredCities;
    final options = <String>['', ...configured];
    for (final c in cities.cities) {
      if (!options.contains(c.toLowerCase())) options.add(c.toLowerCase());
    }
    return DropdownButtonFormField<String>(
      value: _city,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'City',
        prefixIcon: Icon(Icons.location_city_outlined),
        isDense: true,
      ),
      items: options
          .map((c) => DropdownMenuItem<String>(
                value: c,
                child: Text(c.isEmpty ? 'All cities' : _titleCase(c),
                    overflow: TextOverflow.ellipsis),
              ))
          .toList(),
      onChanged: _canEdit ? _selectCity : null,
    );
  }

  static String _titleCase(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  Widget _statusRow(Map<String, dynamic>? row, bool configured) {
    final by = (row?['updated_by_name'] ?? '') as String;
    final at = row?['updated_at'] as String?;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: (configured ? AppTheme.primaryGreen : AppTheme.textMuted)
            .withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: (configured ? AppTheme.primaryGreen : AppTheme.cardBorder)
              .withOpacity(0.5),
        ),
      ),
      child: Row(
        children: [
          Icon(
            configured ? Icons.tune : Icons.cloud_queue,
            size: 18,
            color: configured ? AppTheme.primaryGreenDark : AppTheme.textMuted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              configured
                  ? 'Custom rates for this ${_city.isEmpty ? 'category' : 'category in ${_titleCase(_city)}'}'
                      '${by.isEmpty ? '' : ' — set by $by'}'
                  : 'Following the platform defaults. Fill in a field to '
                      'override them.',
              style: const TextStyle(fontSize: 12.5, height: 1.4),
            ),
          ),
          if (at != null)
            Text(
              at.substring(0, 10),
              style: const TextStyle(fontSize: 10, color: AppTheme.textMuted),
            ),
        ],
      ),
    );
  }

  Widget _section(String title, List<_FeeField> fields,
      Map<String, dynamic>? row) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 13.5, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          for (final f in fields) _field(f, row),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _field(_FeeField f, Map<String, dynamic>? row) {
    // The EFFECTIVE value, for the hint. Never used as the starting text.
    //
    // PostgREST returns a JSON number as int when it has no fractional part,
    // so this is a `num`. `toStringAsFixed` exists on double, not on num --
    // hence the explicit toDouble() rather than a cast at the use site.
    final raw = row?[f.column];
    final effective = raw is num ? raw.toDouble() : null;
    final effectiveText = effective == null
        ? '—'
        : (f.isPercent
            ? (effective == effective.truncateToDouble()
                ? effective.toStringAsFixed(0)
                : effective.toStringAsFixed(2))
            : effective.toStringAsFixed(2));

    final controller = TextEditingController(text: _drafts[f.param] ?? '');
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: controller,
            enabled: _canEdit,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
            decoration: InputDecoration(
              labelText: '${f.label} (${f.unit})',
              hintText: 'platform default',
              isDense: true,
              suffixText: f.isPercent ? '%' : 'ETB',
            ),
            onChanged: (v) => setState(() {
              if (v.trim().isEmpty) {
                _drafts.remove(f.param);
              } else {
                _drafts[f.param] = v;
              }
            }),
          ),
          const SizedBox(height: 3),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              f.hint == null
                  ? 'Currently charged: $effectiveText ${f.unit}'
                  : '$effectiveText ${f.unit} · ${f.hint}',
              style: const TextStyle(fontSize: 10.5, color: AppTheme.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actions(bool configured, bool dirty) {
    if (!_canEdit) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.warning.withOpacity(0.10),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Row(
          children: [
            Icon(Icons.lock_outline, size: 18, color: AppTheme.warning),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Only the account owner can change what the platform charges. '
                'You can read every rate here.',
                style: TextStyle(fontSize: 12.5, height: 1.4),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: (!dirty || _saving) ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.save_outlined, size: 18),
            label: Text(_saving ? 'Saving…' : 'SAVE THESE FEES'),
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.primaryGreen,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
        if (configured) ...[
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _saving ? null : _clearOverride,
              icon: const Icon(Icons.restart_alt, size: 18),
              label: const Text('Go back to platform default'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.error,
                side: const BorderSide(color: AppTheme.error),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
