-- QR verification agent support (Task 4). Purely additive columns on
-- user_documents: existing rows keep working (NULL verdict = pre-agent
-- behavior, i.e. plain manual review).

ALTER TABLE public.user_documents
  ADD COLUMN IF NOT EXISTS verification_status text
    DEFAULT 'MANUAL_REVIEW'
    CHECK (verification_status IN ('MANUAL_REVIEW','AUTO_APPROVED','SUSPECTED_FRAUD')),
  ADD COLUMN IF NOT EXISTS qr_payload text,
  ADD COLUMN IF NOT EXISTS agent_verdict jsonb,
  ADD COLUMN IF NOT EXISTS verified_at timestamptz;

-- Duplicate-QR detection: same payload reused across accounts.
CREATE INDEX IF NOT EXISTS idx_user_documents_qr_payload
  ON public.user_documents (qr_payload)
  WHERE qr_payload IS NOT NULL;

-- Quick access to the fraud queue for admins.
CREATE INDEX IF NOT EXISTS idx_user_documents_verification
  ON public.user_documents (verification_status)
  WHERE verification_status <> 'MANUAL_REVIEW';
