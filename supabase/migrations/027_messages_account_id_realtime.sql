-- ============================================================
-- 027_messages_account_id_realtime.sql
--
-- WHY THIS MIGRATION EXISTS
-- -------------------------
-- Supabase Realtime evaluates each table's RLS policy to decide
-- whether to broadcast a change event to a subscriber. For that
-- evaluation to work reliably, the policy MUST be evaluable on
-- the row alone — without joining to another table.
--
-- The old messages_select policy was:
--
--   EXISTS (
--     SELECT 1 FROM conversations c
--     WHERE  c.id = messages.conversation_id
--     AND    is_account_member(c.account_id)
--   )
--
-- Supabase Realtime does NOT execute sub-selects / JOINs when it
-- checks RLS for broadcast eligibility. Result: the INSERT event
-- for every inbound customer message was silently dropped, so:
--   - "Hi" from a user never appeared in the inbox.
--   - After a broadcast the user's reply was invisible until the
--     agent replied (which triggered a full DB re-fetch).
--   - Within the 24-hour window, customer messages were only
--     visible after the agent sent something back.
--
-- FIX
-- ---
-- 1. Add account_id to messages (same pattern as every other table
--    after migration 017).
-- 2. Backfill from conversations.account_id.
-- 3. Make NOT NULL (no orphan rows should exist).
-- 4. Add a partial index for fast account-scoped message reads.
-- 5. Rewrite the RLS policies to a direct is_account_member(account_id)
--    check — no JOIN, no sub-select, fully Realtime-compatible.
-- 6. Enable Realtime for messages (idempotent — was already done in
--    001 but we re-assert here alongside the policy fix).
--
-- SAFETY
-- ------
-- Idempotent: uses IF NOT EXISTS / ALTER COLUMN ... SET NOT NULL
-- (no-op on already-NOT NULL). Policies are DROP … CREATE.
-- No existing data is deleted or altered beyond the backfill.
-- ============================================================

-- ----------------------------------------------------------------
-- 1. Add account_id column (nullable so backfill can run first)
-- ----------------------------------------------------------------
ALTER TABLE messages
  ADD COLUMN IF NOT EXISTS account_id UUID REFERENCES accounts(id) ON DELETE CASCADE;

-- ----------------------------------------------------------------
-- 2. Backfill — derive from the parent conversation row
-- ----------------------------------------------------------------
UPDATE messages m
SET account_id = c.account_id
FROM conversations c
WHERE c.id = m.conversation_id
  AND m.account_id IS NULL;

-- ----------------------------------------------------------------
-- 3. Enforce NOT NULL now that every row is filled
-- ----------------------------------------------------------------
ALTER TABLE messages ALTER COLUMN account_id SET NOT NULL;

-- ----------------------------------------------------------------
-- 4. Index — every "load messages for account" path benefits
-- ----------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_messages_account ON messages(account_id);

-- ----------------------------------------------------------------
-- 5. RLS — rewrite both policies to direct account_id check
--
-- messages_select : any account member can read (viewer+)
-- messages_modify : agents+ can write (matches conversations policy)
--
-- The old JOIN-based policies are dropped first (017 owns them).
-- ----------------------------------------------------------------
DO $$
DECLARE
  pol RECORD;
BEGIN
  FOR pol IN
    SELECT policyname
    FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'messages'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.messages', pol.policyname);
  END LOOP;
END $$;

CREATE POLICY messages_select ON messages
  FOR SELECT
  USING (is_account_member(account_id));

CREATE POLICY messages_modify ON messages
  FOR ALL
  USING (is_account_member(account_id, 'agent'))
  WITH CHECK (is_account_member(account_id, 'agent'));

-- ----------------------------------------------------------------
-- 6. Ensure messages is in the Realtime publication (idempotent)
-- ----------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'messages'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE messages;
  END IF;
END $$;
