-- Instant expenses (the Splitwise model), behind a switch that ships OFF.
--
-- Until now every expense revision had to be approved by every person in it
-- before it counted, so one idle friend could hold a whole group's balances
-- (and its exits) hostage. With settings.instant_expenses on, a revision no
-- longer requires anyone's approval: the existing acceptance step finds nothing
-- to wait for and accepts it in the same call, so balances move at once. Any
-- member can then edit or remove it with a new revision (which is also instant),
-- and the full revision history stays, so nothing is lost or rewritable.
--
-- The switch is global and OFF by default, so deploying this migration changes
-- nothing. Turn it on (and back off) without a deploy:
--   UPDATE shared_expenses.settings SET instant_expenses=true WHERE singleton;
-- It only affects revisions created AFTER it is switched: a revision that was
-- already waiting for approval keeps waiting.
ALTER TABLE shared_expenses.settings ADD COLUMN instant_expenses boolean NOT NULL DEFAULT false;

CREATE FUNCTION shared_expenses._instant_expense_approval() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$ BEGIN
 IF NEW.approval_required AND EXISTS(SELECT FROM shared_expenses.settings WHERE singleton AND instant_expenses) THEN
  NEW.approval_required:=false;
 END IF;
 RETURN NEW;
END $$;
ALTER FUNCTION shared_expenses._instant_expense_approval() OWNER TO shared_expenses_owner;
REVOKE ALL ON FUNCTION shared_expenses._instant_expense_approval() FROM PUBLIC,app_user;

-- INSERT only: revision_members rows are immutable afterwards (see _immutable).
CREATE TRIGGER shared_instant_expense_approval BEFORE INSERT ON shared_expenses.revision_members
FOR EACH ROW EXECUTE FUNCTION shared_expenses._instant_expense_approval();
