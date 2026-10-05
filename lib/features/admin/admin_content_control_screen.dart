import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/load_error_view.dart';
import 'widgets/public_image_gallery.dart';
import 'widgets/image_delete_sheet.dart';

/// Content control: the queue of reports, the record of what has been taken
/// down, and the two actions this screen exists for.
///
/// Reached from the admin sidebar as "Content Control".
///
/// WHY THIS IS A SEPARATE SURFACE
/// ------------------------------
/// `AdminUserManagementScreen` can suspend an account and
/// `AdminProviderManagementScreen` can suspend a provider. Neither can remove
/// a single uploaded photograph, and neither records what was done or why. An
/// administrator looking at a gallery image that breaks the terms had exactly
/// two options -- leave it up, or delete the provider -- and the second is
/// destructive enough that nobody reaches for it over a picture.
///
/// THE TWO THINGS IT DOES
/// ----------------------
///   * removes one image: the referencing row AND the storage object, in one
///     server call, so a row can never be left pointing at a file that is gone;
///   * suspends or reinstates an account, writing `profiles` and
///     `provider_profiles` together, because the router gates on `profiles`
///     and the admin panel reads `provider_profiles`, and a half-written
///     suspension locks somebody out of their own account.
///
/// Every action carries a reason and lands in `moderation_actions`, which is
/// append-only: no RLS policy lets anybody edit or delete it, an administrator
/// included.
class AdminContentControlScreen extends StatefulWidget {
  const AdminContentControlScreen({super.key});

  @override
  State<AdminContentControlScreen> createState() =>
      _AdminContentControlScreenState();
}

class _AdminContentControlScreenState extends State<AdminContentControlScreen> {
  List<Map<String, dynamic>> _reports = const [];
  List<Map<String, dynamic>> _actions = const [];
  List<Map<String, dynamic>> _imagesForDelete = const [];
  bool _loading = true;
  bool _working = false;
  String? _error;
  String _filter = 'OPEN';

  static const _filters = <String, String>{
    'OPEN': 'Open',
    'REVIEWING': 'Reviewing',
    'UPHELD': 'Upheld',
    'DISMISSED': 'Dismissed',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = Supabase.instance.client;
      // Read the queue and the history together, and read the queue only for
      // the selected status -- asking for all of them and filtering in Dart is
      // how a screen ends up showing a stale count next to a fresh list.
      final results = await Future.wait([
        client.rpc('admin_content_reports', params: {
          'p_status': _filter == 'ALL' ? null : _filter,
          'p_limit': 100,
        }),
        client.rpc('admin_moderation_actions', params: {'p_limit': 60}),
        client.rpc('admin_public_image_gallery', params: {
          'p_city': '',
          'p_limit': 200,
          'p_offset': 0,
        }),
      ]);

      if (!mounted) return;
      setState(() {
        _reports = List<Map<String, dynamic>>.from(results[0] as List);
        _actions = List<Map<String, dynamic>>.from(results[1] as List);
        _imagesForDelete = List<Map<String, dynamic>>.from(results[2] as List);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e, context: 'Could not load the moderation queue');
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
        _snack(friendlyError(e, context: label), bad: true);
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// A reason is mandatory on the server, and asking for it here means the
  /// dialog cannot be dismissed with something the server will refuse.
  Future<String?> _askReason(String title, {String confirm = 'Confirm'}) async {
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

  /// Remove an image chosen from the delete-only gallery strip.
  ///
  /// The server call needs the bucket and path, so this only snapshots the
  /// values the server needs from the `admin_public_image_gallery` row.
  Future<void> _removeImageFromRow(Map<String, dynamic> image) async {
    final bucket = image['bucket'] as String?;
    final path = image['storage_path'] as String?;
    if (bucket == null || bucket.isEmpty || path == null || path.isEmpty) {
      _snack('That image has no usable path, so it cannot be deleted.',
          bad: true);
      return;
    }
    final reason = await _askReason(
      'Remove this image?',
      confirm: 'Remove image',
    );
    if (reason == null || !mounted) return;

    await _run('Image removal', () {
      return Supabase.instance.client.rpc('admin_moderate_image_with_reason', params: {
        'p_bucket': bucket,
        'p_path': path,
        'p_reason': reason,
        'p_severity': 'SERIOUS',
      });
    });
  }

  /// Remove an image by its storage path.
  ///
  /// The bucket is recovered from the path shape -- every upload in this
  /// project is `<uid>/...`. An unknown shape is refused by the server rather
  /// than guessed at here.
  Future<void> _removeImage(String path) async {
    if (path.isEmpty || !path.contains('/')) {
      _snack('That path has no owner folder, so it cannot be removed.',
          bad: true);
      return;
    }
    final reason = await _askReason(
      'Remove this image?',
      confirm: 'Remove image',
    );
    if (reason == null || !mounted) return;

    await _run('Image removal', () {
      return Supabase.instance.client.rpc('admin_moderate_image', params: {
        'p_bucket': _bucketFor(path),
        'p_path': path,
        'p_reason': reason,
        'p_severity': 'SERIOUS',
      });
    });
  }

  /// The bucket is not stored on the report, so it is recovered from the
  /// path's shape -- every upload in this project is `<uid>/...`. An unknown
  /// shape is refused by the server rather than guessed at here.
  String _bucketFor(String path) {
    if (path.contains('/photo') || path.contains('/gallery')) {
      return 'provider-gallery';
    }
    if (path.contains('/avatar')) return 'profile-avatars';
    if (path.contains('/product')) return 'product-images';
    if (path.contains('/vehicle')) return 'vehicle-images';
    return 'provider-gallery';
  }

  Future<void> _suspend(Map<String, dynamic> report) async {
    final id = report['reported_user_id'] as String?;
    if (id == null) {
      _snack('This report is about an image, not an account. Remove the image '
          'instead of suspending somebody.', bad: true);
      return;
    }
    final reason = await _askReason('Suspend this account?', confirm: 'Suspend');
    if (reason == null || !mounted) return;

    await _run('Suspension', () {
      return Supabase.instance.client.rpc('admin_suspend_account', params: {
        'p_user_id': id,
        'p_reason': reason,
        'p_severity': 'CRITICAL',
      });
    });
  }

  /// The counterpart to `_suspend`, and the reason this screen's own class
  /// comment could claim it reinstates accounts while nothing in the app could
  /// actually do it: `admin_reinstate_account` existed in 0122 and was reached
  /// from no Dart file at all.
  ///
  /// 0123 restated it so the reinstatement carries its own keyed notice rather
  /// than the approval welcome -- the account was approved once already, and a
  /// "Welcome to Aliob" would imply somebody who had never left was leaving.
  Future<void> _reinstate(Map<String, dynamic> action) async {
    final id = action['target_user_id'] as String?;
    if (id == null) {
      _snack('That action was taken against a provider record, not a login.',
          bad: true);
      return;
    }
    final reason = await _askReason(
      'Reinstate this account?',
      confirm: 'Reinstate',
    );
    if (reason == null || !mounted) return;

    await _run('Reinstatement', () {
      return Supabase.instance.client.rpc('admin_reinstate_account', params: {
        'p_user_id': id,
        'p_reason': reason,
      });
    });
  }

  Future<void> _resolve(Map<String, dynamic> report, String outcome) async {
    final reason = await _askReason(
      outcome == 'UPHELD' ? 'Upheld — what did you do?' : 'Dismiss — why?',
      confirm: outcome == 'UPHELD' ? 'Uphold' : 'Dismiss',
    );
    if (reason == null || !mounted) return;

    await _run('Report', () {
      return Supabase.instance.client.rpc('admin_resolve_content_report', params: {
        'p_report_id': report['id'],
        'p_outcome': outcome,
        'p_note': reason,
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Content Control'),
        actions: [
          IconButton(
            tooltip: 'Reload',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : _error != null
              ? LoadErrorView(message: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                    children: [
                      _banner(),
                      const SizedBox(height: 20),
                      // The gallery comes FIRST. The report queue below it
                      // only ever showed images somebody had already
                      // complained about, which is why a moderator could not
                      // find a picture that broke the rules until a customer
                      // reported it. The question this section is opened with
                      // is "what is published right now", and that is the
                      // gallery, not the queue.
                      const PublicImageGallery(),
                      const SizedBox(height: 20),
                      const Text('Delete image',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.primaryGreenDark,
                          )),
                      const SizedBox(height: 4),
                      const Text(
                        'Pick any published image and delete it permanently. '
                        'This removes the file and unlinks the row in one call.',
                        style:
                            TextStyle(fontSize: 12, color: AppTheme.textMuted),
                      ),
                      const SizedBox(height: 14),
                      if (_imagesForDelete.isEmpty)
                        const _Empty(
                          icon: Icons.photo_library_outlined,
                          text: 'No published images to delete.',
                        )
                      else
                        for (final img in _imagesForDelete) _deleteRow(img),
                      const SizedBox(height: 24),
                      Text('Reported content',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.primaryGreenDark,
                          )),
                      const SizedBox(height: 4),
                      const Text(
                        'Images and accounts somebody has flagged.',
                        style:
                            TextStyle(fontSize: 12, color: AppTheme.textMuted),
                      ),
                      const SizedBox(height: 14),
                      _filterChips(),
                      const SizedBox(height: 14),
                      if (_reports.isEmpty)
                        const _Empty(
                          icon: Icons.verified_user_outlined,
                          text: 'Nothing in this queue.',
                        )
                      else
                        for (final r in _reports) ...[
                          _reportCard(r),
                          const SizedBox(height: 10),
                        ],
                      const SizedBox(height: 24),
                      Text('What has been done',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.primaryGreenDark,
                          )),
                      const SizedBox(height: 10),
                      if (_actions.isEmpty)
                        const _Empty(
                          icon: Icons.history,
                          text: 'No moderation action has been taken yet.',
                        )
                      else
                        for (final a in _actions) _actionRow(a),
                    ],
                  ),
                ),
    );
  }

  Widget _banner() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surfaceVariant,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.gavel, size: 18, color: AppTheme.primaryGreenDark),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Removing an image deletes it from storage and unlinks it in the '
              'same call. Suspending an account writes both the profile and the '
              'provider record, so nobody is left half-suspended. Everything '
              'here is written to an append-only log.',
              style: TextStyle(fontSize: 12, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterChips() {
    return Wrap(
      spacing: 8,
      children: [
        for (final entry in _filters.entries)
          ChoiceChip(
            label: Text(entry.value),
            selected: _filter == entry.key,
            selectedColor: AppTheme.primaryGreen.withOpacity(0.18),
            onSelected: (_) {
              setState(() => _filter = entry.key);
              _load();
            },
          ),
      ],
    );
  }

  Widget _reportCard(Map<String, dynamic> r) {
    final path = r['object_path'] as String?;
    final isOpen = r['status'] == 'OPEN' || r['status'] == 'REVIEWING';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _filter == 'OPEN'
              ? AppTheme.error.withOpacity(0.35)
              : AppTheme.cardBorder,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  (_label(r['category']) ?? 'Report').toUpperCase(),
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                    color: AppTheme.primaryGreenDark,
                  ),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppTheme.textMuted.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  r['status'] as String,
                  style: const TextStyle(fontSize: 10.5),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(r['description'] as String? ?? '',
              style: const TextStyle(fontSize: 13, height: 1.4)),
          if (path != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.image_outlined,
                    size: 15, color: AppTheme.textMuted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    path,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11, color: AppTheme.textMuted),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 4),
          Text(
            'filed ${(r['created_at'] as String? ?? '').substring(0, 10)}',
            style:
                const TextStyle(fontSize: 10.5, color: AppTheme.textMuted),
          ),
          if (isOpen) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: [
                if (path != null)
                  OutlinedButton.icon(
                    onPressed: _working ? null : () => _removeImageFromRow(r),
                    icon: const Icon(Icons.delete_forever, size: 16),
                    label: const Text('Delete image'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.error,
                      side: const BorderSide(color: AppTheme.error),
                    ),
                  ),
                if (r['reported_user_id'] != null)
                  OutlinedButton.icon(
                    onPressed: _working ? null : () => _suspend(r),
                    icon: const Icon(Icons.block, size: 16),
                    label: const Text('Suspend'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.error,
                      side: const BorderSide(color: AppTheme.error),
                    ),
                  ),
                OutlinedButton.icon(
                  onPressed: _working ? null : () => _resolve(r, 'UPHELD'),
                  icon: const Icon(Icons.check_circle_outline, size: 16),
                  label: const Text('Uphold'),
                ),
                OutlinedButton.icon(
                  onPressed: _working ? null : () => _resolve(r, 'DISMISSED'),
                  icon: const Icon(Icons.close, size: 16),
                  label: const Text('Dismiss'),
                ),
              ],
            ),
          ],
          if (!isOpen && r['resolution_note'] != null) ...[
            const SizedBox(height: 8),
            Text(
              'Resolution: ${r['resolution_note']}',
              style:
                  const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary),
            ),
          ],
        ],
      ),
    );
  }

  Widget _deleteRow(Map<String, dynamic> image) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.delete_outline,
          size: 18, color: AppTheme.error),
      title: Text(
        image['storage_path'] as String? ?? 'unknown image',
        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        [
          if ((image['bucket'] as String? ?? '').isNotEmpty) image['bucket'],
          if ((image['uploader_name'] as String? ?? '').isNotEmpty)
            'by ${image['uploader_name']}',
          (image['uploaded_at'] as String? ?? '').substring(0, 10),
        ]
            .where((part) => part.isNotEmpty)
            .join(' · '),
        style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
      ),
      trailing: OutlinedButton.icon(
        onPressed: _working ? null : () => _removeImageFromRow(image),
        icon: const Icon(Icons.delete_forever, size: 16),
        label: const Text('Delete'),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppTheme.error,
          side: const BorderSide(color: AppTheme.error),
        ),
      ),
    );
  }

  Widget _actionRow(Map<String, dynamic> a) {
    final type = a['action_type'] as String? ?? '';
    final path = a['object_path'] as String?;
    final who = (a['target_user_id'] ?? a['actioned_by_name']) as String?;
    // Reinstatement lives on the suspension that it reverses, not on the report
    // card: an administrator reads the history to answer "who did we take out,
    // and have we put them back?", and that question is asked here.
    final canReinstate =
        type == 'ACCOUNT_SUSPENDED' && a['target_user_id'] != null;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        type == 'IMAGE_REMOVED' ? Icons.image_not_supported_outlined : Icons.gavel,
        size: 18,
        color: AppTheme.primaryGreenDark,
      ),
      title: Text(
        type.replaceAll('_', ' ').toLowerCase(),
        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        [
          if (a['reason'] != null) a['reason'] as String,
          if (path != null) path,
          if (who != null && (a['actioned_by_name'] as String? ?? '').isNotEmpty)
            'by ${a['actioned_by_name']}',
          (a['created_at'] as String? ?? '').substring(0, 16).replaceAll('T', ' '),
        ].join(' · '),
        style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
      ),
      trailing: canReinstate
          ? TextButton.icon(
              onPressed: _working ? null : () => _reinstate(a),
              icon: const Icon(Icons.restore, size: 15),
              label: const Text('Reinstate'),
              style: TextButton.styleFrom(
                foregroundColor: AppTheme.primaryGreenDark,
                visualDensity: VisualDensity.compact,
              ),
            )
          : null,
    );
  }

  static String? _label(Object? category) => switch (category as String?) {
        'VIOLENT_OR_THREATENING' => 'Violence or a threat',
        'HARASSMENT' => 'Harassment',
        'NUDITY_OR_SEXUAL' => 'Sexual content',
        'HATE_OR_ABUSE' => 'Hate or abuse',
        'SPAM_OR_SCAMS' => 'Spam or scam',
        'MISLEADING_LISTING' => 'Misleading listing',
        'FAKE_ACCOUNT' => 'Fake account',
        _ => category,
      };
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Column(
        children: [
          Icon(icon, size: 30, color: AppTheme.textMuted.withOpacity(0.5)),
          const SizedBox(height: 8),
          Text(text, style: const TextStyle(fontSize: 12.5, color: AppTheme.textMuted)),
        ],
      ),
    );
  }
}