-- Allow public and signed-in users to read the active HeartTalk coin catalogue.
-- Package rows contain only public prices and coin amounts; payment creation remains service-role only.
alter table public.coin_packages enable row level security;

drop policy if exists "Anyone can read active HeartTalk coin packages"
  on public.coin_packages;

create policy "Anyone can read active HeartTalk coin packages"
  on public.coin_packages
  for select
  to anon, authenticated
  using (active = true);

grant select on table public.coin_packages to anon, authenticated;
