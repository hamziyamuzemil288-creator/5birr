import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/providers/auth_provider.dart';
import '../../core/services/city_service.dart';
import '../../core/services/points_service.dart';

class UserProfileScreen extends ConsumerWidget {
  const UserProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final profile = auth.profile;

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            // Profile header card
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.cardBorder, width: 0.5),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.04),
                    blurRadius: 12,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Column(
                children: [
                  // Avatar with ring
                  Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: AppTheme.primaryGreen.withOpacity(0.3),
                          width: 2),
                    ),
                    child: Container(
                      width: 76,
                      height: 76,
                      decoration: BoxDecoration(
                        color: AppTheme.primaryGreen.withOpacity(0.1),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.person,
                          color: AppTheme.primaryGreen, size: 38),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(profile?.fullName ?? 'User',
                      style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary)),
                  const SizedBox(height: 4),
                  if (profile?.phone != null && profile!.phone!.isNotEmpty)
                    Text(profile.phone!,
                        style: const TextStyle(
                            fontSize: 13, color: AppTheme.textSecondary)),
                  if (profile?.email != null && profile!.email!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(profile.email!,
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.textMuted)),
                  ],
                  const SizedBox(height: 12),
                  // Status badge
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    decoration: BoxDecoration(
                      color: AppTheme.success.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      (profile?.status ?? 'ACTIVE')
                          .replaceAll('_', ' ')
                          .toLowerCase(),
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.success),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // Loyalty points card
            _PointsCard(),
            const SizedBox(height: 20),
            // Menu card
            Container(
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.cardBorder, width: 0.5),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.03),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                children: [
                  _menuTile(Icons.person_outline, 'Edit Profile',
                      AppTheme.primaryGreen),
                  _divider(),
                  _menuTile(Icons.location_city_outlined, 'My City',
                      AppTheme.teal, onTap: () => _changeCity(context, ref)),
                  _divider(),
                  _menuTile(
                      Icons.location_on_outlined, 'Addresses', AppTheme.teal),
                  _divider(),
                  _menuTile(Icons.favorite_border, 'Favorites', AppTheme.error,
                      onTap: () => context.push('/user/favorites')),
                  _divider(),
                  _menuTile(Icons.notifications_outlined,
                      'Notification Settings', AppTheme.info),
                  _divider(),
                  // GPS / ride tracking: live map + directions to the driver.
                  _menuTile(Icons.map_outlined, 'My Rides (Live Tracking)',
                      AppTheme.teal,
                      onTap: () => context.push('/user/ride-active')),
                  _divider(),
                  _menuTile(Icons.history, 'Ride History', AppTheme.info,
                      onTap: () => context.push('/user/ride-history')),
                  _divider(),
                  _menuTile(Icons.help_outline, 'Help & Support', AppTheme.gold,
                      onTap: () => context.push('/help')),
                  _divider(),
                  _menuTile(Icons.info_outline, 'About Aliob',
                      AppTheme.textSecondary),
                ],
              ),
            ),
            const SizedBox(height: 24),
            // Logout button
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => ref.read(authProvider.notifier).signOut(),
                icon: const Icon(Icons.logout, color: AppTheme.error, size: 18),
                label: const Text('Logout',
                    style: TextStyle(color: AppTheme.error)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: AppTheme.error, width: 1.2),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  /// Phase 1: edit the saved city (profiles.city). Browsing follows the
  /// saved city unless travel mode is on.
  Future<void> _changeCity(BuildContext context, WidgetRef ref) async {
    final cityService = ref.read(cityProvider);
    final saved = cityService.savedCity ?? CityService.fallbackCity;
    final picked = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('My City'),
        children: [
          for (final c in CityService.knownCities)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(c),
              child: Row(
                children: [
                  Icon(
                    c == saved
                        ? Icons.check_circle
                        : Icons.location_city_outlined,
                    size: 18,
                    color: c == saved ? AppTheme.primaryGreen : AppTheme.textMuted,
                  ),
                  const SizedBox(width: 8),
                  Text(c),
                ],
              ),
            ),
        ],
      ),
    );
    if (picked == null || picked == saved) return;
    final ok = await ref.read(cityProvider).updateSavedCity(picked);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok
            ? 'City updated to $picked'
            : 'Could not update the city — try again'),
      ));
    }
  }

  Widget _menuTile(IconData icon, String label, Color iconColor,
      {VoidCallback? onTap}) {
    return ListTile(
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: iconColor.withOpacity(0.08),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Icon(icon, color: iconColor, size: 18),
      ),
      onTap: onTap,
      title: Text(label,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
      trailing:
          const Icon(Icons.chevron_right, color: AppTheme.textMuted, size: 20),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(0)),
    );
  }

  Widget _divider() {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 16),
      child: Divider(height: 1, thickness: 0.5, color: AppTheme.cardBorder),
    );
  }
}

/// Live loyalty-points total for the signed-in user (Feature 3).
class _PointsCard extends StatefulWidget {
  @override
  State<_PointsCard> createState() => _PointsCardState();
}

class _PointsCardState extends State<_PointsCard> {
  int _points = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await PointsService.instance.getMyPoints();
      if (mounted)
        setState(() {
          _points = p;
          _loading = false;
        });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.primaryGreen.withOpacity(0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.primaryGreen.withOpacity(0.25)),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppTheme.primaryGreen.withOpacity(0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.stars_rounded,
                color: AppTheme.primaryGreen, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('My Points',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textSecondary)),
                const SizedBox(height: 2),
                _loading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: AppTheme.primaryGreen))
                    : Text('$_points points',
                        style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.primaryGreenDark)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
