-- Track explicit MCC verification separately from the broader merchant
-- operator lock: admins may lock a display name/category without verifying
-- the merchant's acquiring-bank MCC.
ALTER TABLE merchants
  ADD COLUMN IF NOT EXISTS mcc_operator_verified boolean NOT NULL DEFAULT false;
