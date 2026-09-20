import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/birr_text_field.dart';
import '../../core/widgets/primary_button.dart';
import '../../core/services/provider_activation_service.dart';

class VehicleFormScreen extends StatefulWidget {
  final String? vehicleId;
  const VehicleFormScreen({super.key, this.vehicleId});
  @override
  State<VehicleFormScreen> createState() => _State();
}

class _State extends State<VehicleFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _brandCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  final _plateCtrl = TextEditingController();
  final _colorCtrl = TextEditingController();
  final _capacityCtrl = TextEditingController();
  String? _categoryId;
  List<Map<String, dynamic>> _categories = [];
  String? _providerId;
  bool _loading = true;
  bool _saving = false;
  // One-time activation gate: the registration fee must be paid (via the
  // first wallet recharge) before uploading vehicles/listings.
  bool _registrationFeePaid = true;
  String _activationMessage = '';
  bool get _isEdit => widget.vehicleId != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      if (userId == null) return;
      final prov = await client
          .from('provider_profiles')
          .select('id')
          .eq('user_id', userId)
          .eq('provider_type', 'VEHICLE_PROVIDER')
          .maybeSingle();
      if (prov == null) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      _providerId = prov['id'];
      // Activation gate (non-fatal: form stays usable if the check fails).
      try {
        final activation = await ProviderActivation.load();
        if (activation != null && !activation.isActivated) {
          _registrationFeePaid = false;
          _activationMessage = activation.blockingMessage;
        }
      } catch (_) {}
      final cats = await client
          .from('categories')
          .select('id,name')
          .eq('sector', 'VEHICLE')
          .eq('is_active', true)
          .order('name');
      _categories = List<Map<String, dynamic>>.from(cats as List);

      if (_isEdit) {
        final v = await client
            .from('vehicles')
            .select()
            .eq('id', widget.vehicleId!)
            .single();
        _brandCtrl.text = v['brand'] ?? '';
        _modelCtrl.text = v['model'] ?? '';
        _plateCtrl.text = v['plate_number'] ?? '';
        _colorCtrl.text = v['color'] ?? '';
        _capacityCtrl.text = '${v['capacity'] ?? ''}';
        _categoryId = v['category_id'];
      }
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_providerId == null) return;
    // Block uploads until the one-time registration fee is paid.
    if (!_registrationFeePaid) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(_activationMessage),
        backgroundColor: AppTheme.error,
        duration: const Duration(seconds: 4),
      ));
      return;
    }
    setState(() => _saving = true);
    try {
      final client = Supabase.instance.client;
      final capacity = int.tryParse(_capacityCtrl.text);
      final data = {
        'brand': _brandCtrl.text.trim(),
        'model': _modelCtrl.text.trim(),
        'plate_number': _plateCtrl.text.trim(),
        'color': _colorCtrl.text.trim(),
        'capacity': capacity,
        'category_id': _categoryId,
      };
      if (_isEdit) {
        await client.from('vehicles').update(data).eq('id', widget.vehicleId!);
      } else {
        data['provider_id'] = _providerId;
        data['status'] = 'PENDING_APPROVAL';
        data['is_available'] = false;
        await client.from('vehicles').insert(data);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(_isEdit ? 'Vehicle updated' : 'Vehicle added')));
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'Edit Vehicle' : 'Add Vehicle')),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.teal))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Form(
                key: _formKey,
                child: Column(
                  children: [
                    BirrTextField(
                      label: 'Brand',
                      controller: _brandCtrl,
                      validator: (v) =>
                          v == null || v.trim().isEmpty ? 'Required' : null,
                    ),
                    const SizedBox(height: 16),
                    BirrTextField(
                      label: 'Model',
                      controller: _modelCtrl,
                    ),
                    const SizedBox(height: 16),
                    BirrTextField(
                      label: 'Plate Number',
                      controller: _plateCtrl,
                      validator: (v) =>
                          v == null || v.trim().isEmpty ? 'Required' : null,
                    ),
                    const SizedBox(height: 16),
                    BirrTextField(label: 'Color', controller: _colorCtrl),
                    const SizedBox(height: 16),
                    BirrTextField(
                      label: 'Capacity',
                      controller: _capacityCtrl,
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      value: _categoryId,
                      decoration: const InputDecoration(
                          labelText: 'Vehicle Category'),
                      items: _categories
                          .map((c) => DropdownMenuItem(
                              value: c['id'] as String,
                              child: Text(c['name'] ?? '')))
                          .toList(),
                      onChanged: (v) => setState(() => _categoryId = v),
                    ),
                    const SizedBox(height: 24),
                    if (!_registrationFeePaid) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        margin: const EdgeInsets.only(bottom: 16),
                        decoration: BoxDecoration(
                          color: AppTheme.gold.withOpacity(0.10),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: AppTheme.gold.withOpacity(0.45)),
                        ),
                        child: Text(_activationMessage,
                            style: const TextStyle(
                                fontSize: 13,
                                color: AppTheme.textSecondary)),
                      ),
                    ],
                    SizedBox(
                      width: double.infinity,
                      child: PrimaryButton(
                        label: _isEdit ? 'UPDATE VEHICLE' : 'ADD VEHICLE',
                        isLoading: _saving,
                        onPressed: _save,
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
