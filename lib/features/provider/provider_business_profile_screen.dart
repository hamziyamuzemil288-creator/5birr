import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/birr_text_field.dart';
import '../../core/widgets/primary_button.dart';
import '../../core/services/location_service.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/load_error_view.dart';

class ProviderBusinessProfileScreen extends StatefulWidget {
  const ProviderBusinessProfileScreen({super.key});
  @override
  State<ProviderBusinessProfileScreen> createState() => _State();
}

class _State extends State<ProviderBusinessProfileScreen> {
  /// Public bucket created by 20260927000106. Public because the provider's
  /// public page is reachable by a signed-out customer; the write policies
  /// scope on `auth.uid()::text = (string_to_array(name,'/'))[1]`, which is why
  /// the path below must start with the caller's own uid.
  static const _photoBucket = 'provider-photos';

  final _picker = ImagePicker();
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();

  /// The price this provider asks for, e.g. "50 - 200 ETB".
  ///
  /// `provider_profiles.price_range` has existed since the first schema
  /// snapshot, is projected by the PUBLIC view, and had no editor anywhere in
  /// the app -- so it was always NULL and nothing could ever set it. That is
  /// the "price attaching with it is missing" half of the report: the column
  /// was there, the column was public, and no screen read or wrote it.
  final _priceCtrl = TextEditingController();

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _phoneCtrl.dispose();
    _addressCtrl.dispose();
    _priceCtrl.dispose();
    super.dispose();
  }
  String? _selectedCategoryId;
  String? _photoPath;
  bool _uploadingPhoto = false;
  List<Map<String, dynamic>> _categories = [];
  Map<String, dynamic>? _profile;
  bool _loading = true;
  bool _saving = false;

  // Business GPS (used for buyer distance calculations and directions).
  double? _lat;
  double? _lng;
  bool _capturingGps = false;
  String? _gpsMessage;
  // A failed load left _profile null and the form blank but fully editable,
  // inviting the provider to retype their details — then Save would hit
  // `_profile!['id']` and fail on a null check. Never show an editable form
  // we could not populate.
  String? _error;

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
            _priceCtrl.text = prov['price_range'] ?? '';
            _selectedCategoryId = prov['category_id'];
            _photoPath = prov['photo_storage_path'] as String?;
            _lat = (prov['location_lat'] as num?)?.toDouble();
            _lng = (prov['location_lng'] as num?)?.toDouble();
          }
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(
              e, context: 'Could not load your business profile');
        });
      }
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
        // Empty means "not set", and the public page renders nothing in that
        // case rather than an empty pill. Writing NULL rather than '' keeps the
        // column honest for anything that groups on it.
        'price_range': _priceCtrl.text.trim().isEmpty
            ? null
            : _priceCtrl.text.trim(),
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

  /// Upload a shop photo and record it on the provider's own row.
  ///
  /// Saves immediately rather than waiting for SAVE PROFILE: the photo is a
  /// single tap-to-change control, and making it ride along with the text form
  /// would mean a provider who picks a photo and navigates away loses it. The
  /// write is the same direct `.update()` the form already uses --
  /// `provider_profiles` is on the 22-table client allowlist in
  /// 20260927000050, and the guard trigger in 20260927000027 compares only
  /// status / provider_type / owner_national_id, so it cannot see this column.
  Future<void> _pickPhoto() async {
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      // Downscaled, not forwarded: `provider-photos` is 5MB and accepts only
      // jpeg/png/webp, so a forwarded 12MP phone photo or a HEIC is refused
      // inside storage, where it surfaces as a generic upload failure.
      maxWidth: 1920,
      maxHeight: 1920,
      imageQuality: 85,
    );
    if (picked == null || !mounted) return;

    final client = Supabase.instance.client;
    final uid = client.auth.currentUser?.id;
    final profileId = _profile?['id'] as String?;
    if (uid == null || profileId == null) {
      _toast('Please sign in again.');
      return;
    }

    setState(() => _uploadingPhoto = true);
    try {
      final file = File(picked.path);
      final name = Uri.encodeComponent(file.uri.pathSegments.last);
      final path = '$uid/photo/${DateTime.now().microsecondsSinceEpoch}/$name';
      await client.storage
          .from(_photoBucket)
          .upload(path, file, fileOptions: const FileOptions(upsert: true));
      await client
          .from('provider_profiles')
          .update({'photo_storage_path': path})
          .eq('id', profileId);
      if (!mounted) return;
      setState(() => _photoPath = path);
      _toast('Photo updated');
    } catch (e) {
      if (mounted) {
        _toast(friendlyError(e, context: 'Could not upload your photo'));
      }
    } finally {
      if (mounted) setState(() => _uploadingPhoto = false);
    }
  }

  Future<void> _removePhoto() async {
    final client = Supabase.instance.client;
    final profileId = _profile?['id'] as String?;
    final old = _photoPath;
    if (profileId == null || old == null) return;

    setState(() => _uploadingPhoto = true);
    try {
      await client
          .from('provider_profiles')
          .update({'photo_storage_path': null})
          .eq('id', profileId);
      // The row is cleared first: a failure to delete the object leaves an
      // orphan file, which is invisible to a customer, whereas failing to
      // clear the row would leave the old photo still on the public page.
      try {
        await client.storage.from(_photoBucket).remove([old]);
      } catch (_) {
        // Nothing to say to the provider about an orphaned object.
      }
      if (!mounted) return;
      setState(() => _photoPath = null);
      _toast('Photo removed');
    } catch (e) {
      if (mounted) {
        _toast(friendlyError(e, context: 'Could not remove your photo'));
      }
    } finally {
      if (mounted) setState(() => _uploadingPhoto = false);
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
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
          : _error != null
              ? LoadErrorView(message: _error!, onRetry: _load)
              : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Form(
                key: _formKey,
                child: Column(
                  children: [
                    // Shop photo — the first thing a customer sees on the
                    // public provider page, and the one control here that
                    // saves on its own rather than with the form.
                    Row(
                      children: [
                        Container(
                          width: 76,
                          height: 76,
                          clipBehavior: Clip.antiAlias,
                          decoration: BoxDecoration(
                            color: AppTheme.creamDark,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: _photoPath == null
                              ? const Icon(Icons.storefront_outlined,
                                  color: AppTheme.textMuted, size: 28)
                              : Image.network(
                                  Supabase.instance.client.storage
                                      .from(_photoBucket)
                                      .getPublicUrl(_photoPath!),
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => const Icon(
                                      Icons.storefront_outlined,
                                      color: AppTheme.textMuted,
                                      size: 28),
                                ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              TextButton(
                                onPressed:
                                    _uploadingPhoto ? null : _pickPhoto,
                                child: Text(_photoPath == null
                                    ? 'Add a photo'
                                    : 'Change photo'),
                              ),
                              if (_photoPath != null)
                                TextButton(
                                  onPressed: _uploadingPhoto
                                      ? null
                                      : _removePhoto,
                                  child: const Text('Remove'),
                                ),
                              if (_uploadingPhoto)
                                const Padding(
                                  padding: EdgeInsets.only(top: 6),
                                  child: SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: AppTheme.primaryGreen),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
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
                    BirrTextField(
                      label: 'Price range',
                      controller: _priceCtrl,
                      hint: 'e.g. 50 - 200 ETB',
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 4, left: 4),
                      child: Text(
                        'Shown on your public page. Leave blank if you charge '
                        'case by case.',
                        style: const TextStyle(
                            fontSize: 11, color: AppTheme.textMuted),
                      ),
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
                    const SizedBox(height: 16),
                    // Payment accounts belong in business settings because
                    // they are part of who this provider is to a buyer: the
                    // bank / Telebirr / CBE Birr details shown on the product
                    // page and on Checkout, with copy buttons. One tap to the
                    // screen that manages them — the same one the dashboard's
                    // "Payment Methods" action opens.
                    InkWell(
                      onTap: () => context.push('/provider/payment-methods'),
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppTheme.creamDark,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppTheme.cardBorder),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.account_balance_wallet_outlined,
                                size: 22, color: AppTheme.primaryGreen),
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Payment accounts',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                      color: AppTheme.textPrimary,
                                    ),
                                  ),
                                  SizedBox(height: 2),
                                  Text(
                                    'Bank, Telebirr or CBE Birr — what buyers '
                                    'see to pay you directly',
                                    style: TextStyle(
                                      fontSize: 12,
                                      height: 1.3,
                                      color: AppTheme.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const Icon(Icons.chevron_right,
                                size: 20, color: AppTheme.textMuted),
                          ],
                        ),
                      ),
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
