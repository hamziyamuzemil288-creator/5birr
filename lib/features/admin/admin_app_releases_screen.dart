import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/load_error_view.dart';

/// Item I: the admin "App Releases" screen.
///
/// One card per platform (android, ios). An admin sets the latest build, the
/// MINIMUM build the platform still accepts, the store link and the message in
/// English, Amharic and Oromo, and decides whether the gate BLOCKS (force) or
/// merely PROMPTS.
///
/// Two safety properties are enforced by the UI and by the server:
///
/// * Turning force ON requires ticking "This build is 100% live on Play
///   Store". The server refuses an unconfirmed force (`FORCE_REQUIRES_THE_
///   STORE_CONFIRMATION`), so the checkbox is a real constraint and not a
///   decorative one.
/// * `min_required_build` can never exceed `latest_build` — a minimum above
///   the latest would gate every user forever with no version to update to.
///
/// "Notify all users" sends the in-app notice to everyone plus one batched push
/// carrying the store link, once per release. The button reports how many
/// people were reached, and says so plainly when the release has already been
/// announced instead of silently sending nothing.
class AdminAppReleasesScreen extends StatefulWidget {
  const AdminAppReleasesScreen({super.key});

  @override
  State<AdminAppReleasesScreen> createState() => _AdminAppReleasesScreenState();
}

class _AdminAppReleasesScreenState extends State<AdminAppReleasesScreen> {
  bool _loading = true;
  String? _error;
  final Map<String, _PlatformForm> _forms = {};

  static const _platforms = ['android', 'ios'];

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
      for (final p in _platforms) {
        final res = await Supabase.instance.client
            .rpc('app_release_config_for', params: {'p_platform': p});
        _forms[p] = _PlatformForm.fromJson(Map<String, dynamic>.from(res as Map));
      }
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e, context: 'Could not load the release settings');
        });
      }
    }
  }

  Future<void> _save(String platform) async {
    final f = _forms[platform]!;
    if (f.force && !f.forceConfirmed) {
      _snack('Tick "This build is 100% live on Play Store" before forcing.');
      return;
    }
    if (f.minRequired > f.latest) {
      _snack('The minimum build cannot be higher than the latest build.');
      return;
    }
    setState(() => f.saving = true);
    try {
      await Supabase.instance.client.rpc('admin_save_app_release', params: {
        'p_platform': platform,
        'p_latest_build': f.latest,
        'p_min_required_build': f.minRequired,
        'p_store_url': f.storeUrl,
        'p_package_id': f.packageId,
        'p_message_en': f.messageEn,
        'p_message_am': f.messageAm,
        'p_message_om': f.messageOm,
        'p_force_enabled': f.force,
        'p_confirm_force': f.forceConfirmed,
      });
      if (mounted) setState(() => f.saving = false);
      _snack('Saved. Clients pick this up on their next check.');
    } catch (e) {
      if (mounted) setState(() => f.saving = false);
      _snack(friendlyError(e, context: 'Could not save the release settings'));
    }
  }

  Future<void> _notify(String platform) async {
    final f = _forms[platform]!;
    setState(() => f.notifying = true);
    try {
      final res = await Supabase.instance.client.rpc(
        'admin_notify_all_users_of_release',
        params: {'p_platform': platform},
      );
      final map = Map<String, dynamic>.from(res as Map);
      if (!mounted) return;
      setState(() => f.notifying = false);
      if (map['already_notified'] == true) {
        _snack('This release was already announced to '
            '${map['delivered'] ?? 0} users. Nothing was sent again.');
      } else {
        _snack('Sent to ${map['delivered'] ?? 0} users '
            '(push to ${map['token_count'] ?? 0} devices).');
      }
    } catch (e) {
      if (mounted) setState(() => f.notifying = false);
      _snack(friendlyError(e, context: 'Could not notify users'));
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('App Releases'),
        actions: [
          IconButton(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload',
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : _error != null
              ? LoadErrorView(message: _error!, onRetry: _load)
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppTheme.creamDark,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppTheme.cardBorder),
                      ),
                      child: const Text(
                        'The minimum build is the oldest version the platform '
                        'still accepts. Below it, the app shows a full-screen '
                        'update gate that cannot be dismissed, and the server '
                        'rejects orders, rides, listings and payments from that '
                        'build. Raising it locks those users out until they '
                        'update, so only raise it once the new build is live '
                        'on the store.',
                        style: TextStyle(
                            fontSize: 12.5,
                            height: 1.45,
                            color: AppTheme.textSecondary),
                      ),
                    ),
                    const SizedBox(height: 16),
                    for (final p in _platforms) _platformCard(p),
                  ],
                ),
    );
  }

  Widget _platformCard(String platform) {
    final f = _forms[platform]!;
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(platform == 'ios' ? Icons.apple : Icons.android,
                    color: AppTheme.primaryGreen),
                const SizedBox(width: 8),
                Text(
                  platform == 'ios' ? 'iOS' : 'Android',
                  style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.textPrimary),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: _numberField(
                    'Latest build',
                    f.latest,
                    (v) => setState(() => f.latest = v),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _numberField(
                    'Minimum build',
                    f.minRequired,
                    (v) => setState(() => f.minRequired = v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _textField('Store URL', f.storeUrl,
                (v) => f.storeUrl = v, TextInputType.url),
            const SizedBox(height: 12),
            _textField('Package id', f.packageId,
                (v) => f.packageId = v, TextInputType.text),
            const SizedBox(height: 12),
            _textField('Message (English)', f.messageEn,
                (v) => f.messageEn = (v ?? ''), TextInputType.text,
                maxLines: 2),
            const SizedBox(height: 12),
            _textField('Message (Amharic)', f.messageAm,
                (v) => f.messageAm = v, TextInputType.text,
                maxLines: 2),
            const SizedBox(height: 12),
            _textField('Message (Oromo)', f.messageOm,
                (v) => f.messageOm = v, TextInputType.text,
                maxLines: 2),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: f.force,
              activeColor: AppTheme.primaryGreen,
              title: const Text('Force the update (block the app)',
                  style: TextStyle(fontSize: 14)),
              subtitle: const Text(
                'Off: a prompt the user can dismiss. On: a gate that cannot be '
                'dismissed.',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              ),
              onChanged: (v) => setState(() {
                f.force = v;
                if (!v) f.forceConfirmed = false;
              }),
            ),
            if (f.force)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: f.forceConfirmed,
                activeColor: AppTheme.primaryGreen,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text(
                  'This build is 100% live on Play Store',
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                ),
                subtitle: const Text(
                  'Users below the minimum cannot use the app until they '
                  'update. Confirm the new build is really available.',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                ),
                onChanged: (v) =>
                    setState(() => f.forceConfirmed = v ?? false),
              ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: f.saving ? null : () => _save(platform),
                    style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.primaryGreen),
                    icon: const Icon(Icons.save_outlined, size: 18),
                    label: Text(f.saving ? 'Saving…' : 'Save'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: f.notifying ? null : () => _notify(platform),
                    icon: const Icon(Icons.campaign_outlined, size: 18),
                    label: Text(
                        f.notifying ? 'Sending…' : 'Notify all users'),
                  ),
                ),
              ],
            ),
            if (f.updatedAt != null) ...[
              const SizedBox(height: 8),
              Text(
                'Last saved ${f.updatedAt}'
                '${f.notifyDelivered > 0 ? ' · ${f.notifyDelivered} users notified' : ''}',
                style: const TextStyle(
                    fontSize: 11.5, color: AppTheme.textMuted),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _numberField(String label, int value, ValueChanged<int> onChanged) {
    return TextFormField(
      initialValue: value.toString(),
      keyboardType: TextInputType.number,
      decoration: InputDecoration(labelText: label),
      onChanged: (v) => onChanged(int.tryParse(v.trim()) ?? value),
    );
  }

  Widget _textField(
    String label,
    String? value,
    ValueChanged<String?> onChanged,
    TextInputType keyboardType, {
    int maxLines = 1,
  }) {
    return TextFormField(
      initialValue: value ?? '',
      keyboardType: keyboardType,
      maxLines: maxLines,
      decoration: InputDecoration(labelText: label),
      onChanged: (v) => onChanged(v.trim().isEmpty ? null : v.trim()),
    );
  }
}

/// The editable state of one platform's card. Mutable on purpose — the fields
/// are bound to a live form, and a copy-on-write object would make every
/// keystroke a rebuild of a new instance.
class _PlatformForm {
  _PlatformForm({
    required this.latest,
    required this.minRequired,
    required this.force,
    required this.notifyDelivered,
    this.storeUrl,
    this.packageId,
    this.messageEn = '',
    this.messageAm,
    this.messageOm,
    this.updatedAt,
  });

  int latest;
  int minRequired;
  bool force;
  bool forceConfirmed = false;
  int notifyDelivered;
  String? storeUrl;
  String? packageId;
  String messageEn;
  String? messageAm;
  String? messageOm;
  String? updatedAt;
  bool saving = false;
  bool notifying = false;

  factory _PlatformForm.fromJson(Map<String, dynamic> j) => _PlatformForm(
        latest: (j['latest_build'] as num?)?.toInt() ?? 0,
        minRequired: (j['min_required_build'] as num?)?.toInt() ?? 0,
        force: j['force_enabled'] == true,
        notifyDelivered: (j['notify_delivered'] as num?)?.toInt() ?? 0,
        storeUrl: j['store_url'] as String?,
        packageId: j['package_id'] as String?,
        messageEn: (j['message_en'] as String?) ?? '',
        messageAm: j['message_am'] as String?,
        messageOm: j['message_om'] as String?,
        updatedAt: j['updated_at'] as String?,
      );
}
