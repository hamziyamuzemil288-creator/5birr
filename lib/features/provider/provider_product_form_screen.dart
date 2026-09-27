import 'dart:io';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/birr_text_field.dart';
import '../../core/widgets/primary_button.dart';
import '../../core/services/location_service.dart';
import '../../core/services/provider_activation_service.dart';
import '../../core/services/provider_doc_gate.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/load_error_view.dart';

class ProviderProductFormScreen extends StatefulWidget {
  final String? productId;
  const ProviderProductFormScreen({super.key, this.productId});
  @override
  State<ProviderProductFormScreen> createState() => _State();
}

class _State extends State<ProviderProductFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _qtyCtrl = TextEditingController();
  // Listing pricing mode: fixed price (default) or per-unit (kg / liter).
  // Unit mode keeps the existing full listing (images optional) and stores
  // the per-unit price in `price` AND `price_per_unit`, plus `unit`.
  bool _unitMode = false;
  String _unit = 'KG'; // 'KG' | 'LTR'
  String? _categoryId;
  bool _isAvailable = true;
  List<Map<String, dynamic>> _categories = [];
  List<File> _newImages = [];
  List<Map<String, dynamic>> _existingImages = [];
  String? _providerId;
  bool _loading = true;
  String? _error;
  // One-time activation gate: providers must pay the registration fee via
  // their first wallet recharge before uploading listings.
  bool _registrationFeePaid = true;
  String _activationMessage = '';
  bool _saving = false;
  final _picker = ImagePicker();

  // Listing GPS: defaults from the business profile; can be re-captured.
  double? _lat;
  double? _lng;
  bool _capturingGps = false;

  bool get _isEdit => widget.productId != null;

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
      // Activation gate (non-fatal: form stays usable if the check fails).
      try {
        final activation = await ProviderActivation.load();
        if (activation != null && !activation.isActivated) {
          if (mounted) {
            setState(() {
              _registrationFeePaid = false;
              _activationMessage = activation.blockingMessage;
            });
          }
        }
      } catch (_) {}
      final prov = await client
          .from('provider_profiles')
          .select('id')
          .eq('user_id', userId)
          .maybeSingle();
      if (prov == null) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      _providerId = prov['id'];
      // Prime the listing location from the business profile GPS.
      final fullProv = await client
          .from('provider_profiles')
          .select('location_lat, location_lng')
          .eq('user_id', userId)
          .maybeSingle();
      _lat = (fullProv?['location_lat'] as num?)?.toDouble();
      _lng = (fullProv?['location_lng'] as num?)?.toDouble();
      final cats = await client
          .from('categories')
          .select('id,name')
          .eq('sector', 'SERVICE')
          .eq('is_active', true)
          .isFilter('parent_id', null)
          .order('name');
      var categories = List<Map<String, dynamic>>.from(cats as List);
      // Fallback: if no parent categories exist, show all categories
      // for this sector so the dropdown is never empty.
      if (categories.isEmpty) {
        final allCats = await client
            .from('categories')
            .select('id,name')
            .eq('sector', 'SERVICE')
            .eq('is_active', true)
            .order('name');
        categories = List<Map<String, dynamic>>.from(allCats as List);
      }
      _categories = categories;

      if (_isEdit) {
        final prod = await client
            .from('products')
            .select('*, product_images(*)')
            .eq('id', widget.productId!)
            .single();
        _nameCtrl.text = prod['name'] ?? '';
        _descCtrl.text = prod['description'] ?? '';
        _priceCtrl.text = '${prod['price'] ?? ''}';
        _qtyCtrl.text = '${prod['quantity'] ?? ''}';
        _categoryId = prod['category_id'];
        _isAvailable = prod['is_available'] ?? true;
        final unit = prod['unit'] as String?;
        _unitMode = unit != null;
        if (unit == 'LTR') _unit = 'LTR';
        if (_unitMode) {
          final ppu = (prod['price_per_unit'] as num?)?.toDouble();
          if (ppu != null && ppu > 0) _priceCtrl.text = _fmt(ppu);
        }
        final prodLoc = GeoPoint.parse(prod['location']);
        if (prodLoc != null) {
          _lat = prodLoc.lat;
          _lng = prodLoc.lng;
        }
        _existingImages = List<Map<String, dynamic>>.from(
            (prod['product_images'] as List?) ?? []);
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

  Future<void> _pickImages() async {
    final picked = await _picker.pickMultiImage(imageQuality: 85);
    if (picked.isNotEmpty) {
      setState(() {
        _newImages.addAll(picked.map((x) => File(x.path)));
      });
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_providerId == null) return;
    // Task 7: one-time document check before the first protected action.
    // Providers upload their ID documents here (not at signup) — after
    // their wallet recharge, exactly when they start selling.
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
    // A listing without a location cannot be found by proximity search:
    // search_products computes distance_km only when p.location is set, and
    // its ST_DWithin predicate short-circuits on `p.location IS NULL`, so the
    // radius filter never even runs. Every location-less listing is therefore
    // returned to every nearby searcher regardless of distance — the source
    // of the "unfamiliar place name" results.
    //
    // Required on CREATE so that stops accumulating. Not required on EDIT:
    // blocking an edit of an existing listing until the provider finds GPS
    // would trap them, and editing without setting a location does not add
    // any new location-less rows.
    if (!_isEdit && (_lat == null || _lng == null)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
          'Set a GPS location before saving — listings without one cannot be '
          'found by nearby search.',
        ),
        backgroundColor: AppTheme.error,
        duration: Duration(seconds: 4),
      ));
      return;
    }
    setState(() => _saving = true);
    try {
      final client = Supabase.instance.client;
      final price = double.tryParse(_priceCtrl.text) ?? 0;
      final qty = int.tryParse(_qtyCtrl.text);
      // Unit-priced listings carry the per-unit price in both `price` (so all
      // existing totals/fee math work) and `price_per_unit`, plus the unit.
      final unitValue = _unitMode ? _unit : null;
      final perUnitPrice = _unitMode ? price : 0.0;

      String productId;
      // Real listing GPS: geography point from the captured device position
      // (falls back to the business profile location).
      final lat = _lat;
      final lng = _lng;
      final locationValue =
          (lat != null && lng != null) ? 'SRID=4326;POINT($lng $lat)' : null;

      if (_isEdit) {
        await client.from('products').update({
          'name': _nameCtrl.text.trim(),
          'description':
              _descCtrl.text.trim().isNotEmpty ? _descCtrl.text.trim() : null,
          'price': price,
          'price_per_unit': perUnitPrice,
          'unit': unitValue,
          'quantity': qty,
          'category_id': _categoryId,
          'is_available': _isAvailable,
          if (locationValue != null) 'location': locationValue,
        }).eq('id', widget.productId!);
        productId = widget.productId!;
      } else {
        final created = await client
            .rpc('create_provider_product', params: {
              'p_provider_id': _providerId,
              'p_name': _nameCtrl.text.trim(),
              'p_description': _descCtrl.text.trim().isNotEmpty
                  ? _descCtrl.text.trim()
                  : null,
              'p_price': price,
              'p_category_id': _categoryId,
              'p_quantity': qty,
              'p_price_per_unit': perUnitPrice,
              'p_unit': unitValue,
              'p_is_available': _isAvailable,
              'p_lat': lat,
              'p_lng': lng,
            })
            .single();
        productId = created['id'] as String;
      }

      // Upload new images.
      //
      // The path MUST start with the caller's own auth uid: the storage
      // policies match the object NAME inside the bucket, and every write
      // policy on this bucket scopes the object to auth.uid(). It previously
      // read 'product-images/$productId/...', which put the BUCKET name in
      // the first segment -- that only worked because migration 0033 had
      // widened the INSERT policy to `bucket_id = 'product-images'` with no
      // path check at all, which also let any signed-in account overwrite any
      // provider's listing photo. 20260927000048 restores the owner check, so
      // the two halves land together.
      final uid = client.auth.currentUser?.id;
      if (uid == null) {
        throw Exception('Not signed in — cannot upload listing images');
      }
      for (var i = 0; i < _newImages.length; i++) {
        final file = _newImages[i];
        final fileName =
            '${productId}_${DateTime.now().millisecondsSinceEpoch}_$i.jpg';
        final path = '$uid/$productId/$fileName';
        await client.storage
            .from('product-images')
            .upload(path, file, fileOptions: const FileOptions(upsert: true));
        await client.from('product_images').insert({
          'product_id': productId,
          'storage_path': path,
          'sort_order': i,
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(_isEdit ? 'Product updated' : 'Product created')));
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e, context: 'Could not save this product'))));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Capture the real device GPS for this listing (search distance +
  /// buyer directions use it).
  Future<void> _useCurrentLocation() async {
    setState(() => _capturingGps = true);
    final r = await LocationService.instance.getCurrentPositionDetailed();
    if (!mounted) return;
    if (r.success) {
      setState(() {
        _lat = r.position!.latitude;
        _lng = r.position!.longitude;
        _capturingGps = false;
      });
    } else {
      setState(() => _capturingGps = false);
    }
  }

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'Edit Product' : 'Add Product')),
      body: _error != null
          ? LoadErrorView(message: _error!, onRetry: _load)
          : _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Form(
                key: _formKey,
                child: Column(
                  children: [
                    BirrTextField(
                      label: 'Product Name',
                      controller: _nameCtrl,
                      validator: (v) =>
                          v == null || v.trim().isEmpty ? 'Required' : null,
                    ),
                    const SizedBox(height: 16),
                    BirrTextField(
                      label: 'Description',
                      controller: _descCtrl,
                      maxLines: 3,
                    ),
                    const SizedBox(height: 16),
                    // Pricing mode: fixed price OR price per unit (kg/liter).
                    Row(
                      children: [
                        Expanded(
                          child: ChoiceChip(
                            label: const Text('Fixed price'),
                            selected: !_unitMode,
                            onSelected: (_) =>
                                setState(() => _unitMode = false),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ChoiceChip(
                            label: const Text('Price per unit'),
                            selected: _unitMode,
                            onSelected: (_) => setState(() => _unitMode = true),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (_unitMode)
                      Row(
                        children: [
                          Expanded(
                            child: ChoiceChip(
                              label: const Text('per kilogram'),
                              selected: _unit == 'KG',
                              onSelected: (_) => setState(() => _unit = 'KG'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ChoiceChip(
                              label: const Text('per liter'),
                              selected: _unit == 'LTR',
                              onSelected: (_) => setState(() => _unit = 'LTR'),
                            ),
                          ),
                        ],
                      ),
                    const SizedBox(height: 8),
                    BirrTextField(
                      label: _unitMode
                          ? 'Price per ${_unit == 'KG' ? 'kg' : 'liter'} (ETB)'
                          : 'Price (ETB)',
                      controller: _priceCtrl,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      validator: (v) =>
                          v == null || v.trim().isEmpty ? 'Required' : null,
                    ),
                    const SizedBox(height: 16),
                    if (!_unitMode)
                      BirrTextField(
                        label: 'Quantity (optional)',
                        controller: _qtyCtrl,
                        keyboardType: TextInputType.number,
                      ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      value: _categoryId,
                      decoration: const InputDecoration(labelText: 'Category'),
                      items: _categories
                          .map((c) => DropdownMenuItem(
                              value: c['id'] as String,
                              child: Text(c['name'] ?? '')))
                          .toList(),
                      onChanged: (v) => setState(() => _categoryId = v),
                    ),
                    const SizedBox(height: 16),
                    // Listing GPS capture row
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
                                  : 'No GPS location set — required to publish',
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                          TextButton.icon(
                            onPressed:
                                _capturingGps ? null : _useCurrentLocation,
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
                    const SizedBox(height: 16),
                    SwitchListTile(
                      title: const Text('Available'),
                      value: _isAvailable,
                      onChanged: (v) => setState(() => _isAvailable = v),
                      activeColor: AppTheme.primaryGreen,
                      contentPadding: EdgeInsets.zero,
                    ),
                    const SizedBox(height: 16),
                    // Images section
                    Row(
                      children: [
                        const Text('Images',
                            style: TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600)),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: _pickImages,
                          icon: const Icon(Icons.add_photo_alternate_outlined,
                              size: 18),
                          label: const Text('Add'),
                        ),
                      ],
                    ),
                    if (_existingImages.isNotEmpty || _newImages.isNotEmpty)
                      SizedBox(
                        height: 100,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: [
                            ..._existingImages.map((img) => Container(
                                  width: 100,
                                  margin: const EdgeInsets.only(right: 8),
                                  decoration: BoxDecoration(
                                      color: AppTheme.creamDark,
                                      borderRadius: BorderRadius.circular(8)),
                                  child: const Center(
                                      child: Icon(Icons.image,
                                          color: AppTheme.textMuted)),
                                )),
                            ..._newImages.map((file) => Container(
                                  width: 100,
                                  margin: const EdgeInsets.only(right: 8),
                                  decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(8)),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.file(file, fit: BoxFit.cover),
                                  ),
                                )),
                          ],
                        ),
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
                                fontSize: 13, color: AppTheme.textSecondary)),
                      ),
                    ],
                    SizedBox(
                      width: double.infinity,
                      child: PrimaryButton(
                        label: _isEdit ? 'UPDATE PRODUCT' : 'CREATE PRODUCT',
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
