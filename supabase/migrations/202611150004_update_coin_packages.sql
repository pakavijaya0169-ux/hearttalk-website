-- HeartTalk: replace the legacy coin package catalogue with four current packages.
-- Existing old package rows are retained (inactive) so prior payment_orders foreign keys remain valid.
update public.coin_packages
set active=false
where package_code not in ('welcome','popular','super','mega');

insert into public.coin_packages(package_code,title,coins,amount_paise,active,sort_order) values
 ('welcome','Welcome',25,2000,true,1),
 ('popular','Popular',114,9900,true,2),
 ('super','Super',359,29900,true,3),
 ('mega','Mega',1249,99900,true,4)
on conflict(package_code) do update set
 title=excluded.title,
 coins=excluded.coins,
 amount_paise=excluded.amount_paise,
 active=true,
 sort_order=excluded.sort_order;
