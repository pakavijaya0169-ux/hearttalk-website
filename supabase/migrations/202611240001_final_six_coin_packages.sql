-- HeartTalk final six coin packages. Prices are INR; coins include the +5 bonus.
update public.coin_packages set active=false;

insert into public.coin_packages(package_code,title,coins,amount_paise,sort_order,active) values
 ('trial','Trial Pack',25,2000,1,true),
 ('mini','Mini Pack',55,5000,2,true),
 ('basic','Basic Pack',105,10000,3,true),
 ('value','Value Pack',205,20000,4,true),
 ('plus','Plus Pack',505,50000,5,true),
 ('pro','Pro Pack',1005,100000,6,true)
on conflict (package_code) do update set
 title=excluded.title,
 coins=excluded.coins,
 amount_paise=excluded.amount_paise,
 sort_order=excluded.sort_order,
 active=true;

grant select on table public.coin_packages to anon, authenticated;
