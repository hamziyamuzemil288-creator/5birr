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

/// Fills in the profile fields an OAuth sign-up never supplies.
///
/// ## Why this screen exists
///
/// `handle_new_user()` builds the profile entirely from
/// `raw_user_meta_data`. The password flow passes full_name, phone, city,
/// kebele and street_road through `signUp(data:)`; Google supplies none of
/// them, so an OAuth account arrives with `full_name = 'New User'` and
/// phone/kebele/street_road NULL.
///
/// The document upload is not what breaks — `user_documents` only needs
/// user_id, document_type and storage_path, so the upload succeeds. What
/// breaks is *verification*: the admin reviewing that account renders
/// `phone ?? ''` as a blank line and hides the national-ID row entirely, so
/// they are handed a document with no identity to check it against.
///
/// ## Why these exact fields
///
/// Deliberately the same fields, hints and validators as
/// `signup_screen.dart`'s `_buildFormFields`, copied rather than abstracted:
/// a shared form widget across two screens with different submit semantics
/// is worse than the duplication it removes. If one changes, change both —
/// `check_oauth_profile_completion_is_wired` asserts the field set.
class CompleteProfileScreen extends ConsumerStatefulWidget {
  const CompleteProfileScreen({super.key});

  @override
  ConsumerState<CompleteProfileScreen> createState() =>
      _CompleteProfileScreenState();
}

class _CompleteProfileScreenState extends ConsumerState<CompleteProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _kebeleController = TextEditingController();
  final _streetRoadController = TextEditingController();

  String? _selectedCity;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _prefill();
  }

  /// Seeds the form from what the trigger already knows, so the user only
  /// types what is genuinely missing rather than re-entering their email.
  void _prefill() {
    final auth = ref.read(authProvider);
    final profile = auth.profile;
    final name = profile?.fullName ?? '';
    _nameController.text =
        (name.isEmpty || name == 'New User') ? '' : name;
    _phoneController.text = profile?.phone ?? '';
    _selectedCity = profile?.city;
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
        // Stored the same way signup stores it, so the two flows do not
        // produce two different phone formats for the same person.
        'p_phone': PhoneFormatter.formatToE164(_phoneController.text.trim()) ??
            _phoneController.text.trim(),
        'p_city': _selectedCity,
        'p_kebele': _kebeleController.text.trim(),
        'p_street_road': _streetRoadController.text.trim(),
      });
      // The router gate reads authProvider.profile, so it must be refreshed
      // before navigating or it bounces straight back here.
      await ref.read(authProvider.notifier).refreshProfile();
      if (!mounted) return;
      context.go('/pending-approval');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = friendlyError(e, context: 'Could not save your details');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Complete your profile')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('One more step', style: AppTheme.sectionHeader),
                const SizedBox(height: 8),
                const Text(
                  'You signed in with Google, so we do not have your phone '
                  'number or address yet. We need them before an admin can '
                  'verify your account, and your documents cannot be checked '
                  'without them.',
                  style: AppTheme.caption,
                ),
                const SizedBox(height: 24),
                if (_error != null) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.error.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _error!,
                      style: const TextStyle(
                          color: AppTheme.error, fontSize: 13),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                BirrTextField(
                  label: 'Full Name',
                  hint: 'As it appears on your ID',
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
                    hintText: 'Select your city',
                    prefixIcon: Icon(Icons.location_city_outlined),
                  ),
                  items: CityService.knownCities
                      .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                      .toList(),
                  validator: (v) =>
                      (v == null || v.isEmpty) ? 'City is required' : null,
                  onChanged: (v) => setState(() => _selectedCity = v),
                ),
                const SizedBox(height: 16),
                BirrTextField(
                  label: 'Kebele',
                  hint: 'e.g. Kebele 08',
                  controller: _kebeleController,
                  textInputAction: TextInputAction.next,
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) {
                      return 'Kebele is required';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                BirrTextField(
                  label: 'Street / Road',
                  hint: 'e.g. Bole Road, near Edna Mall',
                  controller: _streetRoadController,
                  textInputAction: TextInputAction.done,
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) {
                      return 'Street / Road is required';
                    }
                    return null;
                  },
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
                const SizedBox(height: 4),
                const Padding(
                  padding: EdgeInsets.only(left: 4),
                  child: Text(
                    'Ethiopian numbers only — enter as 0912345678, '
                    '+251912345678, or 251912345678',
                    style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
                  ),
                ),
                const SizedBox(height: 28),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.primaryGreen,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Text('Save and continue'),
                  ),
                ),
                const SizedBox(height: 12),
                // Never a dead end: an account that cannot complete its
                // profile must still be able to sign out, or a user with a
                // rejected value is trapped on this screen.
                Center(
                  child: TextButton(
                    onPressed: _saving
                        ? null
                        : () => ref.read(authProvider.notifier).signOut(),
                    child: const Text('Sign out'),
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
