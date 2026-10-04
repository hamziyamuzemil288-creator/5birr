import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/ethiopia_cities.dart' as cities;
import '../../../core/utils/friendly_error.dart';
import '../../../core/widgets/photo_grid.dart';

/// The gallery of images that are actually published, for Content Control.
///
/// WHY THIS IS A SEPARATE WIDGET
/// -----------------------------
/// Content Control itself reads `admin_content_reports`, which returns rows
/// somebody has already REPORTED. A moderator looking for "the picture with the
/// road junction in it" had no way to look, because most content that breaks
/// the rules is never reported by anybody. This panel is that list, and it is
/// a widget rather than more of the same screen because `AdminContentControl`
/// reads Supabase in `initState` and cannot be pumped without credentials --
/// which is exactly why every data-free piece of admin UI in this project was
/// extracted (see `DocumentReviewCard` and `IncomeFilterChips`).
///
/// WHAT IT DOES
/// ------------
///   * lists provider gallery photos, product images and vehicle images, with
///     the UPLOADER's display name, their business, and their city on each
///     tile -- so a decision can be made without a second lookup;
///   * groups by city and filters by it, because "which city is this problem
///     in" is usually the first question and it is unanswerable from a flat
///     list of uuids;
///   * hides an image from public WITHOUT deleting it (reversible, and the
///     provider keeps the photo in their own gallery);
///   * removes it entirely, through the same `admin_moderate_image` the report
///     queue already used;
///   * warns the uploader, with text the moderator types, from this section.
///
/// Hide is offered FIRST and remove second, on purpose. Removal is
/// irreversible and takes the provider's copy with it; the report was "delete
/// the image OR suspend it from the public", and the second of those is the
/// one a moderator should reach for by default.

/// One row's tile, or null when the row cannot be rendered.
///
/// The two reads are `as String?`, not `as String`, and that is the whole
/// fix. `admin_public_image_gallery` declares its output as
/// `RETURNS TABLE (..., bucket text, storage_path text, ...)`, and a
/// RETURNS TABLE column is nullable by definition -- PostgREST hands the
/// client JSON `null` for one regardless of what the query wrote. An
/// unchecked `as String` on a null throws, and because it threw inside the
/// list literal that assembled the grid, it took out the WHOLE panel for that
/// city rather than skipping one photo. That is what "images are not loading
/// in this section" looked like, while the same files rendered correctly in
/// every other screen -- product_card, the vehicle form and the document queue
/// all read these same columns defensively.
///
/// A row with no path or no bucket is skipped rather than rendered as a broken
/// tile: there is nothing to sign, so a tile would only ever be a grey
/// placeholder opening an action sheet for a file that is not there.
PhotoGridItem? galleryTileItem(
  Map<String, dynamic> row, {
  void Function(Map<String, dynamic>)? onTap,
}) {
  final path = row['storage_path'] as String?;
  final bucket = row['bucket'] as String?;
  if (path == null || path.isEmpty || bucket == null || bucket.isEmpty) {
    return null;
  }
  return PhotoGridItem.stored(
    path,
    bucket: bucket,
    onTap: onTap == null ? null : () => onTap(row),
  );
}

/// The tiles for one city's rows, in the order the RPC returned them.
///
/// Top level and pure so the exact assembly that shipped -- and broke -- can
/// be exercised without a Supabase client, which `PhotoGrid`'s signing branch
/// requires. The test asserts on THIS function rather than on a copy of it, so
/// a refactor cannot leave the tests green against logic the screen no longer
/// runs.
List<PhotoGridItem> galleryTileItems(
  List<Map<String, dynamic>> rows, {
  void Function(Map<String, dynamic>)? onTap,
}) =>
    [
      for (final r in rows)
        if (galleryTileItem(r, onTap: onTap) case final item?) item,
    ];

class PublicImageGallery extends StatefulWidget {
  const PublicImageGallery({super.key});

  @override
  State<PublicImageGallery> createState() => _PublicImageGalleryState();
}

class _PublicImageGalleryState extends State<PublicImageGallery> {
  List<Map<String, dynamic>> _images = const [];
  bool _loading = true;
  bool _working = false;
  String? _error;

  /// '' means every city, which is what loads first: an administrator opening
  /// moderation should see images immediately, not an empty panel they have to
  /// guess a filter for.
  String _city = '';

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
        'p_city': _city,
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
        _error = friendlyError(e, context: 'Could not load the image gallery');
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
      if (mounted) _snack(friendlyError(e, context: label), bad: true);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// Typed text the moderator sends to the person who uploaded it. Returns
  /// null when cancelled, so nothing is sent by accident.
  Future<({String title, String body})?> _askWarning() async {
    final title = TextEditingController();
    final body = TextEditingController();
    final out = await showDialog<({String title, String body})>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Warn the uploader'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: title,
              autofocus: true,
              maxLength: 80,
              decoration: const InputDecoration(
                labelText: 'Title',
                hintText: 'Your photo breaks our rules',
              ),
            ),
            TextField(
              controller: body,
              minLines: 2,
              maxLines: 4,
              maxLength: 2000,
              decoration: const InputDecoration(
                labelText: 'Message',
                hintText: 'Tell them exactly what to change.',
                helperText:
                    'Sent to their notifications and kept in the permanent log.',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final t = title.text.trim();
              final b = body.text.trim();
              if (t.length >= 3 && b.length >= 3) {
                Navigator.pop(ctx, (title: t, body: b));
              }
            },
            child: const Text('Send warning'),
          ),
        ],
      ),
    );
    title.dispose();
    body.dispose();
    return out;
  }

  Future<void> _warn(Map<String, dynamic> image) async {
    final userId = image['uploader_user_id'] as String?;
    if (userId == null) {
      _snack('This image has no account behind it, so nobody can be warned '
          'about it.', bad: true);
      return;
    }
    final warning = await _askWarning();
    if (warning == null || !mounted) return;
    await _run('Warning', () {
      return _client.rpc('admin_warn_user', params: {
        'p_user_id': userId,
        'p_title': warning.title,
        'p_body': warning.body,
      });
    });
  }

  /// Hide or restore. Restoring demands a reason, because putting a photo back
  /// after a takedown overrides an earlier decision and the record should say
  /// why. The server enforces that too, so this is only the courtesy.
  Future<void> _setPublic(Map<String, dynamic> image, bool isPublic) async {
    String? reason;
    if (isPublic) {
      reason = await _askReason('Put this image back in public?', confirm: 'Restore');
      if (reason == null || !mounted) return;
    }
    await _run(isPublic ? 'Restore' : 'Hide', () {
      return _client.rpc('admin_set_gallery_image_public', params: {
        'p_image_id': image['image_id'],
        'p_public': isPublic,
        if (reason != null) 'p_reason': reason,
      });
    });
  }

  Future<void> _remove(Map<String, dynamic> image) async {
    final reason = await _askReason('Delete this image permanently?', confirm: 'Delete');
    if (reason == null || !mounted) return;
    await _run('Image removal', () {
      // admin_moderate_image_with_reason is a thin wrapper around
      // admin_moderate_image. It still enforces is_admin() server-side; it
      // only changes what a refusal looks like, so a moderator gets a fixed
      // sentence — the server's own reason — instead of a raw PostgREST
      // error string.
      return _client.rpc('admin_moderate_image_with_reason', params: {
        'p_bucket': image['bucket'],
        'p_path': image['storage_path'],
        'p_reason': reason,
        'p_severity': 'SERIOUS',
      });
    });
  }

  Future<String?> _askReason(String title, {required String confirm}) async {
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

  /// Cities that actually have images, so the filter offers somewhere to go
  /// rather than a long list of cities with nothing behind them.
  List<String> get _citiesWithImages {
    final set = <String>{
      for (final r in _images)
        if ((r['city'] as String? ?? '').isNotEmpty) r['city'] as String,
    };
    return set.toList()..sort();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.photo_library_outlined,
                size: 18, color: AppTheme.primaryGreenDark),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('Public images',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.primaryGreenDark)),
            ),
            IconButton(
              tooltip: 'Reload images',
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh, size: 20),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          'Every image a customer can see right now, grouped by city. Hide one '
          'to take it down without deleting it — the provider keeps their copy '
          'and can publish it again.',
          style: TextStyle(fontSize: 12, height: 1.4),
        ),
        const SizedBox(height: 10),
        _cityFilter(),
        const SizedBox(height: 12),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen),
            ),
          )
        else if (_error != null)
          Text(_error!,
              style: const TextStyle(color: AppTheme.error, fontSize: 12.5))
        else if (_images.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 18),
            child: Text(
              'No images have been uploaded yet.',
              style: TextStyle(fontSize: 12.5, color: AppTheme.textMuted),
            ),
          )
        else
          ..._grouped(),
      ],
    );
  }

  Widget _cityFilter() {
    // A getter, not a method: `List<String> get _citiesWithImages`.
    final available = _citiesWithImages;
    final options = <String>['', ...available];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final c in options)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(c.isEmpty ? 'All cities' : _titleCase(c)),
                selected: _city == c,
                selectedColor: AppTheme.primaryGreen.withOpacity(0.18),
                onSelected: (_) {
                  setState(() => _city = c);
                  _load();
                },
              ),
            ),
          // The full city list, so a moderator can ask for a city that has no
          // images and be told "none" rather than being unable to ask.
          if (available.length < cities.cities.length)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                '${cities.cities.length} cities served',
                style:
                    const TextStyle(fontSize: 11, color: AppTheme.textMuted),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _grouped() {
    // One heading per city, images under it. An unordered grid of anonymous
    // tiles is why nobody could work out which city a problem was in.
    final byCity = <String, List<Map<String, dynamic>>>{};
    for (final r in _images) {
      byCity.putIfAbsent((r['city'] as String? ?? ''), () => []).add(r);
    }
    final keys = byCity.keys.toList()
      ..sort((a, b) {
        if (a.isEmpty) return 1;
        if (b.isEmpty) return -1;
        return a.compareTo(b);
      });

    final out = <Widget>[];
    for (final city in keys) {
      final rows = byCity[city]!;
      out.add(Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 8),
        child: Row(
          children: [
            const Icon(Icons.location_city_outlined,
                size: 14, color: AppTheme.textMuted),
            const SizedBox(width: 6),
            Text(
              city.isEmpty ? 'No city set' : _titleCase(city),
              style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textSecondary),
            ),
            const SizedBox(width: 8),
            Text('${rows.length}',
                style:
                    const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
          ],
        ),
      ));
      out.add(_grid(rows));
    }
    return out;
  }

  Widget _grid(List<Map<String, dynamic>> rows) {
    return PhotoGrid(
      items: galleryTileItems(rows, onTap: _sheet),
    );
  }

  /// The per-image actions. A dialog rather than three buttons on a 110dp
  /// tile: on a gallery the moderator is comparing several images, and making
  /// them decide with one tap is how the wrong photo gets actioned.
  Future<void> _sheet(Map<String, dynamic> image) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                image['provider_name'] as String? ?? 'Unknown uploader',
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                [
                  if ((image['uploader_name'] as String? ?? '').isNotEmpty)
                    'Uploaded by ${image['uploader_name']}',
                  if ((image['city'] as String? ?? '').isNotEmpty)
                    _titleCase(image['city'] as String),
                  'from ${_sourceLabel(image['source'] as String?)}',
                  if (image['uploaded_at'] != null)
                    (image['uploaded_at'] as String).substring(0, 10),
                ].join(' · '),
                style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
              ),
              if ((image['caption'] as String? ?? '').isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(image['caption'] as String,
                    style: const TextStyle(fontSize: 12.5)),
              ],
              const SizedBox(height: 4),
              _statusChip(image['is_public'] == true),
              const SizedBox(height: 14),
              // Hide is offered before delete, and is the default emphasis:
              // removal is irreversible and takes the provider's copy too.
              if (image['is_public'] == true)
                _action(
                  icon: Icons.visibility_off_outlined,
                  label: 'Hide from public',
                  detail: 'Reversible. They keep the photo.',
                  onTap: () {
                    Navigator.pop(ctx);
                    _setPublic(image, false);
                  },
                )
              else if (image['source'] == 'provider_gallery')
                _action(
                  icon: Icons.visibility_outlined,
                  label: 'Put back in public',
                  detail: 'Needs a reason. It will be logged.',
                  onTap: () {
                    Navigator.pop(ctx);
                    _setPublic(image, true);
                  },
                ),
              _action(
                icon: Icons.campaign_outlined,
                label: 'Warn the uploader',
                detail: 'Send them a message from this section.',
                onTap: () {
                  Navigator.pop(ctx);
                  _warn(image);
                },
              ),
              _action(
                icon: Icons.delete_outline,
                label: 'Delete permanently',
                detail: 'Removes the file. This cannot be undone.',
                destructive: true,
                onTap: () {
                  Navigator.pop(ctx);
                  _remove(image);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusChip(bool isPublic) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: (isPublic ? AppTheme.primaryGreen : AppTheme.textMuted)
            .withOpacity(0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        isPublic ? 'Public' : 'Hidden',
        style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _action({
    required IconData icon,
    required String label,
    required String detail,
    required VoidCallback onTap,
    bool destructive = false,
  }) {
    final colour = destructive ? AppTheme.error : AppTheme.primaryGreenDark;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      enabled: !_working,
      onTap: onTap,
      leading: Icon(icon, size: 20, color: colour),
      title: Text(label,
          style: TextStyle(
              fontSize: 13.5, fontWeight: FontWeight.w600, color: colour)),
      subtitle: Text(detail,
          style: const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
    );
  }

  static String _sourceLabel(String? source) => switch (source) {
        'provider_gallery' => 'their gallery',
        'product_images' => 'a product listing',
        'vehicle_images' => 'a vehicle',
        _ => 'an upload',
      };

  static String _titleCase(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}