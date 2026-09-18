import 'dart:io';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/birr_text_field.dart';
import '../../core/widgets/primary_button.dart';
import '../../core/services/location_service.dart';

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
  String? _categoryId;
  bool _isAvailable = true;
  List<Map<String, dynamic>> _categories = [];
  List<File> _newImages = [];
  List<Map<String, dynamic>> _existingImages = [];
  String? _providerId;
  bool _loading = true;
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
    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      if (userId == null) return;
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
      if (mounted) setState(() => _loading = false);
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
    setState(() => _saving = true);
    try {
      final client = Supabase.instance.client;
      final price = double.tryParse(_priceCtrl.text) ?? 0;
      final qty = int.tryParse(_qtyCtrl.text);

      String productId;
      // Real listing GPS: geography point from the captured device position
      // (falls back to the business profile location).
      final lat = _lat;
      final lng = _lng;
      final locationValue = (lat != null && lng != null)
          ? 'SRID=4326;POINT($lng $lat)'
          : null;

      if (_isEdit) {
        await client.from('products').update({
          'name': _nameCtrl.text.trim(),
          'description': _descCtrl.text.trim().isNotEmpty
              ? _descCtrl.text.trim()
              : null,
          'price': price,
          'quantity': qty,
          'category_id': _categoryId,
          'is_available': _isAvailable,
          if (locationValue != null) 'location': locationValue,
        }).eq('id', widget.productId!);
        productId = widget.productId!;
      } else {
        final data = await client
            .from('products')
            .insert({
              'provider_id': _providerId,
              'name': _nameCtrl.text.trim(),
              'description': _descCtrl.text.trim().isNotEmpty
                  ? _descCtrl.text.trim()
                  : null,
              'price': price,
              'quantity': qty,
              'category_id': _categoryId,
              'is_available': _isAvailable,
              if (locationValue != null) 'location': locationValue,
            })
            .select()
            .single();
        productId = data['id'];
      }

      // Upload new images
      for (var i = 0; i < _newImages.length; i++) {
        final file = _newImages[i];
        final fileName =
            '${productId}_${DateTime.now().millisecondsSinceEpoch}_$i.jpg';
        final path = 'product-images/$productId/$fileName';
        await client.storage.from('product-images').upload(path, file,
            fileOptions: const FileOptions(upsert: true));
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
            .showSnackBar(SnackBar(content: Text('Error: $e')));
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(_isEdit ? 'Edit Product' : 'Add Product')),
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
                    BirrTextField(
                      label: 'Price (ETB)',
                      controller: _priceCtrl,
                      keyboardType: TextInputType.number,
                      validator: (v) =>
                          v == null || v.trim().isEmpty ? 'Required' : null,
                    ),
                    const SizedBox(height: 16),
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
                                  : 'No GPS location set',
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
