import 'package:supabase_flutter/supabase_flutter.dart';

import 'location_service.dart' show GeoPoint;

class RideService {
  RideService._();
  static final instance = RideService._();
  final _client = Supabase.instance.client;

  /// Create a ride request.
  Future<Map<String, dynamic>> createRideRequest({
    required double pickupLat,
    required double pickupLng,
    required double destLat,
    required double destLng,
    String? pickupText,
    String? destText,
    String? vehicleCategoryId,
  }) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) throw Exception('Not authenticated');

    final data = await _client.rpc('create_ride_request', params: {
      'p_user_id': userId,
      'p_pickup_lat': pickupLat,
      'p_pickup_lng': pickupLng,
      'p_destination_lat': destLat,
      'p_destination_lng': destLng,
      'p_pickup_text': pickupText,
      'p_destination_text': destText,
      'p_vehicle_category_id': vehicleCategoryId,
    });
    return data as Map<String, dynamic>;
  }

  /// Claim a ride (driver side).
  Future<Map<String, dynamic>> claimRide({
    required String rideId,
    required String providerId,
    required String vehicleId,
  }) async {
    final result = await _client.functions.invoke('ride-claim', body: {
      'ride_id': rideId,
      'provider_id': providerId,
      'vehicle_id': vehicleId,
    });
    if (result.status != 200) {
      throw Exception(result.data['error'] ?? 'Claim failed');
    }
    return Map<String, dynamic>.from(result.data['ride'] as Map);
  }

  /// Transition ride status.
  Future<Map<String, dynamic>> transitionRide({
    required String rideId,
    required String newStatus,
  }) async {
    final userId = _client.auth.currentUser?.id;
    final result = await _client.functions.invoke('ride-transition', body: {
      'ride_id': rideId,
      'new_status': newStatus,
      'actor_id': userId,
    });
    if (result.status != 200) {
      throw Exception(result.data['error'] ?? 'Transition failed');
    }
    return Map<String, dynamic>.from(result.data['ride'] as Map);
  }

  /// Cancel a ride.
  Future<Map<String, dynamic>> cancelRide(String rideId) async {
    return transitionRide(rideId: rideId, newStatus: 'CANCELLED');
  }

  /// Get active ride for current user.
  Future<Map<String, dynamic>?> getMyActiveRide() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return null;
    final data = await _client
        .from('ride_requests')
        .select('*, driver_status!current_ride_id(provider_id, current_location)')
        .eq('user_id', userId)
        .inFilter('status', ['REQUESTED', 'CLAIMED', 'DRIVER_ARRIVING', 'ARRIVED', 'TRIP_STARTED'])
        .order('created_at', ascending: false)
        .maybeSingle();
    return data;
  }

  /// Get active ride for driver.
  Future<Map<String, dynamic>?> getMyActiveDriverRide() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return null;
    final prov = await _client
        .from('provider_profiles')
        .select('id')
        .eq('user_id', userId)
        .eq('provider_type', 'VEHICLE_PROVIDER')
        .maybeSingle();
    if (prov == null) return null;
    final data = await _client
        .from('ride_requests')
        .select('*, profiles!ride_requests_user_id_fkey(full_name, phone)')
        .eq('claimed_by_provider_id', prov['id'])
        .inFilter('status', ['CLAIMED', 'DRIVER_ARRIVING', 'ARRIVED', 'TRIP_STARTED'])
        .order('created_at', ascending: false)
        .maybeSingle();
    return data;
  }

  /// Watch ride requests (for drivers).
  Stream<List<Map<String, dynamic>>> watchRideRequests() {
    return _client
        .from('ride_requests')
        .stream(primaryKey: ['id'])
        .eq('status', 'REQUESTED')
        .order('created_at');
  }

  /// Watch a specific ride (for real-time updates).
  Stream<Map<String, dynamic>> watchRide(String rideId) {
    return _client
        .from('ride_requests')
        .stream(primaryKey: ['id'])
        .eq('id', rideId)
        .limit(1)
        .map((list) => list.isNotEmpty ? list.first : <String, dynamic>{});
  }

  /// Live driver_status changes for a provider.
  ///
  /// Used by the rider's Active Ride screen as a *refresh signal*: GPS pushes
  /// write driver_status only (never ride_requests), so without this the map
  /// never learns that the driver moved. RLS lets a rider see exactly the row
  /// assigned to their ride (driver_status_rider_read), so a rider receives no
  /// events for other drivers.
  Stream<List<Map<String, dynamic>>> watchDriverStatus(String providerId) {
    return _client
        .from('driver_status')
        .stream(primaryKey: ['provider_id'])
        .eq('provider_id', providerId);
  }

  /// The driver's current GPS point for a ride, re-fetched on each change
  /// signal. Read through PostgREST (not the realtime payload) so the
  /// geography arrives in the GeoJSON shape [GeoPoint.parse] already handles.
  Future<GeoPoint?> getDriverLocationForRide(String rideId) async {
    final data = await _client
        .from('driver_status')
        .select('current_location')
        .eq('current_ride_id', rideId)
        .maybeSingle();
    return GeoPoint.parse(data?['current_location']);
  }

  /// Get ride history for user.
  Future<List<Map<String, dynamic>>> getUserRideHistory({int limit = 30}) async {
    final data = await _client
        .from('ride_requests')
        .select('*, profiles!ride_requests_user_id_fkey(full_name)')
        .eq('user_id', _client.auth.currentUser?.id ?? '')
        .order('created_at', ascending: false)
        .limit(limit);
    return List<Map<String, dynamic>>.from(data as List);
  }

  /// Get ride history for driver.
  Future<List<Map<String, dynamic>>> getDriverRideHistory({int limit = 30}) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return [];
    final prov = await _client
        .from('provider_profiles')
        .select('id')
        .eq('user_id', userId)
        .eq('provider_type', 'VEHICLE_PROVIDER')
        .maybeSingle();
    if (prov == null) return [];
    final data = await _client
        .from('ride_requests')
        .select('*, profiles!ride_requests_user_id_fkey(full_name)')
        .eq('claimed_by_provider_id', prov['id'])
        .order('created_at', ascending: false)
        .limit(limit);
    return List<Map<String, dynamic>>.from(data as List);
  }

  /// Submit a rating.
  Future<void> submitRating({
    required String rideId,
    required int rating,
    String? comment,
  }) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) throw Exception('Not authenticated');
    await _client.from('ride_ratings').insert({
      'ride_request_id': rideId,
      'rater_id': userId,
      'rating': rating,
      'comment': comment,
    });
  }

  /// Get provider profile by ID (for driver info display).
  Future<Map<String, dynamic>?> getProviderProfile(String providerId) async {
    final data = await _client
        .from('provider_profiles')
        .select('*, profiles(full_name, phone)')
        .eq('id', providerId)
        .maybeSingle();
    return data;
  }
}
