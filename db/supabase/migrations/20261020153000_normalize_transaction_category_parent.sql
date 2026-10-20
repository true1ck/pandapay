-- Keep the public reward/reporting category aligned with a private child.
-- A user subcategory is the detail label; category_id remains the published
-- parent when the child belongs to a published category. For a child of a
-- private top-level category there is no public FK, so category_id is null.
create or replace function pandapay.validate_transaction_user_category()
returns trigger language plpgsql security definer
set search_path = public, pandapay
as $$
declare
  private_parent_category uuid;
  private_parent_user_category uuid;
begin
  if new.user_category_id is null then
    return new;
  end if;

  select parent_category_id, parent_user_category_id
    into private_parent_category, private_parent_user_category
    from user_categories
   where id = new.user_category_id
     and profile_id = new.profile_id;

  if not found then
    raise exception 'user category does not belong to transaction profile';
  end if;

  if private_parent_category is not null then
    new.category_id := private_parent_category;
  elsif private_parent_user_category is not null then
    new.category_id := null;
  end if;

  return new;
end $$;

drop trigger if exists trg_transactions_user_category on transactions;
create trigger trg_transactions_user_category
  before insert or update of category_id, user_category_id, profile_id on transactions
  for each row execute function pandapay.validate_transaction_user_category();
