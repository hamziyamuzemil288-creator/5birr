import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/birr_text_field.dart';
import '../../core/widgets/load_error_view.dart';
import '../../core/widgets/primary_button.dart';

/// Reached from the admin sidebar as "Category Fields".
///
/// This is the CONTROL for the provider's settings form: it decides what a
/// hotel is asked for (room types, a nightly rate), what a doctor is asked for
/// (an hourly price, the services offered), and what every other trade is
/// asked for. Before it existed, all 118 categories shared one five-field
/// form, so nobody could ask a hotel for its room types.
///
/// The definitions are SEEDED per marketplace sector by the migration, which is
/// why this screen opens on a populated list rather than an empty one. Nothing
/// here is required to make the provider side work: an unedited category keeps
/// its seeded form.
///
/// Every write goes through a definer RPC that re-checks `is_admin()`. This
/// screen is navigation and editing, not authority; a staff member who reaches
/// it without the permission gets the server's refusal, not a silent no-op.
class AdminCategoryFieldsScreen extends StatefulWidget {
  const AdminCategoryFieldsScreen({super.key});

  @override
  State<AdminCategoryFieldsScreen> createState() =>
      _AdminCategoryFieldsScreenState();
}

class _AdminCategoryFieldsScreenState extends State<AdminCategoryFieldsScreen> {
  List<Map<String, dynamic>> _categories = const [];
  List<Map<String, dynamic>> _fields = const [];
  String? _categoryId;
  bool _loading = true;
  bool _busy = false;
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
      final cats = await client
          .from('categories')
          .select('id, name, sector, marketplace_sector')
          .isFilter('parent_id', null)
          .eq('is_active', true)
          .order('name');
      final rows = await client.rpc('admin_category_profile_fields');

      final categories = List<Map<String, dynamic>>.from(cats as List);
      if (!mounted) return;
      setState(() {
        _categories = categories;
        _fields = List<Map<String, dynamic>>.from(rows as List);
        _categoryId = _categoryId ??
            (categories.isEmpty ? null : categories.first['id'] as String?);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e, context: 'Could not load category fields');
      });
    }
  }

  /// The rows for the selected category. Filtered on the CLIENT from the full
  /// catalogue rather than re-queried: one read answers every category, so
  /// switching the dropdown is instant and cannot fail independently.
  List<Map<String, dynamic>> get _visibleFields {
    final id = _categoryId;
    if (id == null) return const [];
    return _fields.where((f) => f['category_id'] == id).toList();
  }

  Future<void> _edit({Map<String, dynamic>? existing}) async {
    final categoryId = _categoryId;
    if (categoryId == null) return;

    final result = await showDialog<_FieldDraft>(
      context: context,
      builder: (_) => _FieldDialog(existing: existing),
    );
    if (result == null || !mounted) return;

    setState(() => _busy = true);
    try {
      await Supabase.instance.client.rpc(
        'admin_save_category_profile_field',
        params: {
          'p_category_id': categoryId,
          'p_field_key': result.fieldKey,
          'p_label': result.label,
          'p_input_type': result.inputType,
          'p_unit_label': result.unitLabel,
          'p_help_text': result.helpText,
          'p_is_required': result.isRequired,
          'p_is_price': result.isPrice,
          'p_sort_order': result.sortOrder,
          'p_is_active': result.isActive,
        },
      );
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved "${result.label}"')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(friendlyError(e, context: 'Could not save that field')),
      ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(Map<String, dynamic> field) async {
    final answers = (field['provider_value_count'] as num?)?.toInt() ?? 0;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${field['label']}"?'),
        // The value count is stated before the delete, not discovered after:
        // an administrator removing a field that ten providers have already
        // answered should know that is what they are doing. The answers are
        // kept, not wiped -- the field is only removed from the form.
        content: Text(answers == 0
            ? 'No provider has filled this in yet.'
            : '$answers provider(s) have already filled this in. Their '
                'answers are kept, but the field stops being shown.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: AppTheme.error)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await Supabase.instance.client.rpc(
        'admin_delete_category_profile_field',
        params: {'p_field_id': field['id']},
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(friendlyError(e, context: 'Could not delete that field')),
      ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Category Fields')),
      floatingActionButton: _categoryId == null
          ? null
          : FloatingActionButton.extended(
              onPressed: _busy ? null : () => _edit(),
              backgroundColor: AppTheme.primaryGreen,
              icon: const Icon(Icons.add),
              label: const Text('Add field'),
            ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : _error != null
              ? LoadErrorView(message: _error!, onRetry: _load)
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: DropdownButtonFormField<String>(
                        value: _categoryId,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Category',
                          prefixIcon: Icon(Icons.category_outlined),
                        ),
                        items: _categories
                            .map((c) => DropdownMenuItem<String>(
                                  value: c['id'] as String,
                                  child: Text(
                                    '${c['name']}'
                                    '${c['marketplace_sector'] == null ? '' : ' · ${c['marketplace_sector']}'}',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ))
                            .toList(),
                        onChanged: (v) => setState(() => _categoryId = v),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Providers in this category see these fields in '
                          'Settings & Pricing.',
                          style: AppTheme.caption,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(child: _list()),
                  ],
                ),
    );
  }

  Widget _list() {
    final rows = _visibleFields;
    if (rows.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'This category defines no fields yet.\n'
            'It inherits its parent category\'s form until you add one.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppTheme.textMuted),
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 90),
      itemCount: rows.length,
      itemBuilder: (_, i) {
        final f = rows[i];
        final answers = (f['provider_value_count'] as num?)?.toInt() ?? 0;
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppTheme.cardBorder),
          ),
          child: ListTile(
            title: Row(
              children: [
                Flexible(
                  child: Text(f['label']?.toString() ?? '',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                ),
                if (f['is_required'] == true) ...[
                  const SizedBox(width: 6),
                  const Text('*',
                      style: TextStyle(color: AppTheme.error, fontSize: 14)),
                ],
              ],
            ),
            subtitle: Text(
              '${f['field_key']} · ${f['input_type']}'
              '${f['unit_label'] == null ? '' : ' · ${f['unit_label']}'}'
              ' · $answers answer(s)'
              '${f['is_active'] == true ? '' : ' · hidden'}',
              style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Edit',
                  icon: const Icon(Icons.edit_outlined,
                      size: 18, color: AppTheme.teal),
                  onPressed: _busy ? null : () => _edit(existing: f),
                ),
                IconButton(
                  tooltip: 'Delete',
                  icon: const Icon(Icons.delete_outline,
                      size: 18, color: AppTheme.error),
                  onPressed: _busy ? null : () => _delete(f),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The dialog's result. A plain record-like class so the caller cannot write a
/// half-built map into the RPC.
class _FieldDraft {
  final String fieldKey;
  final String label;
  final String inputType;
  final String? unitLabel;
  final String? helpText;
  final bool isRequired;
  final bool isPrice;
  final int sortOrder;
  final bool isActive;

  const _FieldDraft({
    required this.fieldKey,
    required this.label,
    required this.inputType,
    this.unitLabel,
    this.helpText,
    this.isRequired = false,
    this.isPrice = false,
    this.sortOrder = 0,
    this.isActive = true,
  });
}

class _FieldDialog extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _FieldDialog({this.existing});

  @override
  State<_FieldDialog> createState() => _FieldDialogState();
}

class _FieldDialogState extends State<_FieldDialog> {
  static const _types = ['TEXT', 'NUMBER', 'PRICE', 'BOOLEAN', 'SELECT'];

  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _keyCtrl;
  late final TextEditingController _labelCtrl;
  late final TextEditingController _unitCtrl;
  late final TextEditingController _helpCtrl;
  late final TextEditingController _orderCtrl;
  late String _inputType;
  late bool _isRequired;
  late bool _isPrice;
  late bool _isActive;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _keyCtrl = TextEditingController(text: e?['field_key']?.toString() ?? '');
    _labelCtrl = TextEditingController(text: e?['label']?.toString() ?? '');
    _unitCtrl = TextEditingController(text: e?['unit_label']?.toString() ?? '');
    _helpCtrl = TextEditingController(text: e?['help_text']?.toString() ?? '');
    _orderCtrl = TextEditingController(
        text: (e?['sort_order'] ?? 0).toString());
    _inputType = (e?['input_type']?.toString() ?? 'TEXT');
    if (!_types.contains(_inputType)) _inputType = 'TEXT';
    _isRequired = e?['is_required'] == true;
    _isPrice = e?['is_price'] == true;
    _isActive = e?['is_active'] != false;
  }

  @override
  void dispose() {
    _keyCtrl.dispose();
    _labelCtrl.dispose();
    _unitCtrl.dispose();
    _helpCtrl.dispose();
    _orderCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    return AlertDialog(
      title: Text(editing ? 'Edit field' : 'Add field'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              BirrTextField(
                label: 'Label',
                hint: 'e.g. Price per night',
                controller: _labelCtrl,
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'A label is required'
                    : null,
              ),
              const SizedBox(height: 12),
              BirrTextField(
                label: 'Key',
                hint: 'e.g. price_per_night',
                controller: _keyCtrl,
                enabled: !editing,
                // The key is what answers are filed under, so it cannot be
                // renamed after providers have answered -- that would orphan
                // every value already stored.
                onChanged: (_) => setState(() {}),
                validator: (v) {
                  final key = (v ?? '').trim().toLowerCase();
                  if (!RegExp(r'^[a-z][a-z0-9_]{1,48}$').hasMatch(key)) {
                    return 'Lowercase letters, digits and underscores';
                  }
                  return null;
                },
              ),
              if (editing)
                const Padding(
                  padding: EdgeInsets.only(top: 4, left: 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'The key cannot be changed once it exists.',
                      style:
                          TextStyle(fontSize: 11, color: AppTheme.textMuted),
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _inputType,
                decoration: const InputDecoration(labelText: 'Input type'),
                items: _types
                    .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                    .toList(),
                onChanged: (v) => setState(() {
                  _inputType = v ?? 'TEXT';
                  // A PRICE is a price by definition; keeping the flag in step
                  // here means the admin cannot create a PRICE that does not
                  // count as pricing, which the server would silently correct
                  // anyway.
                  if (_inputType == 'PRICE') _isPrice = true;
                }),
              ),
              const SizedBox(height: 12),
              BirrTextField(
                label: 'Unit (optional)',
                hint: 'e.g. ETB / night',
                controller: _unitCtrl,
              ),
              const SizedBox(height: 12),
              BirrTextField(
                label: 'Help text (optional)',
                hint: 'Shown under the field',
                controller: _helpCtrl,
              ),
              const SizedBox(height: 12),
              BirrTextField(
                label: 'Order',
                controller: _orderCtrl,
                keyboardType: TextInputType.number,
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return null;
                  return int.tryParse(v.trim()) == null
                      ? 'A whole number'
                      : null;
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _isRequired,
                activeColor: AppTheme.primaryGreen,
                title: const Text('Required', style: TextStyle(fontSize: 14)),
                onChanged: (v) => setState(() => _isRequired = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _isPrice,
                activeColor: AppTheme.primaryGreen,
                title: const Text('Counts as pricing',
                    style: TextStyle(fontSize: 14)),
                onChanged: (v) => setState(() => _isPrice = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _isActive,
                activeColor: AppTheme.primaryGreen,
                title: const Text('Shown to providers',
                    style: TextStyle(fontSize: 14)),
                onChanged: (v) => setState(() => _isActive = v),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        SizedBox(
          child: PrimaryButton(
            label: editing ? 'SAVE' : 'ADD',
            onPressed: () {
              if (!_formKey.currentState!.validate()) return;
              Navigator.pop(
                context,
                _FieldDraft(
                  fieldKey: _keyCtrl.text.trim().toLowerCase(),
                  label: _labelCtrl.text.trim(),
                  inputType: _inputType,
                  unitLabel: _unitCtrl.text.trim().isEmpty
                      ? null
                      : _unitCtrl.text.trim(),
                  helpText: _helpCtrl.text.trim().isEmpty
                      ? null
                      : _helpCtrl.text.trim(),
                  isRequired: _isRequired,
                  isPrice: _isPrice,
                  sortOrder: int.tryParse(_orderCtrl.text.trim()) ?? 0,
                  isActive: _isActive,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
