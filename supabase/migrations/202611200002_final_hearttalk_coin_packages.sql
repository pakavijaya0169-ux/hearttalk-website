-- HeartTalk: final approved coin packages (four only).
-- Supersedes the incorrect six-package catalogue migration without deleting historical package rows.
update public.coin_packages set active = false;

insert into public.coin_packages
  (package_code, title, coins, amount_paise, active, sort_order, paid_coins, bonus_coins)
values
  ('welcome', 'Welcome Pack', 25, 2000, true, 1, 20, 5),
  ('popular', 'Popular Pack', 114, 9900, true, 2, 99, 15),
  ('super', 'Super Pack', 359, 29900, true, 3, 299, 60),
  ('mega', 'Mega Pack', 1249, 99900, true, 4, 999, 250)
on conflict (package_code) do update set
  title = excluded.title,
  coins = excluded.coins,
  amount_paise = excluded.amount_paise,
  active = excluded.active,
  sort_order = excluded.sort_order,
  paid_coins = excluded.paid_coins,
  bonus_coins = excluded.bonus_coins;
