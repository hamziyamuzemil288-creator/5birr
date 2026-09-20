import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' as geo;

import '../../core/widgets/cart_icon_button.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/services/location_service.dart';

class UserSearchScreen extends StatefulWidget {
  const UserSearchScreen({super.key});
  @override
  State<UserSearchScreen> createState() => _UserSearchScreenState();
}

class _UserSearchScreenState extends State<UserSearchScreen> {
  final _ctrl = TextEditingController();
  List<Map<String, dynamic>> _results = [];
  bool _loading = false;
  bool _searched = false;
  Timer? _debounce;

  // Live GPS: distance-from-user comes from the real device position.
  geo.Position? _myPos;

  @override
  void initState() {
    super.initState();
    _primeLocation();
  }

  /// One-time live GPS prime (permission prompt fires on first use).
  Future<void> _primeLocation() async {
    final r = await LocationService.instance.getCurrentPositionDetailed();
    if (!mounted) return;
    if (r.success) {
      setState(() => _myPos = r.position);
      // Re-run the last query so distance_km fills in from real GPS.
      if (_ctrl.text.trim().isNotEmpty) _search(_ctrl.text.trim());
    }
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(value));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _search(String q) async {
    if (q.trim().isEmpty) return;
    setState(() {
      _loading = true;
      _searched = true;
    });
    try {
      // Server-side full-text + geo search. Passing the live GPS position
      // makes the server compute real distance_km per result and lets the
      // user sort by distance; without permission it still works (no distance).
      final pos = _myPos;
      final data =
          await Supabase.instance.client.rpc('search_products', params: {
        'p_query': q.trim(),
        'p_limit': 30,
        'p_offset': 0,
        if (pos != null) ...{
          'p_lat': pos.latitude,
          'p_lng': pos.longitude,
          'p_sort_by': 'distance',
        },
      });
      if (mounted) {
        setState(() {
          _results = List<Map<String, dynamic>>.from(data as List);
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Live-GPS distance badge, e.g. " · 2.4 km" (null until GPS granted
  /// and the listing has a known location).
  String _distanceSuffix(Map<String, dynamic> p) {
    if (_myPos == null) return '';
    final d = p['distance_km'];
    if (d == null) return '';
    final km = (d as num).toDouble();
    return km < 1
        ? ' · ${(km * 1000).round()} m'
        : ' · ${km.toStringAsFixed(1)} km';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          color: AppTheme.primaryGreen,
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  onSubmitted: _onQueryChanged,
                  onChanged: _onQueryChanged,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Search products, services...',
                    hintStyle: TextStyle(color: Colors.white.withOpacity(0.6)),
                    prefixIcon: const Icon(Icons.search,
                        color: Colors.white70, size: 20),
                    filled: true,
                    fillColor: Colors.white.withOpacity(0.15),
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none),
                  ),
                ),
              ),
              const CartIconButton(iconColor: Colors.white),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(
                  child:
                      CircularProgressIndicator(color: AppTheme.primaryGreen))
              : !_searched
                  ? const Center(
                      child: Text('Search for products and services',
                          style: TextStyle(color: AppTheme.textMuted)))
                  : _results.isEmpty
                      ? const Center(
                          child: Text('No results found',
                              style: TextStyle(color: AppTheme.textMuted)))
                      : ListView.builder(
                          padding: const EdgeInsets.all(16),
                          itemCount: _results.length,
                          itemBuilder: (_, i) {
                            final p = _results[i];
                            return ListTile(
                              onTap: () =>
                                  context.push('/user/product/${p['id']}'),
                              leading: Container(
                                width: 48,
                                height: 48,
                                decoration: BoxDecoration(
                                  color: AppTheme.creamDark,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Icon(Icons.inventory_2_outlined,
                                    color: AppTheme.textMuted),
                              ),
                              title: Text(p['name'] ?? '',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 14)),
                              subtitle: Text(
                                  '${p['provider_name'] ?? ''} · '
                                  '${p['price']} ${p['currency'] ?? 'ETB'}'
                                  '${p['unit'] == 'KG' ? '/kg' : p['unit'] == 'LTR' ? '/liter' : ''}'
                                  '${_distanceSuffix(p)}',
                                  style: const TextStyle(
                                      fontSize: 12,
                                      color: AppTheme.primaryGreen,
                                      fontWeight: FontWeight.w600)),
                            );
                          },
                        ),
        ),
      ],
    );
  }
}
