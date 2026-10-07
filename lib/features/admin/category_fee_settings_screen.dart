import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/ethiopia_cities.dart' as cities;
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/load_error_view.dart';

// Fee model → which field groups apply, plus per-model hints.
//
// The categories table does not carry an explicit "fee model" column. The model
// is derived the same way the app already derives tab membership: from sector
// and marketplace_sector, using the columns that already exist today.
//
//   RIDE          — summoned per trip and priced by distance (base + per_km).
//                   VEHICLE rows whose name / slug read as a dispatchable trip:
//                   ride-taxi, motorcycle-bajaj, car-rental, delivery-vehicle,
//                   food-delivery, airport-transport, special-transport.
//   FIXED_ROUTE  — runs a route, but is still a distance-priced vehicle: bus,
//                   minibus, truck, freight-cargo, tour-travel, ambulance.
//   STAY         — nights, not km. ACCOMMODATION (hotels-lodging). Booking
//                   fares only: never any per-km fields.
//   SERVICE_BOOK — a booked appointment / slot / call-out: SERVICES
//                   (barber, plumber, doctor, gym lesson …). Booking fares.
//   PRODUCT      — bought off a shelf: FOOD / RETAIL / OTHER that is
//                   PRODUCT_BASED, or any SERVICE subcategory that is
//                   product-based (grocery, clothing …).
//                   Product commission + listing fee.

enum _FeeModel { ride, fixedRoute, stay, serviceBook, product }

/// The fields that apply to a given fee model.
List<List<_FeeField>> _fieldsForModel(_FeeModel model) {
  // RIDE and FIXED_ROUTE both use distance-priced rides. They share the ride
  // fields. Keep their field sets identical for now: the app does not yet have
  // a separate "fixed route surcharge" column, so the same ride pricing table
  // prices both.
  if (model == _FeeModel.ride || model == _FeeModel.fixedRoute) {
    return [
      _rideFields,
      _bookingFields,
      _commissionFields,
    ];
  }
  if (model == _FeeModel.stay || model == _FeeModel.serviceBook) {
    // Stay/hotel must NEVER show per-km fields. Booking base + minimum fare
    // still apply — a hotel may charge a call-out or a booking fee — but the
    // per-km columns are not offered for a hotel.
    return [
      _bookingFieldsBaseOnly,
      _commissionFields,
    ];
  }
  // PRODUCT: product commission + listing fee + the shared subscription &
  // activation (every provider pays the one-time activation and, where enabled,
  // the monthly subscription, regardless of what they sell).
  return [
    _productFields,
    _commissionFields,
  ];
}

/// Which fee model applies to [category].
_FeeModel _feeModelForCategory(Map<String, dynamic> category) {
  final sector = (category['sector'] as String?) ?? '';
  final marketplaceSector =
      (category['marketplace_sector'] as String?) ?? '';
  final name = (category['name'] as String?) ?? '';
  final slug = (category['slug'] as String?) ?? '';

  // SERVICE sector categories whose marketplace_sector is ACCOMMODATION =
  // stay/hotel. No per-km fields, ever.
  if (marketplaceSector == 'ACCOMMODATION') return _FeeModel.stay;

  // SERVICE sector categories whose marketplace_sector is SERVICES =
  // booked appointments / call-outs / slots: barber, plumber, doctor,
  // gym lesson … Booking fares (base + minimum), no per-km.
  if (sector == 'SERVICE' && marketplaceSector == 'SERVICES') {
    return _FeeModel.serviceBook;
  }

  // Any category that is product-based on the shelf =
  // PRODUCT model. This is the FOOD / RETAIL / OTHER SERVICE categories and
  // any SERVICE subcategory that is product-based (grocery, clothing …).
  // The app seeds these with service_group = 'PRODUCT_BASED', so that is the
  // honest signal.
  final serviceGroup = (category['service_group'] as String?) ?? '';
  if (serviceGroup == 'PRODUCT_BASED') return _FeeModel.product;

  // VEHICLE sector: a dispatchable trip OR a fixed route. Split by slug/name
  // because the seed does not carry a per-vehicle fee-model column today.
  if (sector == 'VEHICLE') {
    final key = (slug + '|' + name).toLowerCase();
    // Fixed-route / scheduled / heavy transport: per-km rides still apply,
    // but the model label differs so an admin can tell a bus from a taxi.
    if (key.contains('bus') ||
        key.contains('minibus') ||
        key.contains('truck') ||
        key.contains('freight') ||
        key.contains('cargo') ||
        key.contains('tour') ||
        key.contains('travel') ||
        key.contains('ambulance') ||
        key.contains('airport')) {
      return _FeeModel.fixedRoute;
    }
    // Everything else in VEHICLE is a dispatched trip priced by km: ride-taxi,
    // motorcycle-bajaj, car-rental, delivery-vehicle, food-delivery, etc.
    return _FeeModel.ride;
  }

  // Any SERVICE category that landed here (unclassified sector) but is
  // clearly bookable == service booking. Fall back to booking fares.
  if (sector == 'SERVICE') return _FeeModel.serviceBook;

  // Absolute fallback: treat as a ride-priced model so the editor is never
  // empty for a category we do not recognise.
  return _FeeModel.ride;
}

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
      // `p_booking_base_fee`, not `..._fare`. PostgREST matches named
      // arguments by name, so this one-letter slip was a PGRST202 on every
      // save -- which the error mapper renders as "the category may have
      // been removed", which is what sent this whole audit down the wrong
      // path. The database has declared it `_fee` since 0107.
      param: 'p_booking_base_fee',
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

/// Booking fields WITHOUT per-km. Used for stay/hotel and service-booking
/// models, where a distance dimension is the wrong shape.
const List<_FeeField> _bookingFieldsBaseOnly = [
  _FeeField(
      param: 'p_booking_base_fee',
      label: 'Booking base fee',
      column: 'booking_base_fare'),
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

// Mutable simulator state, one per fee model, so the admin can tune the
// example inputs for each model without saving anything.
class _SimState {
  _SimState();
  final distanceCtrl = TextEditingController(text: '5');
  final nightsCtrl = TextEditingController(text: '1');
  final amountCtrl = TextEditingController(text: '1000');
  String city = '';
  double distance = 5;
  int nights = 1;
  double amount = 1000;
  String? error;
  _SimResult? result;
}

class _SimResult {
  _SimResult(this.lines);
  final List<String> lines;
}

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

  /// The category the admin is currently editing, as a row from
  /// admin_category_fee_catalogue (category_id, name, sector, marketplace_sector,
  /// service_group, …). Null when no category is selected.
  Map<String, dynamic>? _category;

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
      // Read the editor flag BEFORE the setState, not after it.
      //
      // This was:
      //
      //   setState(() { _rows = ...; _loading = false; });
      //   _canEdit = await _readEditorFlag();
      //
      // A field assigned after the last setState does not rebuild anything, so
      // `_canEdit` stayed false forever. Every control gated on it was dead:
      // the category dropdown's `onChanged` was null, so no category could
      // ever be selected, no fee section ever rendered, and the screen showed
      // "Only the account owner can change what the platform charges" -- to
      // the account owner. The whole editor was unusable and looked like a
      // dead card in the sidebar.
      final canEdit = await _readEditorFlag();
      if (!mounted) return;
      setState(() {
        _rows = List<Map<String, dynamic>>.from(rows as List);
        _canEdit = canEdit;
        _loading = false;
      });
      // The simulator shows effective numbers; once the catalogue is fresh,
      // recompute so the preview reflects the current rates.
      _recomputeSim();
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

  /// The fee model for the selected category, derived from the category's own
  /// sector / marketplace_sector / service_group. Null when no category is
  /// selected, so the form stays empty rather than falling back to a wrong model.
  _FeeModel? get _model {
    final cat = _category;
    if (cat == null) return null;
    return _feeModelForCategory(cat);
  }

  /// The fields that apply to the selected category's fee model. Empty until a
  /// category is selected, so the form stays empty rather than showing every
  /// field for every category.
  List<List<_FeeField>> get _modelFields {
    final m = _model;
    if (m == null) return [];
    return _fieldsForModel(m);
  }

  String get _modelLabel {
    final m = _model;
    if (m == null) return '';
    return switch (m) {
      _FeeModel.ride => 'Ride / taxi (per km)',
      _FeeModel.fixedRoute => 'Fixed-route transport (per km)',
      _FeeModel.stay => 'Stay / hotel (per night)',
      _FeeModel.serviceBook => 'Service booking',
      _FeeModel.product => 'Shop / products',
    };
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
      _category = null;
      _drafts.clear();
    });
    // Re-read the catalogue row so the form has the category's own fields
    // (sector / marketplace_sector / service_group) for the fee-model label
    // and for the simulator, without waiting for a full reload.
    _syncCategory();
    // A new category changes the fee model and the effective rates, so
    // recompute the preview once the row is known.
    _recomputeSim();
  }

  void _selectCity(String? city) {
    setState(() {
      _city = city ?? '';
      _drafts.clear();
    });
    _recomputeSim();
  }

  /// The category row (with sector / marketplace_sector / service_group)
  /// for the currently selected category, looked up from the cached catalogue.
  void _syncCategory() {
    if (_categoryId == null) return;
    for (final r in _rows) {
      if (r['category_id'] == _categoryId) {
        setState(() => _category = r);
        return;
      }
    }
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
        for (final group in _modelFields)
          for (final f in group)
            f.param: parse(f.param),
      });
      if (!mounted) return;
      // The effective numbers just changed, so the row behind the form is
      // stale. Re-read rather than guessing what the new fallback resolves to.
      await _load();
      if (!mounted) return;
      setState(() => _drafts.clear());
      _snack('Saved. The next charge uses the new rate.');
      _recomputeSim();
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
        _recomputeSim();
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
                      const SizedBox(height: 8),
                      _modelBanner(),
                      const SizedBox(height: 14),
                      ..._modelFields.map((fields) => Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: _section(
                            _sectionTitle(fields), fields, current),
                      )),
                      const SizedBox(height: 8),
                      _simulatorSection(current),
                      const SizedBox(height: 18),
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
                  color: AppTheme.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _categoryPicker() {
    final cats = _categories;
    return DropdownButtonFormField<String>(
      initialValue: _categoryId,
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
      initialValue: _city,
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
            .withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: (configured ? AppTheme.primaryGreen : AppTheme.cardBorder)
              .withValues(alpha: 0.5),
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
    if (fields.isEmpty) return const SizedBox.shrink();
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

  /// A human label for a field group's section, derived from the fields.
  /// Used by the simulator and the model-filtered form so section titles stay
  /// in sync with what is actually editable.
  static String _sectionTitle(List<_FeeField> fields) {
    if (fields.isEmpty) return '';
    final labels = fields.map((f) => f.label).toList();
    if (labels.any((l) => l.contains('Base fare') || l.contains('Per kilometre'))) {
      return 'Ride fares';
    }
    if (labels.any((l) => l.contains('Booking base') || l.contains('Booking per km') ||
        l.contains('Booking minimum'))) {
      return labels.any((l) => l.contains('Per km')) ? 'Booking / service fees' : 'Booking fees';
    }
    if (labels.any((l) => l.contains('Product commission') || l.contains('Product minimum') ||
        l.contains('Product listing'))) {
      return 'Products';
    }
    if (labels.any((l) => l.contains('Commission') || l.contains('Minimum commission') ||
        l.contains('Monthly subscription') || l.contains('One-time activation'))) {
      return 'Commission & subscriptions';
    }
    return '';
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

  Widget _modelBanner() {
    final model = _model;
    if (model == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppTheme.primaryGreen.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.primaryGreen.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(
            _modelIcon(model),
            size: 16,
            color: AppTheme.primaryGreenDark,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Fee model: $_modelLabel',
              style: const TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w600,
                  color: AppTheme.primaryGreenDark),
            ),
          ),
        ],
      ),
    );
  }

  IconData _modelIcon(_FeeModel m) => switch (m) {
        _FeeModel.ride => Icons.directions_car_outlined,
        _FeeModel.fixedRoute => Icons.directions_bus_outlined,
        _FeeModel.stay => Icons.hotel_outlined,
        _FeeModel.serviceBook => Icons.book_online_outlined,
        _FeeModel.product => Icons.shopping_bag_outlined,
      };

  /// The simulator section: pick a category + city, enter the relevant inputs,
  /// and see the same numbers the charge will use.
  Widget _simulatorSection(Map<String, dynamic>? current) {
    final model = _model;
    if (model == null) return const SizedBox.shrink();

    // Simulator inputs: keep the state on the widget so the admin can tune
    // numbers without saving anything.
    final sim = _simStateFor(model);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: AppTheme.surfaceVariant,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.calculate_outlined,
                  size: 16, color: AppTheme.primaryGreenDark),
              const SizedBox(width: 6),
              const Expanded(
                child: Text('Fare & fee preview',
                    style: TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w700)),
              ),
              const Icon(Icons.lightbulb_outline,
                  size: 15, color: AppTheme.textMuted),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'What the current rates would charge for an example — the same '
            'resolvers the real charge uses. This does not save anything.',
            style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
          ),
          const SizedBox(height: 12),
          _simInputs(sim, model),
          const SizedBox(height: 12),
          if (sim.error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                sim.error!,
                style: const TextStyle(
                    fontSize: 12, color: AppTheme.error),
              ),
            ),
          if (sim.result != null) _simResult(sim.result!),
        ],
      ),
    );
  }

  /// The simulator inputs for a given fee model.
  _SimState _simStateFor(_FeeModel model) {
    final sim = _simStates.putIfAbsent(model, () => _SimState());
    return sim;
  }

  final Map<_FeeModel, _SimState> _simStates = const {};

  Widget _simInputs(_SimState sim, _FeeModel model) {
    final fields = _modelFields;
    final hasRide = fields
        .expand((g) => g)
        .any((f) => f.param == 'p_ride_per_km');
    final hasBookingKm = fields
        .expand((g) => g)
        .any((f) => f.param == 'p_booking_per_km');
    final hasProduct = fields
        .expand((g) => g)
        .any((f) => f.param == 'p_product_commission_percent');
    final hasListing = fields
        .expand((g) => g)
        .any((f) => f.param == 'p_product_listing_fee');

    final children = <Widget>[];

    // Distance (for ride / fixed-route / service-booking-with-per-km models).
    if (hasRide || hasBookingKm) {
      children.addAll([
        const Text('Distance (km)',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        _simField(
          controller: sim.distanceCtrl,
          label: 'Trip distance',
          suffix: 'km',
          onChanged: (v) {
            final d = double.tryParse(v);
            setState(() {
              sim.distance = d ?? 0;
              sim.distanceCtrl.text =
                  d == null ? '' : d.toString();
            });
            _recomputeSim();
          },
        ),
        const SizedBox(height: 10),
      ]);
    }

    // Nights (stay / hotel model).
    if (model == _FeeModel.stay) {
      children.addAll([
        const Text('Stay', style: TextStyle(
            fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        _simField(
          controller: sim.nightsCtrl,
          label: 'Nights',
          suffix: 'nights',
          keyboardType: TextInputType.number,
          onChanged: (v) {
            final n = int.tryParse(v);
            setState(() {
              sim.nights = n ?? 0;
              sim.nightsCtrl.text = n == null ? '' : n.toString();
            });
            _recomputeSim();
          },
        ),
        const SizedBox(height: 10),
      ]);
    }

    // Gross amount (for product / commission models where the commission is a
    // percentage of the sale).
    if (hasProduct || hasListing) {
      children.addAll([
        const Text('Sale', style: TextStyle(
            fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        _simField(
          controller: sim.amountCtrl,
          label: 'Sale amount',
          suffix: 'ETB',
          onChanged: (v) {
            final a = double.tryParse(v);
            setState(() {
              sim.amount = a ?? 0;
              sim.amountCtrl.text =
                  a == null ? '' : a.toString();
            });
            _recomputeSim();
          },
        ),
        const SizedBox(height: 10),
      ]);
    }

    // City selector for the simulator so the admin can see a city-specific
    // number without first saving an override.
    children.addAll([
      const Text('City (optional)', style: TextStyle(
          fontSize: 12, fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      _simCityField(sim),
      const SizedBox(height: 6),
    ]);

    return Wrap(
      spacing: 12,
      runSpacing: 8,
      children: children,
    );
  }

  /// Recompute the simulator preview for the currently selected model.
  /// Safe to call any time; it is a best-effort server read.
  void _recomputeSim() {
    if (_categoryId == null) return;
    // Defer so we do not block the current frame and so we do not issue a
    // cascade of RPCs while the admin is typing fast.
    Future.microtask(() => _computeSimFromState());
  }

  Future<void> _computeSimFromState() async {
    final model = _model;
    final current = _current;
    if (model == null || current == null) return;
    final result = await _computeSim(current, model);
    if (!mounted) return;
    setState(() {
      _simStates[model]?.result = result;
      _simStates[model]?.error = null;
    });
  }

  Widget _simField({
    required TextEditingController controller,
    required String label,
    required String suffix,
    TextInputType keyboardType = const TextInputType.numberWithOptions(
        decimal: true),
    required ValueChanged<String> onChanged,
  }) {
    return SizedBox(
      width: 150,
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
        ],
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          suffixText: suffix,
        ),
        onChanged: onChanged,
      ),
    );
  }

  Widget _simCityField(_SimState sim) {
    final options = <String>['', ..._configuredCities];
    for (final c in cities.cities) {
      if (!options.contains(c.toLowerCase())) options.add(c.toLowerCase());
    }
    return SizedBox(
      width: 150,
      child: DropdownButtonFormField<String>(
        initialValue: sim.city,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'Preview city',
          isDense: true,
        ),
        items: options
            .map((c) {
              return DropdownMenuItem<String>(
                value: c,
                child: Text(
                  c.isEmpty ? 'All cities' : _titleCase(c),
                  overflow: TextOverflow.ellipsis,
                ),
              );
            })
            .toList(),
        onChanged: (v) => setState(() {
          sim.city = v ?? '';
          sim.result = null;
        }),
      ),
    );
  }

  Widget _simResult(_SimResult result) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppTheme.primaryGreen.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.primaryGreen.withValues(alpha: 0.30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Preview',
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700,
                  color: AppTheme.primaryGreenDark)),
          const SizedBox(height: 6),
          for (final line in result.lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                line,
                style: const TextStyle(
                    fontSize: 12, color: AppTheme.textPrimary),
              ),
            ),
        ],
      ),
    );
  }

  /// Computes the simulator preview from the current effective rates and the
  /// admin's example inputs, using the same server resolvers the charge uses.
  /// Best-effort: a failed lookup shows nothing rather than a wrong number.
  Future<_SimResult?> _computeSim(
      Map<String, dynamic>? current, _FeeModel model) async {
    final sim = _simStates[model]!;
    final catId = _categoryId;
    if (catId == null) return null;

    final city = sim.city;

    // Round-trip to the server's resolvers so the preview is the same number
    // the charge will use. Each resolver is read inside try/catch so a missing
    // function on an older deployment degrades to "preview unavailable" rather
    // than crashing the editor.
    num? rideBase, ridePerKm, rideMin, bookingBase, bookingPerKm, bookingMin;
    num? commissionPct, commissionMin, subscription, activation;
    num? productCommissionPct, productCommissionMin, listingFee;

    try {
      rideBase = await _rpcNum('fee_ride_base_fare', catId, city);
      ridePerKm = await _rpcNum('fee_ride_per_km', catId, city);
      rideMin = await _rpcNum('fee_ride_minimum_fare', catId, city);
    } catch (_) {}

    try {
      bookingBase = await _rpcNum('fee_booking_base_fare', catId, city);
      bookingPerKm = await _rpcNum('fee_booking_per_km', catId, city);
      bookingMin = await _rpcNum('fee_booking_minimum_fee', catId, city);
    } catch (_) {}

    try {
      commissionPct = await _rpcNum('fee_commission_percent', catId, city, false);
      commissionMin = await _rpcNum('fee_commission_min', catId, city, false);
      productCommissionPct =
          await _rpcNum('fee_commission_percent', catId, city, true);
      productCommissionMin =
          await _rpcNum('fee_commission_min', catId, city, true);
    } catch (_) {}

    try {
      subscription = await _rpcNum('fee_subscription', catId, city);
      activation = await _rpcNum('fee_activation', catId, city);
    } catch (_) {}

    try {
      listingFee = await _rpcNumForProduct(catId, city);
    } catch (_) {}

    final effectiveCommissionPct =
        commissionPct ?? _effectiveFromRow(current, 'commission_percent');
    final effectiveCommissionMin =
        commissionMin ?? _effectiveFromRow(current, 'commission_min');
    final effectiveSubscription =
        subscription ?? _effectiveFromRow(current, 'subscription_fee');
    final effectiveActivation =
        activation ?? _effectiveFromRow(current, 'activation_fee');
    final effectiveProductCommissionPct =
        productCommissionPct ?? _effectiveFromRow(current, 'product_commission_percent');
    final effectiveProductCommissionMin =
        productCommissionMin ?? _effectiveFromRow(current, 'product_commission_min');
    final effectiveListingFee =
        listingFee ?? _effectiveFromRow(current, 'product_listing_fee');

    final lines = <String>[];
    final errors = <String>[];

    // Ride fare estimate (only for models that have ride fields).
    if (model == _FeeModel.ride || model == _FeeModel.fixedRoute) {
      if (rideBase != null && ridePerKm != null && rideMin != null) {
        final fare = _rideFare(base: rideBase, perKm: ridePerKm, min: rideMin, km: sim.distance);
        lines.add('Ride fare: ETB ${fare.toStringAsFixed(2)} '
            '(${_fmtKm(sim.distance)} → base ETB ${rideBase.toDouble().toStringAsFixed(2)} '
            '+ ${ridePerKm.toDouble().toStringAsFixed(2)}/km, floor ETB ${rideMin.toDouble().toStringAsFixed(2)})');
      } else {
        errors.add('Ride fare preview unavailable');
      }
    }

    // Booking fare (stay / service booking / ride models that also expose
    // booking fields).
    if (bookingBase != null && bookingMin != null) {
      final isPerKm = bookingPerKm != null && sim.distance > 0;
      final fare = isPerKm
          ? _bookingFare(base: bookingBase, perKm: bookingPerKm, min: bookingMin, km: sim.distance)
          : ( sim.distance > 0
              ? bookingBase.toDouble() + (bookingPerKm?.toDouble() ?? 0) * sim.distance
              : bookingBase.toDouble());
      lines.add('Booking fee: ETB ${fare.toStringAsFixed(2)} '
          '(base ETB ${bookingBase.toDouble().toStringAsFixed(2)}'
          '${isPerKm ? ', ${bookingPerKm.toDouble().toStringAsFixed(2)}/km' : ''}'
          ', floor ETB ${bookingMin.toDouble().toStringAsFixed(2)})');
    } else if (model == _FeeModel.stay) {
      // Hotels: show the booking base as the per-booking fee.
      if (bookingBase != null) {
      lines.add('Booking fee: ETB ${bookingBase.toDouble().toStringAsFixed(2)} '
          '(per booking, no per-km)');
      }
    }

    // Commission.
    if (effectiveCommissionPct != null) {
      final onSale = sim.amount > 0 ? sim.amount : 100;
      final commission = _commission(amount: onSale, percent: effectiveCommissionPct, min: effectiveCommissionMin ?? 0);
      lines.add('Commission on ETB ${onSale.toStringAsFixed(2)}: ETB ${commission.toStringAsFixed(2)} '
          '(${_fmtPct(effectiveCommissionPct.toDouble())}'
          '${effectiveCommissionMin != null && effectiveCommissionMin > 0 ? ', min ETB ${effectiveCommissionMin.toDouble().toStringAsFixed(2)}' : ''}',);
    }

    // Product commission + listing fee.
    if (effectiveProductCommissionPct != null && sim.amount > 0) {
      final commission = _commission(amount: sim.amount, percent: effectiveProductCommissionPct, min: effectiveProductCommissionMin ?? 0);
      lines.add('Product commission on ETB ${sim.amount.toStringAsFixed(2)}: ETB ${commission.toStringAsFixed(2)} '
          '(${_fmtPct(effectiveProductCommissionPct.toDouble())}'
          '${effectiveProductCommissionMin != null && effectiveProductCommissionMin > 0 ? ', min ETB ${effectiveProductCommissionMin.toDouble().toStringAsFixed(2)}' : ''}',);
    }
    if (effectiveListingFee != null && effectiveListingFee.toDouble() > 0) {
      lines.add('Listing fee: ETB ${effectiveListingFee.toDouble().toStringAsFixed(2)} (per listing)');
    }

    // Subscription + activation (shown for every model).
    if (effectiveSubscription != null && effectiveSubscription.toDouble() > 0) {
      lines.add('Monthly subscription: ETB ${effectiveSubscription.toDouble().toStringAsFixed(2)}');
    }
    if (effectiveActivation != null && effectiveActivation.toDouble() > 0) {
      lines.add('One-time activation: ETB ${effectiveActivation.toDouble().toStringAsFixed(2)}');
    }

    if (lines.isEmpty && errors.isNotEmpty) {
      return _SimResult([]);
    }
    return _SimResult(lines);
  }

  double _rideFare({required num base, required num perKm, required num min, required num km}) {
    final raw = base + perKm * km;
    return (raw > min ? raw : min).toDouble();
  }

  double _bookingFare({required num base, required num perKm, required num min, required num km}) {
    final raw = base + perKm * km;
    return (raw > min ? raw : min).toDouble();
  }

  double _commission({required num amount, required num percent, required num min}) {
    final pct = amount * percent / 100.0;
    return (pct > min ? pct : min).toDouble();
  }

  double? _effectiveFromRow(Map<String, dynamic>? row, String column) {
    final v = row?[column];
    return v is num ? v.toDouble() : null;
  }

  Future<num?> _rpcNum(String fn, String catId, String city,
      [bool isProduct = false]) async {
    try {
      final res = await Supabase.instance.client.rpc(fn, params: {
        'p_category_id': catId,
        'p_city': city,
        if (isProduct) 'p_is_product': true,
      });
      if (res is double) return res;
      if (res is int) return res.toDouble();
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<num?> _rpcNumForProduct(String catId, String city) async {
    return _rpcNum('fee_commission_percent', catId, city, true);
  }

  String _fmtKm(num km) =>
      km == km.roundToDouble() ? km.toInt().toString() : km.toStringAsFixed(1);

  String _fmtPct(num pct) =>
      pct == pct.truncateToDouble() ? pct.toInt().toString() : pct.toStringAsFixed(2);

  Widget _actions(bool configured, bool dirty) {
    if (!_canEdit) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.warning.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
        ),            child: Row(
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
