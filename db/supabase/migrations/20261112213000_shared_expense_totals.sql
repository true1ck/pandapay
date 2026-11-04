-- Exact current accepted totals. Payments affect debt, never consumption.
-- The head-change trigger updates bounded revision members, not journal history.
CREATE TABLE shared_expenses.context_totals (
 context_id uuid PRIMARY KEY REFERENCES shared_expenses.contexts(context_id),
 total_minor bigint NOT NULL DEFAULT 0 CHECK(total_minor BETWEEN 0 AND 9007199254740991),
 expense_count bigint NOT NULL DEFAULT 0 CHECK(expense_count BETWEEN 0 AND 9007199254740991)
);
CREATE TABLE shared_expenses.member_totals (
 context_id uuid NOT NULL,member_id uuid NOT NULL,
 paid_minor bigint NOT NULL DEFAULT 0 CHECK(paid_minor BETWEEN 0 AND 9007199254740991),
 share_minor bigint NOT NULL DEFAULT 0 CHECK(share_minor BETWEEN 0 AND 9007199254740991),
 PRIMARY KEY(context_id,member_id),
 FOREIGN KEY(context_id,member_id) REFERENCES shared_expenses.members(context_id,member_id)
);
ALTER TABLE shared_expenses.context_totals OWNER TO shared_expenses_owner;
ALTER TABLE shared_expenses.member_totals OWNER TO shared_expenses_owner;
ALTER TABLE shared_expenses.context_totals ENABLE ROW LEVEL SECURITY;
ALTER TABLE shared_expenses.context_totals FORCE ROW LEVEL SECURITY;
ALTER TABLE shared_expenses.member_totals ENABLE ROW LEVEL SECURITY;
ALTER TABLE shared_expenses.member_totals FORCE ROW LEVEL SECURITY;
CREATE POLICY shared_totals_owner ON shared_expenses.context_totals TO shared_expenses_owner USING(true) WITH CHECK(true);
CREATE POLICY shared_member_totals_owner ON shared_expenses.member_totals TO shared_expenses_owner USING(true) WITH CHECK(true);
CREATE POLICY shared_totals_read ON shared_expenses.context_totals FOR SELECT TO app_user USING(shared_expenses._can_read_context(context_id));
CREATE POLICY shared_member_totals_read ON shared_expenses.member_totals FOR SELECT TO app_user USING(shared_expenses._can_read_context(context_id));
REVOKE ALL ON shared_expenses.context_totals,shared_expenses.member_totals FROM PUBLIC,app_user;
GRANT SELECT ON shared_expenses.context_totals,shared_expenses.member_totals TO app_user;

CREATE FUNCTION shared_expenses._update_totals() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,shared_expenses,pg_temp AS $$
DECLARE previous_total bigint:=0; next_total bigint:=0; previous_count bigint:=0; next_count bigint:=0; item record;
BEGIN
 IF OLD.accepted_revision_id IS NOT DISTINCT FROM NEW.accepted_revision_id THEN RETURN NEW; END IF;
 SELECT total_minor,CASE WHEN is_void THEN 0 ELSE 1 END INTO previous_total,previous_count FROM shared_expenses.expense_revisions WHERE context_id=OLD.context_id AND revision_id=OLD.accepted_revision_id;
 SELECT total_minor,CASE WHEN is_void THEN 0 ELSE 1 END INTO next_total,next_count FROM shared_expenses.expense_revisions WHERE context_id=NEW.context_id AND revision_id=NEW.accepted_revision_id;
 UPDATE shared_expenses.context_totals SET total_minor=total_minor+coalesce(next_total,0)-coalesce(previous_total,0),expense_count=expense_count+coalesce(next_count,0)-coalesce(previous_count,0) WHERE context_id=NEW.context_id;
 IF NOT FOUND THEN
   INSERT INTO shared_expenses.context_totals(context_id,total_minor,expense_count) VALUES(NEW.context_id,coalesce(next_total,0)-coalesce(previous_total,0),coalesce(next_count,0)-coalesce(previous_count,0));
 END IF;
 FOR item IN SELECT member_id,sum(paid)::bigint AS paid,sum(share)::bigint AS share FROM (
   SELECT member_id,paid_minor AS paid,share_minor AS share FROM shared_expenses.revision_members WHERE context_id=NEW.context_id AND revision_id=NEW.accepted_revision_id
   UNION ALL SELECT member_id,-paid_minor,-share_minor FROM shared_expenses.revision_members WHERE context_id=OLD.context_id AND revision_id=OLD.accepted_revision_id
 ) changes GROUP BY member_id LOOP
   UPDATE shared_expenses.member_totals SET paid_minor=paid_minor+item.paid,share_minor=share_minor+item.share WHERE context_id=NEW.context_id AND member_id=item.member_id;
   IF NOT FOUND THEN
     INSERT INTO shared_expenses.member_totals(context_id,member_id,paid_minor,share_minor) VALUES(NEW.context_id,item.member_id,item.paid,item.share);
   END IF;
 END LOOP;
 RETURN NEW;
END $$;
ALTER FUNCTION shared_expenses._update_totals() OWNER TO shared_expenses_owner;
REVOKE ALL ON FUNCTION shared_expenses._update_totals() FROM PUBLIC,app_user;
CREATE TRIGGER shared_accepted_totals AFTER UPDATE OF accepted_revision_id ON shared_expenses.expenses FOR EACH ROW EXECUTE FUNCTION shared_expenses._update_totals();

-- Additive upgrade backfill: current accepted heads only, no bank/reward writes.
INSERT INTO shared_expenses.context_totals(context_id,total_minor,expense_count)
SELECT e.context_id,sum(r.total_minor)::bigint,count(*) FILTER(WHERE NOT r.is_void) FROM shared_expenses.expenses e
JOIN shared_expenses.expense_revisions r ON r.context_id=e.context_id AND r.revision_id=e.accepted_revision_id GROUP BY e.context_id;
INSERT INTO shared_expenses.member_totals(context_id,member_id,paid_minor,share_minor)
SELECT e.context_id,m.member_id,sum(m.paid_minor)::bigint,sum(m.share_minor)::bigint FROM shared_expenses.expenses e
JOIN shared_expenses.revision_members m ON m.context_id=e.context_id AND m.revision_id=e.accepted_revision_id GROUP BY e.context_id,m.member_id;
