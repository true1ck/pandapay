# Customer correction update guard

Integrated SQL testing after `setup_app_role.sql` exposed a permission interaction: the generic role reconciliation grants table-level UPDATE after the correction migration's column-only grant. An owner could then set a decision directly despite the private HTTP boundary.

Additive migration 20261112200000 enforces the original retry-only customer update rule in a SECURITY INVOKER trigger. It checks the effective caller, so a trusted security-definer consent revocation still erases shared evidence. Existing owner-isolation/private-role SQL and the real consent ordering tests run after generic role setup, including a repeated role setup pass. No applied migration or generic role policy is edited.
