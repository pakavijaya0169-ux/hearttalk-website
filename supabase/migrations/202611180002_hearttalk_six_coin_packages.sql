-- HeartTalk: replace legacy coin packages with the six approved INR packages.
-- 1 INR = 2 coins. No bonus coins are included in this pricing schedule.
update public.coin_packages set active = false;

insert into public.coin_packages
  (package_code, title, coins, amount_paise, active, sort_order, paid_coins, bonus_coins)
values
  ('coins_10',   'Mini Pack',     20,   1000,   true, 1,   20, 0),
  ('coins_50',   'Starter Pack', 100,   5000,   true, 2,  100, 0),
  ('coins_125',  'Value Pack',   250,  12500,   true, 3,  250, 0),
  ('coins_250',  'Popular Pack', 500,  25000,   true, 4,  500, 0),
  ('coins_500',  'Premium Pack', 1000, 50000,   true, 5, 1000, 0),
  ('coins_1000', 'Ultimate Pack',2000,100000,   true, 6, 2000, 0)
on conflict (package_code) do update set
  title = excluded.title,
  coins = excluded.coins,
  amount_paise = excluded.amount_paise,
  active = excluded.active,
  sort_order = excluded.sort_order,
  paid_coins = excluded.paid_coins,
  bonus_coins = excluded.bonus_coins;
