-- 5BIRR — Admin Expense Tracking & Notification Broadcasting
-- Migration 0024_admin_expenses_notifications.sql
-- Adds:
--   1. admin_expenses — for logging business expenses
--   2. admin_notification_broadcasts — for tracking broadcast notifications sent by admin
-- RLS: admin-only for expenses, admin-only for broadcasts.

-- =========================================================
-- 1. admin_expenses — Business expense tracking
-- =========================================================
CREATE TABLE IF NOT EXISTS admin_expenses (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  admin_id uuid NOT NULL REFERENCES auth.users(id),
  category TEXT NOT NULL,        -- e.g. 'SALARY', 'MARKETING', 'INFRASTRUCTURE', 'LEGAL', 'OTHER'
  description TEXT NOT NULL,
  amount numeric(12,2) NOT NULL CHECK (amount > 0),
  currency TEXT NOT NULL DEFAULT 'ETB',
  expense_date date NOT NULL DEFAULT CURRENT_DATE,
  receipt_storage_path TEXT,     -- optional receipt upload
  metadata jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_admin_expenses_admin ON admin_expenses(admin_id);
CREATE INDEX IF NOT EXISTS idx_admin_expenses_date ON admin_expenses(expense_date);
CREATE INDEX IF NOT EXISTS idx_admin_expenses_category ON admin_expenses(category);

ALTER TABLE admin_expenses ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN CREATE POLICY admin_expenses_admin_only ON admin_expenses
  FOR ALL USING (is_admin()) WITH CHECK (is_admin());
EXCEPTION WHEN duplicate_object THEN null; END $$;

-- =========================================================
-- 2. admin_notification_broadcasts — Track broadcast notifications
-- =========================================================
CREATE TABLE IF NOT EXISTS admin_notification_broadcasts (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  admin_id uuid NOT NULL REFERENCES auth.users(id),
  title TEXT NOT NULL,
  body TEXT,
  target_type TEXT NOT NULL CHECK (target_type IN ('ALL_USERS', 'ALL_PROVIDERS', 'ALL', 'SPECIFIC_USER')),
  target_user_id uuid REFERENCES auth.users(id),  -- null unless SPECIFIC_USER
  sent_count INT NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_admin_broadcasts_admin ON admin_notification_broadcasts(admin_id);
CREATE INDEX IF NOT EXISTS idx_admin_broadcasts_date ON admin_notification_broadcasts(created_at);

ALTER TABLE admin_notification_broadcasts ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN CREATE POLICY admin_broadcasts_admin_only ON admin_notification_broadcasts
  FOR ALL USING (is_admin()) WITH CHECK (is_admin());
EXCEPTION WHEN duplicate_object THEN null; END $$;
