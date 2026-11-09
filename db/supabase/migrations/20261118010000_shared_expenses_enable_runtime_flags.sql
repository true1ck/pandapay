-- Split rollout: the foundation migration ships every capability flag OFF
-- (reads/proposals/accepted_writes/settlements default false). Nothing outside
-- tests and the local rig ever turned them on, so a deployed API answered
-- capabilities with reads=false and the app showed "Shared expenses are not
-- available yet". Turn the runtime on. Idempotent; source_guards stays as is.
UPDATE shared_expenses.settings
   SET reads_enabled = true,
       proposals_enabled = true,
       accepted_writes_enabled = true,
       settlements_enabled = true
 WHERE singleton;
