import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/providers/auth_provider.dart';
import '../../core/services/city_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/utils/phone_formatter.dart';
import '../../core/widgets/birr_text_field.dart';

/// Edit the caller's own profile.
///
/// This screen exists because the "Edit Profile" row on the account screen
/// was a `_menuTile` with no `onTap` at all — the tap did nothing, silently,
/// and no `/profile/edit` route had ever been declared. A menu row that
/// looks tappable and is not is worse than a missing row, so this is the
/// screen it should always have opened.
///
/// ## Why it saves through complete_profile()
///
/// Same reason as the OAuth screen: the `profiles` owner UPDATE policy is
/// defined in 0014, below the deploy baseline, and 20260927000050 closed the
/// client write surface, so a direct client update is not something this app
/// can rely on. One RPC, two callers.
///
/// ## Why the row is read directly
///
/// `UserProfile` carries id/fullName/phone/email/nationalId/status only —
/// it has no kebele, street_road or city, all three of which this form edits
/// and `complete_profile` requires. Reading the row is also the honest thing
/// to prefill an edit form from.
class EditProfileScreen extends ConsumerStatefulWidget {
  const EditProfileScreen({super.key});

  @override
  ConsumerState<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends ConsumerState<EditProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _kebeleController = TextEditingController();
  final _streetRoadController = TextEditingController();

  String? _selectedCity;
  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid == null) {
        if (mounted) {
          setState(() {
            _loading = false;
            _loadError = 'Please sign in again.';
          });
        }
        return;
      }
      final data = await Supabase.instance.client
          .from('profiles')
          .select()
          .eq('id', uid)
          .maybeSingle();

      if (!mounted) return;
      final row = (data as Map<String, dynamic>?) ?? const {};
      final name = (row['full_name'] as String?) ?? '';
      _nameController.text = (name.isEmpty || name == 'New User') ? '' : name;
      _phoneController.text = (row['phone'] as String?) ?? '';
      _kebeleController.text = (row['kebele'] as String?) ?? '';
      _streetRoadController.text = (row['street_road'] as String?) ?? '';
      setState(() {
        _selectedCity = row['city'] as String?;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        // Named, not an empty form: a blank form that silently fails to save
        // is the same failure mode as a menu row with no onTap.
        _loadError = friendlyError(e, context: 'Could not load your profile');
      });
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _kebeleController.dispose();
    _streetRoadController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await Supabase.instance.client.rpc('complete_profile', params: {
        'p_full_name': _nameController.text.trim(),
        'p_phone': PhoneFormatter.formatToE164(_phoneController.text.trim()) ??
            _phoneController.text.trim(),
        'p_city': _selectedCity,
        'p_kebele': _kebeleController.text.trim(),
        'p_street_road': _streetRoadController.text.trim(),
      });
      await ref.read(authProvider.notifier).refreshProfile();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile updated.')),
      );
      context.pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = friendlyError(e, context: 'Could not save your changes');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Edit Profile')),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : _loadError != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_loadError!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: AppTheme.error)),
                        const SizedBox(height: 16),
                        OutlinedButton(
                          onPressed: _load,
                          child: const Text('Try again'),
                        ),
                      ],
                    ),
                  ),
                )
              : SafeArea(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (_error != null) ...[
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: AppTheme.error.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(_error!,
                                  style: const TextStyle(
                                      color: AppTheme.error, fontSize: 13)),
                            ),
                            const SizedBox(height: 16),
                          ],
                          BirrTextField(
                            label: 'Full Name',
                            controller: _nameController,
                            textInputAction: TextInputAction.next,
                            validator: (v) {
                              if (v == null || v.trim().isEmpty) {
                                return 'Name is required';
                              }
                              if (v.trim().length < 2) return 'Name is too short';
                              return null;
                            },
                          ),
                          const SizedBox(height: 16),
                          DropdownButtonFormField<String>(
                            value: _selectedCity,
                            decoration: const InputDecoration(
                              labelText: 'City *',
                              prefixIcon: Icon(Icons.location_city_outlined),
                            ),
                            items: CityService.knownCities
                                .map((c) =>
                                    DropdownMenuItem(value: c, child: Text(c)))
                                .toList(),
                            validator: (v) => (v == null || v.isEmpty)
                                ? 'City is required'
                                : null,
                            onChanged: (v) => setState(() => _selectedCity = v),
                          ),
                          const SizedBox(height: 16),
                          BirrTextField(
                            label: 'Kebele',
                            controller: _kebeleController,
                            textInputAction: TextInputAction.next,
                            validator: (v) => (v == null || v.trim().isEmpty)
                                ? 'Kebele is required'
                                : null,
                          ),
                          const SizedBox(height: 16),
                          BirrTextField(
                            label: 'Street / Road',
                            controller: _streetRoadController,
                            textInputAction: TextInputAction.next,
                            validator: (v) => (v == null || v.trim().isEmpty)
                                ? 'Street / Road is required'
                                : null,
                          ),
                          const SizedBox(height: 16),
                          BirrTextField(
                            label: 'Phone Number',
                            hint: '0912345678',
                            controller: _phoneController,
                            keyboardType: TextInputType.phone,
                            textInputAction: TextInputAction.done,
                            validator: (v) {
                              if (v == null || v.trim().isEmpty) {
                                return 'Phone number is required';
                              }
                              return PhoneFormatter.validateEthiopianPhone(v);
                            },
                          ),
                          const SizedBox(height: 28),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                              onPressed: _saving ? null : _save,
                              style: FilledButton.styleFrom(
                                backgroundColor: AppTheme.primaryGreen,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 14),
                              ),
                              child: _saving
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2, color: Colors.white),
                                    )
                                  : const Text('Save changes'),
                            ),
                          ),
                          const SizedBox(height: 12),
                          // National ID is deliberately not editable here: it
                          // is verified against an uploaded document, and a
                          // typed-in number is not that evidence.
                          const Center(
                            child: Text(
                              'Your National ID is verified from the document '
                              'you upload, so it cannot be typed in here.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize: 11, color: AppTheme.textMuted),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
    );
  }
}
