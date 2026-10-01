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

  /// Publish or unpublish one photo.
  ///
  /// WHAT THIS IS NOT
  /// ---------------
  /// It is not the missing "post" button the report asked for, because there is
  /// nothing to post: `add_gallery_image` writes `is_active = true`, so an
  /// upload is public the moment it lands. What makes a photo invisible is the
  /// OTHER half of the public read policy -- `provider_gallery_public_read`
  /// also requires the provider's account to be APPROVED. A photo on a pending
  /// or suspended account is correctly hidden and no client-side switch can
  /// change that.
  ///
  /// So the honest control is unpublish/republish: it changes what THIS person
  /// decided to show, and the server's reply says plainly whether the photo is
  /// now visible or whether the account status is the reason it is not.
  Future<void> _setPublic(ProviderGalleryImage image, bool isPublic) async {
    try {
      final result = await _client.rpc('set_gallery_image_public', params: {
        'p_image_id': image.id,
        'p_public': isPublic,
      });
      await _load();
      if (mounted) {
        _toast(result is String ? result : 'Updated.');
      }
    } catch (e) {
      if (mounted) {
        _toast(friendlyError(e, context: 'Could not change that photo'));
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
                                overlay: _TileOverlay(
                                  img: img,
                                  onDelete: () => _delete(img),
                                  onTogglePublic: () =>
                                      _setPublic(img, !img.isPublic),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
    );
  }
}

/// The two controls on each tile: publish state, and remove.
///
/// A single "X" scrim used to be the only affordance, so a provider had no way
/// to express "this photo is not one I offer" without deleting it -- and
/// deletion here is the row, which cannot be undone. Two distinct buttons, and
/// the eye is on the left so it is the easier one to hit by accident of
/// thumb rather than the destructive one.
class _TileOverlay extends StatelessWidget {
  const _TileOverlay({
    required this.img,
    required this.onDelete,
    required this.onTogglePublic,
  });

  final ProviderGalleryImage img;
  final VoidCallback onDelete;
  final VoidCallback onTogglePublic;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _scrim(
            icon: img.isPublic ? Icons.visibility : Icons.visibility_off,
            tooltip: img.isPublic ? 'Hide this photo' : 'Publish this photo',
            onTap: onTogglePublic,
          ),
          const SizedBox(width: 4),
          _scrim(
            icon: Icons.close,
            tooltip: 'Remove this photo',
            onTap: onDelete,
          ),
        ],
      ),
    );
  }

  Widget _scrim({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.all(4),
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.55),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Icon(icon, size: 14, color: Colors.white),
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
              'Add photos of your work, premises or team. They are published '
              'as soon as they upload. Customers see them once your account is '
              'approved — use the eye on a photo to hide one you do not want '
              'advertised.',
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
