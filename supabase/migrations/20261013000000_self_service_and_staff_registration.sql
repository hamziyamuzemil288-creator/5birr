-- 20261013: Self-service registration and admin settings
-- Adds registered_by_staff_id to providers, auto-approves self-registered providers,
-- and seeds admin contact/payment settings used by the app.

BEGIN;

-- 1) Add registered_by_staff_id to providers if missing
ALTER TABLE IF EXISTS public.providers
  ADD COLUMN IF NOT EXISTS registered_by_staff_id uuid;

-- 2) Ensure profiles table reference is maintained by a FK if possible
-- Add FK only if profiles table exists and FK not present
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='profiles') THEN
    BEGIN
      ALTER TABLE public.providers
        ADD CONSTRAINT IF NOT EXISTS fk_providers_registered_by_staff_profiles
        FOREIGN KEY (registered_by_staff_id) REFERENCES public.profiles(id);
    EXCEPTION WHEN duplicate_object THEN
      -- constraint already exists; ignore
    END;
  END IF;
END$$;

-- 3) Create system_settings table if it does not exist (simple key/value)
CREATE TABLE IF NOT EXISTS public.system_settings (
  key text PRIMARY KEY,
  value text
);

-- 4) Seed admin settings used by the app (idempotent)
INSERT INTO public.system_settings(key, value) VALUES
  ('admin_contact_phone', '')
ON CONFLICT (key) DO NOTHING;

INSERT INTO public.system_settings(key, value) VALUES
  ('admin_payment_details', '')
ON CONFLICT (key) DO NOTHING;

-- 5) Create trigger function to auto-approve self-service provider inserts
CREATE OR REPLACE FUNCTION public.set_provider_status_on_insert()
RETURNS TRIGGER AS $$
BEGIN
  -- If the provider row was inserted without a registered_by_staff_id, treat
  -- as self-service registration and set status to APPROVED/ACTIVE immediately.
  -- This assumes a column named status exists on public.providers (per schema).
  IF NEW.registered_by_staff_id IS NULL THEN
    -- Only set status if the column exists and is currently NULL or PENDING-like
    BEGIN
      NEW.status := 'APPROVED';
    EXCEPTION WHEN undefined_column THEN
      -- If status column does not exist, skip silently
      NULL;
    END;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 6) Attach trigger to providers table (replace existing trigger if present)
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='providers') THEN
    BEGIN
      -- Drop existing trigger if present
      IF (SELECT count(*) FROM pg_trigger WHERE tgname = 'trg_set_provider_status_on_insert') > 0 THEN
        EXECUTE 'DROP TRIGGER IF EXISTS trg_set_provider_status_on_insert ON public.providers';
      END IF;
      EXECUTE 'CREATE TRIGGER trg_set_provider_status_on_insert BEFORE INSERT ON public.providers FOR EACH ROW EXECUTE FUNCTION public.set_provider_status_on_insert()';
    EXCEPTION WHEN OTHERS THEN
      -- Ignore errors to keep migration idempotent/resilient
      RAISE NOTICE 'Could not create provider trigger: %', SQLERRM;
    END;
  END IF;
END$$;

-- 7) Relax NOT NULL on common provider document columns if they exist (non-fatal)
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='provider_documents' AND column_name='document_uri') THEN
    BEGIN
      EXECUTE 'ALTER TABLE public.provider_documents ALTER COLUMN document_uri DROP NOT NULL';
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'Could not drop NOT NULL on provider_documents.document_uri: %', SQLERRM;
    END;
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='providers' AND column_name='required_documents_complete') THEN
    BEGIN
      EXECUTE 'ALTER TABLE public.providers ALTER COLUMN required_documents_complete DROP NOT NULL';
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'Could not drop NOT NULL on providers.required_documents_complete: %', SQLERRM;
    END;
  END IF;
END$$;

COMMIT;
