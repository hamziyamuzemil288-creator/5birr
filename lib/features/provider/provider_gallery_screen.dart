import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/models/provider_gallery.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/photo_grid.dart';
import '../../core/utils/friendly_error.dart';

/// A provider's own gallery: add, view and remove photos.
///
/// Upload path is `<auth uid>/<image id>/<file>` in the `provider-gallery`
/// bucket, which is what the bucket's storage policies scope to
/// (auth.uid()::text = first path segment). The server refuses a row whose
/// path is not under the caller's own folder, so the two halves cannot
/// disagree — see 20260927000055.
class ProviderGalleryScreen extends StatefulWidget {
  const ProviderGalleryScreen({super.key, required this.providerId});
  final String providerId;

  @override
  State<ProviderGalleryScreen> createState() => _ProviderGalleryScreenState();
}

class _ProviderGalleryScreenState extends State<ProviderGalleryScreen> {
  static const _bucket = 'provider-gallery';

  final _picker = ImagePicker();
  List<ProviderGalleryImage> _images = const [];
  bool _loading = true;
  bool _uploading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  SupabaseClient get _client => Supabase.instance.client;

  Future<void> _load() async {
    try {
      // A plain client read: SELECT was never revoked and the owner policy
      // already scopes the rows to this provider.
      final data = await _client
          .from('provider_gallery')
          .select()
          .eq('provider_id', widget.providerId)
          .order('display_order');
      if (!mounted) return;
      setState(() {
        _images = (data as List)
            .map((r) => ProviderGalleryImage.fromJson(r))
            .toList();
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e, context: 'Could not load your gallery');
      });
    }
  }

  Future<void> _add() async {
    // Downscaled, not forwarded. `provider-gallery` has a 5MB limit, and
    // imageQuality alone re-encodes at full resolution -- a 12MP phone photo
    // still lands over the limit and is refused inside storage, where the
    // provider only ever sees a generic failure. Matches every other picker
    // in the app (and provider_product_form/vehicle_form, which had the same
    // gap on this same call).
    final picked = await _picker.pickMultiImage(
      maxWidth: 1920,
      maxHeight: 1920,
      imageQuality: 85,
    );
    if (picked.isEmpty || !mounted) return;

    final uid = _client.auth.currentUser?.id;
    if (uid == null) {
      _toast('Please sign in again.');
      return;
    }

    setState(() => _uploading = true);
    var added = 0;
    String? lastError;
    for (final x in picked) {
      final file = File(x.path);
      // The folder name is generated client-side so it is known before the
      // upload starts; the server does not need to have seen a row yet. The
      // counter keeps two files picked in the same millisecond apart.
      final imageId = '${DateTime.now().microsecondsSinceEpoch}_$added';
      final path = '$uid/$imageId/${Uri.encodeComponent(file.uri.pathSegments.last)}';
      try {
        await _client.storage
            .from(_bucket)
            .upload(path, file, fileOptions: const FileOptions(upsert: true));
        await _client.rpc('add_gallery_image', params: {
          'p_provider_id': widget.providerId,
          'p_storage_path': path,
          'p_caption': null,
        });
        added++;
      } catch (e) {
        lastError = e.toString();
      }
    }

    await _load();
    if (!mounted) return;
    setState(() => _uploading = false);
    if (added == 0) {
      _toast(friendlyError(lastError ?? 'Upload failed',
          context: 'Could not add photos'));
    } else {
      _toast('Added $added photo${added == 1 ? '' : 's'}.');
    }
  }

  Future<void> _delete(ProviderGalleryImage image) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove photo?'),
        content: const Text(
          'It will disappear from your gallery. The stored file is left in '
          'place so any other listing still pointing at it keeps working.',
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
    if (ok != true || !mounted) return;

    try {
      await _client
          .rpc('delete_gallery_image', params: {'p_image_id': image.id});
      await _load();
      if (mounted) _toast('Photo removed.');
    } catch (e) {
      if (mounted) {
        _toast(friendlyError(e, context: 'Could not remove that photo'));
      }
    }
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Gallery'),
        actions: [
          IconButton(
            onPressed: _uploading ? null : _add,
            icon: _uploading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppTheme.primaryGreen))
                : const Icon(Icons.add_photo_alternate_outlined),
            tooltip: 'Add photos',
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: AppTheme.error)),
                  ),
                )
              : _images.isEmpty
                  ? _EmptyGallery(onAdd: _add, busy: _uploading)
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: PhotoGrid(
                          // A provider's gallery is read on a phone far more
                          // often than on a tablet, so three across is the
                          // default and the tiles stay square.
                          items: [
                            for (final img in _images)
                              PhotoGridItem.stored(
                                img.storagePath,
                                bucket: _bucket,
                                onLongPress: () => _delete(img),
                                overlay: _DeleteScrim(
                                  onTap: () => _delete(img),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
    );
  }
}

class _DeleteScrim extends StatelessWidget {
  const _DeleteScrim({required this.onTap});
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

class _EmptyGallery extends StatelessWidget {
  const _EmptyGallery({required this.onAdd, required this.busy});
  final VoidCallback onAdd;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.photo_library_outlined,
                size: 56, color: AppTheme.textMuted),
            const SizedBox(height: 16),
            const Text('No photos yet',
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            const Text(
              'Add photos of your work, premises or team. Customers see these '
              'when they open your profile.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: busy ? null : onAdd,
              icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
              label: const Text('Add photos'),
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.primaryGreen,
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
