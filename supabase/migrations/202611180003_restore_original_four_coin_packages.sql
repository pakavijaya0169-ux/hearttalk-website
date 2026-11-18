-- Restore the four original HeartTalk coin packages.
update public.coin_packages set active = false;

insert into public.coin_packages
  (package_code, title, coins, amount_paise, active, sort_order)
values
  ('welcome', 'Welcome Pack', 25, 2000, true, 1),
  ('popular', 'Popular Pack', 114, 9900, true, 2),
  ('super', 'Super Pack', 359, 29900, true, 3),
  ('mega', 'Mega Pack', 1249, 99900, true, 4)
on conflict (package_code) do update set
  title=excluded.title, coins=excluded.coins,
  amount_paise=excluded.amount_paise, active=excluded.active,
  sort_order=excluded.sort_order;
