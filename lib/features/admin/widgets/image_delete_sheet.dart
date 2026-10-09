import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/friendly_error.dart';

/// A delete-only sheet for admins that lists every published image and lets an
/// administrator remove one permanently.
///
/// This is the missing "delete image from the admin sidebar" path the report
/// described: the admin side of the image-delete flow is reachable from the
/// Content Control screen's own delete strip. The removal now goes through the
/// Supabase Storage API and cleans up the app row + audit entry client-side,\- because the server RPC that used to do this still runs the pre-fix body on
/// the live database (Supabase blocks direct storage.objects writes with P0001).
class ImageDeleteSheet extends StatefulWidget {
  const ImageDeleteSheet({super.key});

  @override
  State<ImageDeleteSheet> createState() => _ImageDeleteSheetState();
}

class _ImageDeleteSheetState extends State<ImageDeleteSheet> {
  List<Map<String, dynamic>> _images = const [];
  bool _loading = true;
  bool _working = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  SupabaseClient get _client => Supabase.instance.client;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await _client.rpc('admin_public_image_gallery', params: {
        'p_city': '',
        'p_limit': 200,
        'p_offset': 0,
      });
      if (!mounted) return;
      setState(() {
        _images = List<Map<String, dynamic>>.from(rows as List);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e, context: 'Could not load the image list');
      });
    }
  }

  void _snack(String message, {bool bad = false}) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: bad ? AppTheme.error : null,
      ));
  }

  Future<void> _run(String label, Future<dynamic> Function() action) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      final result = await action();
      final text = result is String ? result : '$label done';
      if (!mounted) return;
      _snack(text);
      await _load();
    } catch (e) {
      if (mounted) {
        _snack(friendlyErrorWithCode(e, context: label), bad: true);
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<String?> _askReason({required String title, required String confirm}) async {
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          maxLength: 500,
          decoration: const InputDecoration(
            labelText: 'Reason',
            helperText: 'Recorded permanently against this account.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final text = controller.text.trim();
              if (text.length >= 3) Navigator.pop(ctx, text);
            },
            child: Text(confirm),
          ),
        ],
      ),
    );
    controller.dispose();
    return reason;
  }

  Future<void> _remove(Map<String, dynamic> image) async {
    final bucket = image['bucket'] as String?;
    final path = image['storage_path'] as String?;
    if (bucket == null || bucket.isEmpty || path == null || path.isEmpty) {
      _snack('That image has no usable path, so it cannot be deleted.',
          bad: true);
      return;
    }
    final reason = await _askReason(
      title: 'Delete this image permanently?',
      confirm: 'Delete image',
    );
    if (reason == null || !mounted) return;

    await _run('Image removal', () {
      // Same fix as PublicImageGallery._remove: the live server still runs
      // the pre-fix admin_moderate_image body (migration 20261006000004 is
      // behind the deployed head), which writes directly to storage.objects
      // and hits the RLS trigger's P0001 block. Go through the Storage API
      // instead, then clean up the app row and audit entry ourselves.
      final b = bucket;
      final p = path;

      // 1. Remove the file from storage through the Storage API.
      _client.storage.from(b).remove([p]);

      // 2. Delete the app row that references it. For provider-gallery we
      //    call a server RPC (the table is RLS-protected and the caller is
      //    an admin; the RPC enforces that). For product-images and
      //    vehicle-images the client can delete directly through the public
      //    table API because RLS allows admins to write there.
      var rowRemoved = false;
      if (b == 'provider-gallery') {
        final deleted =
            await _client.rpc('admin_delete_provider_gallery_by_path', params: {
          'p_path': p,
        });
        rowRemoved = deleted is int && (deleted as int) > 0;
      } else if (b == 'product-images') {
        final deleted = await _client
            .from('product_images')
            .delete()
            .eq('storage_path', p)
            .select()
            .maybeSingle();
        rowRemoved = deleted != null;
      } else if (b == 'vehicle-images') {
        final deleted = await _client
            .from('vehicle_images')
            .delete()
            .eq('storage_path', p)
            .select()
            .maybeSingle();
        rowRemoved = deleted != null;
      }

      // 3. Write the audit entry. moderation_actions is append-only and
      //    admin-only, so we go through a server RPC that enforces both.
      _client.rpc('admin_log_moderation_action', params: {
        'p_action_type': 'IMAGE_REMOVED',
        'p_severity': 'SERIOUS',
        'p_reason': reason,
        'p_object_bucket': b,
        'p_object_path': p,
        'p_detail': {'removed_from': rowRemoved ? b : 'unknown'},
      });

      return 'Image removed: $p';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Delete image'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
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
                  ? const Center(
                      child: Text(
                        'No published images were found.',
                        style: TextStyle(color: AppTheme.textMuted),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _images.length,
                      itemBuilder: (_, i) {
                        final image = _images[i];
                        final name = image['provider_name'] as String? ?? 'Unknown';
                        final path = image['storage_path'] as String?;
                        return Card(
                          margin: const EdgeInsets.only(bottom: 12),
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: AppTheme.primaryGreen,
                              child: Text('#$i',
                                  style: const TextStyle(color: Colors.white)),
                            ),
                            title: Text(name,
                                style: const TextStyle(fontWeight: FontWeight.w600)),
                            subtitle: Text(
                              path ?? 'unknown path',
                              style: const TextStyle(fontSize: 11),
                            ),
                            trailing: OutlinedButton.icon(
                              onPressed: _working ? null : () => _remove(image),
                              icon: const Icon(Icons.delete_forever, size: 16),
                              label: const Text('Delete'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppTheme.error,
                                side: const BorderSide(color: AppTheme.error),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
    );
  }
}
