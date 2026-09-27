import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/birr_text_field.dart';
import '../../core/widgets/primary_button.dart';
import '../../core/services/provider_activation_service.dart';
import '../../core/services/provider_doc_gate.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/load_error_view.dart';

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
  String? _error;
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
    // Clear any previous failure so a successful retry actually recovers.
    if (mounted && _error != null) setState(() => _error = null);
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
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e, context: 'Could not load the form');
        });
      }
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_providerId == null) return;
    // Task 7: one-time document check before the first protected action
    // (registering a vehicle for orders). Happens after wallet recharge.
    if (!(await ProviderDocGate.instance.ensureDocuments(context))) return;
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
        await client.rpc('create_provider_vehicle', params: {
          'p_provider_id': _providerId,
          'p_brand': data['brand'],
          'p_model': data['model'],
          'p_plate_number': data['plate_number'],
          'p_color': data['color'],
          'p_capacity': data['capacity'],
          'p_category_id': data['category_id'],
        });
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(_isEdit ? 'Vehicle updated' : 'Vehicle added')));
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e, context: 'Could not save this vehicle'))));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'Edit Vehicle' : 'Add Vehicle')),
      body: _error != null
          ? LoadErrorView(message: _error!, onRetry: _load)
          : _loading
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
