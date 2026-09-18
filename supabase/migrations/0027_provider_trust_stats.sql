-- 5BIRR — Provider trust/quality stats (Feature 2)
-- Migration 0027_provider_trust_stats.sql
-- Applied: 2026-09-18
--
-- Adds a public read-only view aggregating REAL data so provider &
-- vehicle-provider profiles can show a trust section at the top:
--   * average rating + review count      ← reviews (target_type PROVIDER)
--   * completed orders                   ← orders where status='COMPLETED'
--   * completion rate                    ← COMPLETED / (COMPLETED + CANCELLED
--                                          + REJECTED), null when no resolved
--                                          orders yet (rendered as "New")
--   * avg response time (minutes)        ← order placed → provider accepted,
--                                          from order_status_history
--   * member since                       ← provider_profiles.created_at
-- A provider is "verified" when its approval request is APPROVED.
-- Works for BOTH regular and vehicle providers (same provider_profiles row).
--
-- Read-only: views run with the owner's privileges, bypassing RLS — only
-- aggregate, non-sensitive figures are exposed (no contact/location data).

CREATE OR REPLACE VIEW public.provider_trust_stats AS
SELECT
  pp.id                                    AS provider_id,
  pp.created_at                            AS member_since,
  ar.status = 'APPROVED'                   AS is_verified,
  COALESCE(r.avg_rating, 0)                AS avg_rating,
  COALESCE(r.review_count, 0)              AS review_count,
  COALESCE(o.completed_count, 0)           AS completed_count,
  o.completion_rate,
  resp.avg_response_minutes
FROM provider_profiles pp
LEFT JOIN (
  SELECT ar.subject_id AS provider_id, ar.status
  FROM approval_requests ar
  WHERE ar.subject_type = 'PROVIDER'
) ar ON ar.provider_id = pp.id
LEFT JOIN (
  SELECT target_id AS provider_id,
         ROUND(AVG(rating)::numeric, 1) AS avg_rating,
         COUNT(*)                       AS review_count
  FROM reviews
  WHERE target_type = 'PROVIDER'
  GROUP BY target_id
) r ON r.provider_id = pp.id
LEFT JOIN (
  SELECT provider_id,
         COUNT(*) FILTER (WHERE status = 'COMPLETED') AS completed_count,
         CASE
           WHEN COUNT(*) FILTER (WHERE status IN ('COMPLETED','CANCELLED','REJECTED')) > 0
           THEN ROUND(
             100.0 * COUNT(*) FILTER (WHERE status = 'COMPLETED') /
               COUNT(*) FILTER (WHERE status IN ('COMPLETED','CANCELLED','REJECTED'))
           )
           ELSE NULL
         END AS completion_rate
  FROM orders
  GROUP BY provider_id
) o ON o.provider_id = pp.id
LEFT JOIN (
  SELECT o2.provider_id,
         AVG(EXTRACT(EPOCH
             FROM (h2_change.created_at - o2.created_at)) / 60.0) AS avg_response_minutes
  FROM orders o2
  JOIN order_status_history h2_change
    ON h2_change.order_id = o2.id
   AND h2_change.to_status = 'ACCEPTED'
  GROUP BY o2.provider_id
) resp ON resp.provider_id = pp.id;
