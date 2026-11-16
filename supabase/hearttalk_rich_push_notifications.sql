-- HeartTalk rich push notification campaigns and image storage
-- Run once in Supabase SQL Editor. This creates the admin campaign queue and
-- private token registry; it does NOT send pushes until the FCM Edge Function is deployed.

create table if not exists public.hearttalk_push_campaigns (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 1 and 120),
  body text not null check (char_length(body) between 1 and 500),
  image_url text,
  audience text not null default 'all'
    check (audience in ('all','active','hosts','selected')),
  scheduled_at timestamptz,
  status text not null default 'draft'
    check (status in ('draft','scheduled','queued','sending','sent','failed','cancelled')),
  delivery_count integer not null default 0 check (delivery_count >= 0),
  failure_count integer not null default 0 check (failure_count >= 0),
  last_error text,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  sent_at timestamptz,
  constraint scheduled_campaign_has_time check (status <> 'scheduled' or scheduled_at is not null)
);

create index if not exists hearttalk_push_campaigns_status_schedule_idx
  on public.hearttalk_push_campaigns(status, scheduled_at);

alter table public.hearttalk_push_campaigns enable row level security;
revoke all on public.hearttalk_push_campaigns from anon, public;
grant select, insert, update on public.hearttalk_push_campaigns to authenticated;

drop policy if exists "HeartTalk admins manage push campaigns" on public.hearttalk_push_campaigns;
create policy "HeartTalk admins manage push campaigns"
on public.hearttalk_push_campaigns
for all to authenticated
using (
  exists (select 1 from public.hearttalk_user_roles r
          where r.user_id = auth.uid() and r.role = 'admin')
)
with check (
  exists (select 1 from public.hearttalk_user_roles r
          where r.user_id = auth.uid() and r.role = 'admin')
);

create table if not exists public.hearttalk_push_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  fcm_token text not null unique,
  platform text not null check (platform in ('web','android','ios')),
  enabled boolean not null default true,
  updated_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index if not exists hearttalk_push_tokens_user_idx
  on public.hearttalk_push_tokens(user_id) where enabled = true;
alter table public.hearttalk_push_tokens enable row level security;
revoke all on public.hearttalk_push_tokens from anon, public;
grant select, insert, update, delete on public.hearttalk_push_tokens to authenticated;

drop policy if exists "Users manage own push tokens" on public.hearttalk_push_tokens;
create policy "Users manage own push tokens"
on public.hearttalk_push_tokens
for all to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

drop policy if exists "Admins view push tokens" on public.hearttalk_push_tokens;
create policy "Admins view push tokens"
on public.hearttalk_push_tokens
for select to authenticated
using (
  exists (select 1 from public.hearttalk_user_roles r
          where r.user_id = auth.uid() and r.role = 'admin')
);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('notification-images','notification-images',true,5242880,
        array['image/jpeg','image/png','image/webp'])
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Admins upload HeartTalk notification images" on storage.objects;
create policy "Admins upload HeartTalk notification images"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'notification-images'
  and exists (select 1 from public.hearttalk_user_roles r
              where r.user_id = auth.uid() and r.role = 'admin')
);

drop policy if exists "Admins update HeartTalk notification images" on storage.objects;
create policy "Admins update HeartTalk notification images"
on storage.objects for update to authenticated
using (
  bucket_id = 'notification-images'
  and exists (select 1 from public.hearttalk_user_roles r
              where r.user_id = auth.uid() and r.role = 'admin')
)
with check (
  bucket_id = 'notification-images'
  and exists (select 1 from public.hearttalk_user_roles r
              where r.user_id = auth.uid() and r.role = 'admin')
);

drop policy if exists "Admins delete HeartTalk notification images" on storage.objects;
create policy "Admins delete HeartTalk notification images"
on storage.objects for delete to authenticated
using (
  bucket_id = 'notification-images'
  and exists (select 1 from public.hearttalk_user_roles r
              where r.user_id = auth.uid() and r.role = 'admin')
);

drop policy if exists "Public can view HeartTalk notification images" on storage.objects;
create policy "Public can view HeartTalk notification images"
on storage.objects for select to public
using (bucket_id = 'notification-images');
