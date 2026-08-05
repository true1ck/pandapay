-- UA-8 (Chunk 32): GET /merchants/nearby (api/src/index.js) needs to read
-- published merchant locations as a genuinely public/unauthenticated route
-- — same shape as GET /catalogue's card_products_public_read (0015) — but
-- `merchants`/`merchant_locations` (0007) only ever got an admin-only
-- policy (AD-6's console routes are all requireAdmin-gated). Without this,
-- withUserClient(null, ...) — the "no user" pattern every other public
-- route in this codebase uses — returns zero rows against merchants no
-- matter what's actually published, since RLS is forced and there was no
-- non-admin policy to match. Same restriction card_products_public_read
-- (0015) already applies: published-only, or admin (so the console's own
-- admin session keeps seeing everything, unpublished included).
--
-- Scoped narrowly to what AD-6 already treats as public-safe once
-- published: `is_published = true` is the same gate the console's
-- publish/unpublish toggle (AD-6, Chunk 23) already governs — this
-- migration does not change what "published" means, just who can read it
-- without an admin session.

create policy merchants_public_read on merchants
  for select to public
  using (is_published = true or pandapay.is_admin());

create policy merchant_locations_public_read on merchant_locations
  for select to public
  using (
    exists (
      select 1 from merchants m
       where m.id = merchant_locations.merchant_id
         and (m.is_published = true or pandapay.is_admin())
    )
  );
