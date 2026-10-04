import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme/app_theme.dart';
import '../../core/services/location_service.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/load_error_view.dart';

/// A provider's public destination: the EXACT GPS a buyer sees only after a
/// payment screenshot is uploaded and approved, plus the necessary info
/// (name, phone, address) that the same approval unlocks.
class ProviderLocationDetailScreen extends ConsumerStatefulWidget {
  final String providerId;
  const ProviderLocationDetailScreen({super.key, required this.providerId});

  @override
  ConsumerState<ProviderLocationDetailScreen> createState() =>
      _ProviderLocationDetailScreenState();
}

class _ProviderLocationDetailScreenState
    extends ConsumerState<ProviderLocationDetailScreen> {
  Map<String, dynamic>? _profile;
  Map<String, dynamic>? _approvedLocation;
  bool _loading = true;
  bool _error = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final client = Supabase.instance.client;
      final profile = await client
          .from('provider_profiles')
          .select(
            'id, business_name, phone, address_text, business_address, '
            'location_lat, location_lng',
          )
          .eq('id', widget.providerId)
          .maybeSingle();

      // Approved (buyer-visible) point — the one the buyer is allowed to
      // read after payment is verified. A provider who never approved a point
      // still shows their editable business GPS.
      Map<String, dynamic>? approved;
      try {
        approved = (await client
                .rpc('get_approved_location_for_buyer', params: {
              'p_provider_id': widget.providerId,
              'p_buyer_id': client.auth.currentUser?.id,
            }))
            as Map<String, dynamic>?;
      } catch (_) {
        approved = null;
      }

      if (mounted) {
        setState(() {
          _profile = profile;
          _approvedLocation = approved ?? profile; // fallback to editable GPS
          _loading = false;
          _error = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = true;
          _errorMessage = friendlyError(e, context: 'Could not load provider');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Provider Destination'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error
              ? LoadErrorView(message: _errorMessage!, onRetry: _load)
              : _profile == null
                  ? const Center(
                      child: Text(
                          'This provider does not have a business profile'),
                    )
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Header
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [
                                  AppTheme.primaryGreen,
                                  AppTheme.primaryGreenDark
                                ],
                              ),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _profile!['business_name'] ?? 'Provider',
                                  style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    _approvedLocation != null
                                        ? 'APPROVED FOR BUYERS'
                                        : 'EDITABLE BUSINESS GPS',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 20),

                          // The approved location card: exactly what the buyer
                          // sees once approval is granted.
                          if (_approvedLocation != null) ...[
                            _gpsCard(),
                            const SizedBox(height: 16),
                          ] else ...[
                            _emptyGpsCard(),
                            const SizedBox(height: 16),
                          ],

                          // Necessary info (name + phone) — same approval window
                          // as the GPS card.
                          _contactCard(),

                          const SizedBox(height: 16),

                          // Business address / description.
                          _addressCard(),

                          const SizedBox(height: 24),

                          // Provider's phone as a tap-to-call control.
                          _phoneCard(),
                        ],
                      ),
                    ),
    );
  }

  /// The exact GPS the buyer is allowed to see.
  Widget _gpsCard() {
    final loc = _approvedLocation!;
    final lat = (loc['location_lat'] as num?)?.toDouble();
    final lng = (loc['location_lng'] as num?)?.toDouble();
    final businessName = _profile!['business_name'] ?? 'Provider';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.teal.withOpacity(0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.teal.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.my_location, size: 18, color: AppTheme.teal),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Approved Location for Buyers (business: $businessName)',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),
              Text(
                'APPROVED',
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.teal,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (lat != null && lng != null) ...[
            Row(
              children: [
                const Icon(Icons.map, size: 16, color: AppTheme.textMuted),
                const SizedBox(width: 6),
                Text(
                  '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Exact GPS — the point a rider should be taken to.',
              style: const TextStyle(
                fontSize: 12,
                color: AppTheme.textMuted,
              ),
            ),
          ] else ...[
            const Text(
              'No approved GPS yet.',
              style: TextStyle(
                fontSize: 13,
                color: AppTheme.textSecondary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'The provider has not approved an exact GPS for buyers. '
              'The place they are known by is shown in the address below.',
              style: const TextStyle(
                fontSize: 12,
                color: AppTheme.textMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// No approved point yet: a clear, non-blank slate.
  Widget _emptyGpsCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.gold.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.gold.withOpacity(0.45)),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'No approved GPS for buyers',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: AppTheme.textPrimary,
            ),
          ),
          SizedBox(height: 6),
          Text(
            'This provider has not approved an exact GPS for buyers yet. '
            'Only the business address is here.',
            style: TextStyle(
              fontSize: 12,
              color: AppTheme.textMuted,
            ),
          ),
        ],
      ),
    );
  }

  /// Contact card: name + phone, released only after payment is verified.
  Widget _contactCard() {
    final profile = _profile!;
    final name = profile['business_name'] ?? 'Provider';
    final phone = profile['phone'];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.primaryGreen.withOpacity(0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.primaryGreen.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.person, size: 18, color: AppTheme.primaryGreen),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Provider — $name',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),
              const Text(
                'APPROVED',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.primaryGreen,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (phone != null && phone.toString().isNotEmpty)
            Text(
              phone.toString(),
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppTheme.primaryGreen,
                letterSpacing: 0.5,
              ),
            )
          else
            const Text(
              'Phone not published.',
              style: TextStyle(
                fontSize: 13,
                color: AppTheme.textSecondary,
              ),
            ),
          const SizedBox(height: 6),
          const Text(
            'Your payment has been verified, so you can contact the provider '
            'directly.',
            style: TextStyle(fontSize: 12, height: 1.4),
          ),
        ],
      ),
    );
  }

  /// Business address / necessary info.
  Widget _addressCard() {
    final profile = _profile!;
    final address = [
      profile['address_text'],
      profile['business_address'],
    ].whereType<String>().firstWhere((s) => s.isNotEmpty, orElse: () => '');
    final businessName = profile['business_name'] ?? 'Provider';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Business Location',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          if (address.isNotEmpty)
            Text(
              address,
              style: const TextStyle(fontSize: 14, height: 1.4),
            )
          else
            Text(
              '$businessName — no business address on file.',
              style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
            ),
        ],
      ),
    );
  }

  /// Provider phone, tap-to-call.
  Widget _phoneCard() {
    final phone = _profile!['phone'];
    if (phone == null || phone.toString().isEmpty) {
      return const SizedBox.shrink();
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Row(
        children: [
          const Icon(Icons.call, size: 20, color: AppTheme.primaryGreen),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Call ${phone.toString()}',
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
              ),
            ),
          ),
          TextButton(
            onPressed: () {
              // Tap-to-call. The phone call URI scheme is handled by
              // `LocationService.openPhoneCall()`, which is wired for the web
              // build so this screen does not need dart:io.
              LocationService.instance.openPhoneCall(phone.toString());
            },
            child: const Text(
              'CALL',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppTheme.primaryGreen,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
