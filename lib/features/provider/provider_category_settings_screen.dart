import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/birr_text_field.dart';
import '../../core/widgets/load_error_view.dart';
import '../../core/widgets/primary_button.dart';

/// The settings and pricing form for a provider's OWN trade.
///
/// Every provider used to get the same five fields on one Business Profile
/// screen, whatever they sold: a hotel had nowhere to say what rooms it has
/// and at what nightly rate, and a doctor had nowhere to put an hourly price.
/// The fields here are defined per category by an administrator
/// (migration 20260927000128) and the server decides which set this provider
/// is shown, so this screen never has to guess.
///
/// Two things it deliberately does NOT do:
///
///   * it does not write to `provider_profile_field_values` directly. The
///     definer RPC picks the value column from the FIELD's declared type, so a
///     number cannot be stored where a renderer will look for text, and a key
///     this category does not define is refused instead of stored as a value
///     nothing displays.
///   * it does not invent a value to prefill a blank field. An empty box stays
///     empty; the provider's saved answer is the only thing that fills it.
class ProviderCategorySettingsScreen extends StatefulWidget {
  const ProviderCategorySettingsScreen({super.key});

  @override
  State<ProviderCategorySettingsScreen> createState() =>
      _ProviderCategorySettingsScreenState();
}

/// One row of `provider_profile_fields()`.
class _ProfileField {
  final String fieldKey;
  final String label;
  final String inputType;
  final String? unitLabel;
  final String? helpText;
  final bool isRequired;
  final bool isPrice;
  final String? valueText;
  final num? valueNumber;
  final bool? valueBoolean;

  const _ProfileField({
    required this.fieldKey,
    required this.label,
    required this.inputType,
    this.unitLabel,
    this.helpText,
    this.isRequired = false,
    this.isPrice = false,
    this.valueText,
    this.valueNumber,
    this.valueBoolean,
  });

  static _ProfileField fromJson(Map<String, dynamic> j) => _ProfileField(
        fieldKey: (j['field_key'] ?? '') as String,
        label: (j['label'] ?? '') as String,
        inputType: (j['input_type'] ?? 'TEXT') as String,
        unitLabel: j['unit_label'] as String?,
        helpText: j['help_text'] as String?,
        isRequired: j['is_required'] == true,
        isPrice: j['is_price'] == true,
        valueText: j['value_text'] as String?,
        valueNumber: j['value_number'] as num?,
        valueBoolean: j['value_boolean'] as bool?,
      );

  bool get isNumeric => inputType == 'NUMBER' || inputType == 'PRICE';
}

class _ProviderCategorySettingsScreenState
    extends State<ProviderCategorySettingsScreen> {
  List<_ProfileField> _fields = const [];
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, bool> _switches = {};

  /// The trade picker. Populated for the provider's own sector, so a service
  /// provider is never offered a vehicle category (the server refuses it
  /// anyway; showing it would be a control that cannot succeed).
  List<Map<String, dynamic>> _categories = const [];
  String? _categoryId;
  String? _categoryName;
  String? _providerType;

  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = Supabase.instance.client;
      final uid = client.auth.currentUser?.id;
      if (uid == null) {
        setState(() {
          _loading = false;
          _error = 'Please sign in again.';
        });
        return;
      }

      final profile = await client
          .from('provider_profiles')
          .select('provider_type, category_id')
          .eq('user_id', uid)
          .maybeSingle();

      final type = profile?['provider_type'] as String?;
      final categoryId = profile?['category_id'] as String?;

      // The sector list is offered whether or not a category is set yet: a
      // provider whose signup claim failed needs the picker to fix it, and one
      // who simply changed trade needs it to move.
      List<Map<String, dynamic>> categories = const [];
      try {
        final rows = await client
            .from('categories')
            .select('id, name')
            .eq('sector', type == 'VEHICLE_PROVIDER' ? 'VEHICLE' : 'SERVICE')
            .isFilter('parent_id', null)
            .eq('is_active', true)
            .order('name');
        categories = List<Map<String, dynamic>>.from(rows as List);
      } catch (_) {
        categories = const [];
      }

      List<_ProfileField> fields = const [];
      String? name;
      try {
        final rows = await client.rpc('provider_profile_fields');
        fields = List<Map<String, dynamic>>.from(rows as List)
            .map(_ProfileField.fromJson)
            .toList();
      } on PostgrestException catch (e) {
        // NO_PROVIDER_PROFILE is a real state, not a failure: it means this
        // account has no provider row yet (not yet approved, or a user account
        // opened this screen). Saying so is better than an error screen.
        if ((e.message).contains('NO_PROVIDER_PROFILE')) {
          setState(() {
            _loading = false;
            _error = 'This account is not registered as a provider yet.';
          });
          return;
        }
        rethrow;
      }

      if (categoryId != null) {
        for (final c in categories) {
          if (c['id'] == categoryId) name = c['name']?.toString();
        }
      }

      for (final f in _controllers.values) {
        f.dispose();
      }
      _controllers.clear();
      _switches.clear();
      for (final f in fields) {
        if (f.inputType == 'BOOLEAN') {
          _switches[f.fieldKey] = f.valueBoolean ?? false;
        } else {
          _controllers[f.fieldKey] = TextEditingController(
            text: f.isNumeric
                ? (f.valueNumber == null ? '' : _trimNumber(f.valueNumber!))
                : (f.valueText ?? ''),
          );
        }
      }

      if (!mounted) return;
      setState(() {
        _fields = fields;
        _categories = categories;
        _categoryId = categoryId;
        _categoryName = name;
        _providerType = type;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e, context: 'Could not load your settings');
      });
    }
  }

  /// A whole number prints without a trailing `.0`, because a price shown as
  /// "500.00" in an input box reads as a different claim from "500".
  static String _trimNumber(num n) {
    if (n == n.roundToDouble()) return n.round().toString();
    return n.toString();
  }

  Future<void> _saveCategory(String? value) async {
    if (value == null || value == _categoryId) return;
    final previous = _categoryId;
    setState(() => _categoryId = value);
    try {
      await Supabase.instance.client
          .rpc('provider_claim_category', params: {'p_category_id': value});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Category updated')),
      );
      // The fields belong to the category, so a change means a NEW form.
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _categoryId = previous);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                friendlyError(e, context: 'Could not change your category'))),
      );
    }
  }

  /// Save every field, then report how many actually landed.
  ///
  /// Sequential rather than concurrent on purpose: each call is its own
  /// transaction and its own refusal, and firing ten at once makes the failure
  /// the provider sees depend on which one lost the race.
  Future<void> _save() async {
    setState(() => _saving = true);
    final client = Supabase.instance.client;
    var saved = 0;
    String? firstProblem;
    try {
      for (final f in _fields) {
        final params = <String, dynamic>{
          'p_field_key': f.fieldKey,
          if (f.inputType == 'BOOLEAN')
            'p_value_boolean': _switches[f.fieldKey] ?? false
          else
            'p_value_text': _controllers[f.fieldKey]?.text.trim() ?? '',
        };
        try {
          await client.rpc('save_provider_profile_field', params: params);
          saved++;
        } catch (e) {
          final message = friendlyError(e, context: 'Could not save ${f.label}');
          // A REQUIRED field left blank is the one refusal worth stopping on:
          // everything after it would be saved against a form the provider
          // still has to fix, so the count they are shown would be misleading.
          if (f.isRequired &&
              (e is PostgrestException) &&
              e.message.contains('THIS_FIELD_IS_REQUIRED')) {
            firstProblem = '${f.label} is required.';
            break;
          }
          firstProblem ??= message;
        }
      }

      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      if (firstProblem != null) {
        messenger.showSnackBar(SnackBar(
          content: Text(saved == 0
              ? firstProblem
              : 'Saved $saved of ${_fields.length}. $firstProblem'),
        ));
      } else {
        messenger.showSnackBar(
          SnackBar(content: Text('Saved $saved field(s)')),
        );
      }
      await _load();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings & Pricing')),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : _error != null
              ? LoadErrorView(message: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      _categoryCard(),
                      const SizedBox(height: 20),
                      if (_fields.isEmpty)
                        _emptyState()
                      else ...[
                        const Text('Your details', style: AppTheme.sectionHeader),
                        const SizedBox(height: 4),
                        Text(
                          'These are the fields customers see for your '
                          'category. Set by the platform; fill in your own '
                          'values.',
                          style: AppTheme.caption,
                        ),
                        const SizedBox(height: 16),
                        ..._fields.map(_fieldWidget),
                        const SizedBox(height: 24),
                        SizedBox(
                          width: double.infinity,
                          child: PrimaryButton(
                            label: 'SAVE SETTINGS',
                            isLoading: _saving,
                            onPressed: _save,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
    );
  }

  Widget _categoryCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.storefront_outlined,
                  size: 18, color: AppTheme.primaryGreen),
              const SizedBox(width: 8),
              const Text('Your category',
                  style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 10),
          if (_categories.isEmpty)
            Text(
              _categoryName ??
                  'Not set. It will be chosen when your account is reviewed.',
              style: const TextStyle(fontSize: 13, color: AppTheme.textMuted),
            )
          else
            DropdownButtonFormField<String>(
              value: _categoryId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'What you provide',
                prefixIcon: Icon(Icons.category_outlined),
              ),
              items: _categories
                  .map((c) => DropdownMenuItem<String>(
                        value: c['id'] as String,
                        child: Text(c['name']?.toString() ?? '',
                            overflow: TextOverflow.ellipsis),
                      ))
                  .toList(),
              onChanged: _saveCategory,
            ),
          if (_providerType != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Changing this changes the fields below.',
                style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
              ),
            ),
        ],
      ),
    );
  }

  Widget _emptyState() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppTheme.creamDark,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Column(
        children: [
          Icon(Icons.tune, color: AppTheme.textMuted, size: 28),
          SizedBox(height: 10),
          Text(
            'No settings are defined for your category yet.\n'
            'Pick your category above, or check back once the platform has '
            'published its form.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: AppTheme.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _fieldWidget(_ProfileField f) {
    if (f.inputType == 'BOOLEAN') {
      return Container(
        margin: const EdgeInsets.only(bottom: 14),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.cardBorder),
        ),
        child: SwitchListTile(
          value: _switches[f.fieldKey] ?? false,
          activeColor: AppTheme.primaryGreen,
          title: Text(f.label, style: const TextStyle(fontSize: 14)),
          onChanged: (v) => setState(() => _switches[f.fieldKey] = v),
        ),
      );
    }

    final unit = f.unitLabel;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          BirrTextField(
            label: f.isRequired ? '${f.label} *' : f.label,
            hint: f.isNumeric
                ? (unit == null ? '0' : '0 $unit')
                : f.helpText,
            controller: _controllers[f.fieldKey],
            keyboardType:
                f.isNumeric ? TextInputType.number : TextInputType.text,
            // The price flag is what makes a field a PRICE rather than just a
            // number: it is the one the customer's page renders with a
            // currency suffix and the one an admin can see feeds pricing.
            suffixIcon: (f.isPrice && unit != null)
                ? Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Center(
                      widthFactor: 1,
                      child: Text(unit,
                          style: const TextStyle(
                              fontSize: 12, color: AppTheme.textMuted)),
                    ),
                  )
                : null,
          ),
          if (f.helpText != null && f.isNumeric)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4),
              child: Text(f.helpText!,
                  style: const TextStyle(
                      fontSize: 11, color: AppTheme.textMuted)),
            ),
        ],
      ),
    );
  }
}
