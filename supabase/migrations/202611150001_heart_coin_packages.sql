-- HeartTalk paid + bonus coin package catalogue.
-- Paid coins determine the rupee split; bonus coins are promotional and do not create host earnings.
alter table public.coin_packages
  add column if not exists bonus_coins integer not null default 0
  check (bonus_coins >= 0);

insert into public.coin_packages
  (package_code,title,coins,bonus_coins,amount_paise,sort_order,active)
values
  ('starter','Starter Pack',10,5,1000,1,true),
  ('mini','Mini Pack',50,5,5000,2,true),
  ('popular','Popular Pack',125,15,12500,3,true),
  ('value','Value Pack',250,35,25000,4,true),
  ('super_saver','Super Saver',500,75,50000,5,true),
  ('vip','VIP Pack',1000,200,100000,6,true)
on conflict (package_code) do update set
  title=excluded.title,
  coins=excluded.coins,
  bonus_coins=excluded.bonus_coins,
  amount_paise=excluded.amount_paise,
  sort_order=excluded.sort_order,
  active=excluded.active;

create or replace function public.admin_save_coin_package(
  p_code text,
  p_title text,
  p_coins integer,
  p_bonus_coins integer,
  p_amount_paise bigint,
  p_active boolean
)
returns boolean
language plpgsql
security definer
set search_path=''
as $$
begin
  if auth.uid() is null or not public.is_hearttalk_admin() then
    raise exception 'Admin access required';
  end if;
  if p_code is null or p_title is null
     or char_length(trim(p_title)) not between 1 and 60
     or p_coins is null or p_coins < 1
     or p_bonus_coins is null or p_bonus_coins < 0
     or p_amount_paise is null or p_amount_paise < 1 then
    raise exception 'Invalid package values';
  end if;

  update public.coin_packages
  set title=trim(p_title),
      coins=p_coins,
      bonus_coins=p_bonus_coins,
      amount_paise=p_amount_paise,
      active=p_active
  where package_code=p_code;

  if not found then
    raise exception 'Coin package not found';
  end if;
  return true;
end;
$$;

revoke all on function public.admin_save_coin_package(text,text,integer,integer,bigint,boolean) from public,anon;
grant execute on function public.admin_save_coin_package(text,text,integer,integer,bigint,boolean) to authenticated;
