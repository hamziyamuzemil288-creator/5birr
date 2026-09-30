import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/birr_text_field.dart';
import '../../core/widgets/primary_button.dart';
import '../../core/widgets/photo_grid.dart';
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
  /// Photos are stored at `{auth.uid()}/{vehicle_id}/{filename}` — the path
  /// convention the `vehicle-images` bucket's storage policies scope to
  /// (auth.uid()::text = the first path segment), documented in migration 0012
  /// and enforced server-side by add_vehicle_image(). The two halves cannot
  /// disagree: an object uploaded outside the caller's own folder would be
  /// unusable, so the RPC refuses a row that points at one.
  static const _bucket = 'vehicle-images';

  final _formKey = GlobalKey<FormState>();
  final _picker = ImagePicker();
  final _brandCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  final _plateCtrl = TextEditingController();
  final _colorCtrl = TextEditingController();
  final _capacityCtrl = TextEditingController();

  /// Rows already recorded against the vehicle (edit mode only).
  List<Map<String, dynamic>> _photos = [];

  /// Files picked before the vehicle exists. A new vehicle has no id to hang a
  /// storage path on until create_provider_vehicle returns one, so they are
  /// held here and uploaded by _save() once it does — rather than being
  /// dropped, which is what "add a vehicle, then add photos" would have meant.
  final List<XFile> _pendingPhotos = [];

  bool _busyPhotos = false;

  @override
  void dispose() {
    _brandCtrl.dispose();
    _modelCtrl.dispose();
    _plateCtrl.dispose();
    _colorCtrl.dispose();
    _capacityCtrl.dispose();
    super.dispose();
  }
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

        // A plain client read: SELECT was never revoked and vehicle_images_read
        // already scopes the rows to this provider (or an admin). Deliberately
        // inside the same try as the vehicle itself: if the photos cannot be
        // loaded, the form says so instead of quietly showing an empty gallery
        // that looks like "no photos yet".
        final photos = await client
            .from('vehicle_images')
            .select()
            .eq('vehicle_id', widget.vehicleId!)
            .order('sort_order');
        _photos = List<Map<String, dynamic>>.from(photos as List);
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

  Future<void> _reloadPhotos() async {
    if (!_isEdit) return;
    final data = await Supabase.instance.client
        .from('vehicle_images')
        .select()
        .eq('vehicle_id', widget.vehicleId!)
        .order('sort_order');
    if (!mounted) return;
    setState(() => _photos = List<Map<String, dynamic>>.from(data as List));
  }

  /// Uploads [files] to the caller's own folder for [vehicleId] and records a
  /// row for each through add_vehicle_image(). Returns how many FAILED, so the
  /// caller can report a partial result instead of swallowing it — the failure
  /// mode the product form had, where a rejected upload looked like success.
  Future<int> _uploadPhotos({
    required String uid,
    required String vehicleId,
    required List<XFile> files,
  }) async {
    if (files.isEmpty) return 0;
    final client = Supabase.instance.client;
    var failed = 0;
    for (var i = 0; i < files.length; i++) {
      final file = File(files[i].path);
      // A unique name per file: two photos picked in the same millisecond would
      // otherwise collide on one path and upsert:true would silently replace
      // the first.
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final name = Uri.encodeComponent(files[i].uri.pathSegments.last);
      final path = '$uid/$vehicleId/${stamp}_$i-$name';
      try {
        await client.storage
            .from(_bucket)
            .upload(path, file, fileOptions: const FileOptions(upsert: true));
        await client.rpc('add_vehicle_image', params: {
          'p_vehicle_id': vehicleId,
          'p_storage_path': path,
        });
      } catch (_) {
        failed++;
      }
    }
    return failed;
  }

  Future<void> _addPhotos() async {
    final picked = await _picker.pickMultiImage(imageQuality: 85);
    if (picked.isEmpty || !mounted) return;

    // New vehicle: no id to build a path from yet, so hold the files and let
    // _save() upload them once the RPC has returned one.
    if (!_isEdit) {
      setState(() => _pendingPhotos.addAll(picked));
      return;
    }

    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) {
      _toast('Please sign in again.', error: true);
      return;
    }

    setState(() => _busyPhotos = true);
    final failed =
        await _uploadPhotos(uid: uid, vehicleId: widget.vehicleId!, files: picked);
    await _reloadPhotos();
    if (!mounted) return;
    setState(() => _busyPhotos = false);
    if (failed == 0) {
      _toast('Added ${picked.length} photo${picked.length == 1 ? '' : 's'}.');
    } else {
      _toast(
        'Could not add $failed of ${picked.length} photo(s). Please try again.',
        error: true,
      );
    }
  }

  void _dropPending(XFile file) {
    setState(() => _pendingPhotos.remove(file));
  }

  Future<void> _removePhoto(String imageId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove photo?'),
        content: const Text(
          'It will disappear from the vehicle. The stored file is left in place '
          'so anything else pointing at it keeps working.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Remove',
                style: TextStyle(color: AppTheme.error)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await Supabase.instance.client.rpc('delete_vehicle_image',
          params: {'p_image_id': imageId});
      await _reloadPhotos();
      if (mounted) _toast('Photo removed.');
    } catch (e) {
      if (mounted) {
        _toast(friendlyError(e, context: 'Could not remove that photo'),
            error: true);
      }
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    // Both of these used to return silently, so a tap on ADD VEHICLE with no
    // provider profile — or with the identity documents still outstanding —
    // did nothing at all and said nothing about it.
    if (_providerId == null) {
      _toast(
        'Your vehicle provider profile could not be loaded, so nothing was '
        'saved. Pull to refresh, then try again.',
        error: true,
      );
      return;
    }
    // Task 7: one-time document check before the first protected action
    // (registering a vehicle for orders). Happens after wallet recharge.
    final documentsOk = await ProviderDocGate.instance.ensureDocuments(context);
    if (!documentsOk) {
      _toast('Nothing was saved. Verify your identity to add a vehicle.',
          error: true);
      return;
    }
    // Block uploads until the one-time registration fee is paid.
    if (!_registrationFeePaid) {
      _toast(_activationMessage, error: true);
      return;
    }
    if (!mounted) return;
    setState(() => _saving = true);
    try {
      final client = Supabase.instance.client;
      final uid = client.auth.currentUser?.id;
      if (uid == null) {
        _toast('Please sign in again.', error: true);
        return;
      }
      final capacity = int.tryParse(_capacityCtrl.text);
      final data = {
        'brand': _brandCtrl.text.trim(),
        'model': _modelCtrl.text.trim(),
        'plate_number': _plateCtrl.text.trim(),
        'color': _colorCtrl.text.trim(),
        'capacity': capacity,
        'category_id': _categoryId,
      };

      String vehicleId;
      if (_isEdit) {
        vehicleId = widget.vehicleId!;
        await client.from('vehicles').update(data).eq('id', vehicleId);
      } else {
        final created = await client.rpc('create_provider_vehicle', params: {
          'p_provider_id': _providerId,
          'p_brand': data['brand'],
          'p_model': data['model'],
          'p_plate_number': data['plate_number'],
          'p_color': data['color'],
          'p_capacity': data['capacity'],
          'p_category_id': data['category_id'],
        });
        // The RPC returns the inserted row, which is what the photos picked
        // before the vehicle existed need in order to have a path.
        vehicleId = (created as Map)['id'] as String;
      }

      final pending = List<XFile>.from(_pendingPhotos);
      final failed =
          await _uploadPhotos(uid: uid, vehicleId: vehicleId, files: pending);
      _pendingPhotos.clear();

      if (!mounted) return;
      final saved = _isEdit ? 'Vehicle updated' : 'Vehicle added';
      if (failed == 0) {
        _toast(saved);
      } else {
        _toast(
          '$saved, but $failed photo${failed == 1 ? '' : 's'} could not be '
          'uploaded. Open the vehicle and try again.',
          error: true,
        );
      }
      context.pop();
    } catch (e) {
      if (mounted) {
        _toast(friendlyError(e, context: 'Could not save this vehicle'),
            error: true);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _toast(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? AppTheme.error : null,
      duration: const Duration(seconds: 4),
    ));
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
                    _photosSection(),
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

  Widget _photosSection() {
    final tiles = <PhotoGridItem>[
      for (final p in _photos)
        PhotoGridItem.stored(
          p['storage_path'] as String,
          bucket: _bucket,
          onLongPress: () => _removePhoto(p['id'] as String),
          overlay: _RemoveScrim(onTap: () => _removePhoto(p['id'] as String)),
        ),
      for (final f in _pendingPhotos)
        PhotoGridItem.file(
          File(f.path),
          onTap: () => _dropPending(f),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('Photos',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            ),
            TextButton.icon(
              onPressed: _busyPhotos ? null : _addPhotos,
              icon: _busyPhotos
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppTheme.teal))
                  : const Icon(Icons.add_photo_alternate_outlined, size: 18),
              label: const Text('Add'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Text(
          'Riders see these when they look at your vehicle. JPEG, PNG or WebP, '
          'up to 5MB each.',
          style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 12),
        if (tiles.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.creamDark,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Text(
              'No photos yet.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppTheme.textMuted),
            ),
          )
        else
          PhotoGrid(items: tiles),
        if (!_isEdit && _pendingPhotos.isNotEmpty) ...[
          const SizedBox(height: 8),
          const Text(
            'These are uploaded when you add the vehicle. Tap one to remove it.',
            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
          ),
        ],
        if (_isEdit && _photos.isNotEmpty) ...[
          const SizedBox(height: 8),
          const Text(
            'Tap the × on a photo to remove it.',
            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
          ),
        ],
      ],
    );
  }
}

class _RemoveScrim extends StatelessWidget {
  const _RemoveScrim({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topRight,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.all(4),
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.55),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Icon(Icons.close, size: 14, color: Colors.white),
        ),
      ),
    );
  }
}
