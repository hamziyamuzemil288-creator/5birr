-- 0041_ride_requests_realtime.sql
--
-- Realtime publication configuration fix (2026-09-21).
--
-- Symptom: opening an active ride crashed with RealtimeSubscribeException —
--   "Unable to subscribe to changes... Please check Realtime is enabled for
--    the given connect parameters: table: ride_requests".
-- Cause: supabase_flutter's `.from('ride_requests').stream(primaryKey: ['id'])`
--   delivers data through the supabase_realtime publication, and no migration
--   had ever added ride_requests to it. The only table ever added was
--   order_messages (0036), so every ride stream was dead on arrival.
--
-- Dart-side realtime consumers of ride_requests (all were broken):
--   - RideService.watchRide (lib/core/services/ride_service.dart:112)
--       * lib/features/user/user_active_ride_screen.dart:54  (the reported crash)
--       * lib/features/vehicle/driver_trip_screen.dart:49
--   - RideService.watchRideRequests (lib/core/services/ride_service.dart:121)
--       * lib/features/vehicle/driver_ride_requests_screen.dart:49
--   - RideRepository.watchOpenRideRequests (lib/features/vehicle/ride_repository.dart:12)
--
-- Checked and deliberately NOT added (pure DB-config fix, per request):
--   * driver_status — no screen streams it. The driver pushes GPS via the
--     update_driver_location RPC (writes driver_status.current_location) and
--     the rider receives it through the ride_requests row's driver_status
--     embed, refreshed on ride row events. If a future screen streams
--     driver_status directly, add it to the publication in a follow-up.
--   * notifications — watchNotifications/watchUnreadCount exist in
--     lib/core/repositories/notification_repository.dart but currently have
--     no callers. Add here too if they are ever wired up.
--
-- RLS already governs who can read ride_requests rows (riders see their own,
-- drivers their claimed rides), and realtime postgis_changes/pg_changes
-- authorization applies the same policies per subscriber — so no policy
-- changes are needed. No Dart code is modified by this migration.
--
-- Idempotent: safe to re-run (same guard pattern as 0036).

do $$
begin
  begin
    alter publication supabase_realtime add table ride_requests;
  exception
    when duplicate_object then null; -- already in the publication
    when undefined_object then null; -- publication not present on this project
  end;
end $$;
