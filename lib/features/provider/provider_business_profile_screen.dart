import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/birr_text_field.dart';
import '../../core/widgets/primary_button.dart';
import '../../core/services/location_service.dart';
import '../../core/utils/friendly_error.dart';

class ProviderBusinessProfileScreen extends StatefulWidget {
  const ProviderBusinessProfileScreen({super.key});
  @override
  State<ProviderBusinessProfileScreen> createState() => _State();
}

class _State extends State<ProviderBusinessProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  String? _selectedCategoryId;
  List<Map<String, dynamic>> _categories = [];
  Map<String, dynamic>? _profile;
  bool _loading = true;
  bool _saving = false;

  // Business GPS (used for buyer distance calculations and directions).
  double? _lat;
  double? _lng;
  bool _capturingGps = false;
  String? _gpsMessage;

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
          .select()
          .eq('user_id', userId)
          .eq('provider_type', 'SERVICE_PROVIDER')
          .maybeSingle();
      final cats = await client
          .from('categories')
          .select('id,name')
          .eq('sector', 'SERVICE')
          .isFilter('parent_id', null)
          .eq('is_active', true)
          .order('name');
      if (mounted) {
        setState(() {
          _profile = prov;
          _categories = List<Map<String, dynamic>>.from(cats as List);
          if (prov != null) {
            _nameCtrl.text = prov['business_name'] ?? '';
            _descCtrl.text = prov['address_text'] ?? '';
            _phoneCtrl.text = '';
            _addressCtrl.text = prov['business_address'] ?? prov['address_text'] ?? '';
            _selectedCategoryId = prov['category_id'];
            _lat = (prov['location_lat'] as num?)?.toDouble();
            _lng = (prov['location_lng'] as num?)?.toDouble();
          }
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      if (userId == null || _profile == null) return;
      await client.from('provider_profiles').update({
        'business_name': _nameCtrl.text.trim(),
        'business_address': _addressCtrl.text.trim(),
        'category_id': _selectedCategoryId,
        'location_lat': _lat,
        'location_lng': _lng,
      }).eq('id', _profile!['id']);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Profile updated')));
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(friendlyError(e, context: 'Could not save your business profile'))));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Capture the real device GPS as the business location so buyers see
  /// accurate distance and can navigate here.
  Future<void> _useCurrentLocation() async {
    setState(() {
      _capturingGps = true;
      _gpsMessage = null;
    });
    final r = await LocationService.instance.getCurrentPositionDetailed();
    if (!mounted) return;
    if (r.success) {
      setState(() {
        _lat = r.position!.latitude;
        _lng = r.position!.longitude;
        _capturingGps = false;
        _gpsMessage =
            'Set: ${_lat!.toStringAsFixed(5)}, ${_lng!.toStringAsFixed(5)}';
      });
    } else {
      setState(() {
        _capturingGps = false;
        _gpsMessage = r.status == LocationStatus.deniedForever ||
                r.status == LocationStatus.serviceDisabled
            ? 'Enable location in settings first'
            : 'Could not get GPS — try again';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Business Profile')),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Form(
                key: _formKey,
                child: Column(
                  children: [
                    BirrTextField(
                      label: 'Business Name',
                      controller: _nameCtrl,
                      validator: (v) =>
                          v == null || v.trim().isEmpty ? 'Required' : null,
                    ),
                    const SizedBox(height: 16),
                    BirrTextField(
                      label: 'Address',
                      controller: _addressCtrl,
                      maxLines: 2,
                    ),
                    const SizedBox(height: 12),
                    // Business GPS capture row
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppTheme.creamDark,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.place_outlined,
                              size: 20, color: AppTheme.primaryGreen),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _lat != null && _lng != null
                                  ? '${_lat!.toStringAsFixed(5)}, ${_lng!.toStringAsFixed(5)}'
                                  : 'No GPS location set yet',
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                          TextButton.icon(
                            onPressed: _capturingGps ? null : _useCurrentLocation,
                            icon: _capturingGps
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: AppTheme.primaryGreen))
                                : const Icon(Icons.my_location, size: 16),
                            label: const Text('Use GPS'),
                          ),
                        ],
                      ),
                    ),
                    if (_gpsMessage != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(_gpsMessage!,
                            style: const TextStyle(
                                fontSize: 12, color: AppTheme.textMuted)),
                      ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      value: _selectedCategoryId,
                      decoration: const InputDecoration(
                          labelText: 'Category'),
                      items: _categories
                          .map((c) => DropdownMenuItem(
                              value: c['id'] as String,
                              child: Text(c['name'] ?? '')))
                          .toList(),
                      onChanged: (v) =>
                          setState(() => _selectedCategoryId = v),
                    ),
                    const SizedBox(height: 16),
                    BirrTextField(
                      label: 'Description',
                      controller: _descCtrl,
                      maxLines: 3,
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      child: PrimaryButton(
                        label: 'SAVE PROFILE',
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
