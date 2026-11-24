-- HeartTalk final coin catalogue: replace every prior package with these seven only.
alter table public.coin_packages
  add column if not exists base_coins integer,
  add column if not exists bonus_coins integer;

update public.coin_packages set active=false;

insert into public.coin_packages
  (package_code,title,coins,base_coins,bonus_coins,amount_paise,sort_order,active)
values
  ('trial','Trial Pack',25,20,5,2000,1,true),
  ('mini','Mini Pack',50,40,10,4000,2,true),
  ('basic','Basic Pack',120,100,20,10000,3,true),
  ('value','Value Pack',170,150,20,15000,4,true),
  ('plus','Plus Pack',225,200,25,20000,5,true),
  ('pro','Pro Pack',530,500,30,50000,6,true),
  ('ultra','Ultra Pack',1050,1000,50,100000,7,true)
on conflict (package_code) do update set
  title=excluded.title,
  coins=excluded.coins,
  base_coins=excluded.base_coins,
  bonus_coins=excluded.bonus_coins,
  amount_paise=excluded.amount_paise,
  sort_order=excluded.sort_order,
  active=true;

grant select on table public.coin_packages to anon, authenticated;
