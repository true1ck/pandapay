-- Learning loop B3: what the admin decided about an AI draft, and why. A
-- rejection teaches the next prompt (past mistakes) and withdraws the private
-- rule from the sender's phone.
ALTER TABLE public.sms_v2_unknown_templates
  ADD COLUMN admin_decision text CHECK (admin_decision IN ('approved', 'rejected')),
  ADD COLUMN admin_reason text,
  ADD COLUMN admin_note text CHECK (length(admin_note) <= 300),
  ADD COLUMN decided_by uuid,
  ADD COLUMN decided_at timestamptz;
