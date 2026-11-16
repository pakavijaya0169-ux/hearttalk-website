-- HeartTalk: restore the four agreed coin packages.
-- Existing recharge requests keep their package snapshots; legacy catalogue entries are deactivated, not deleted.
alter table public.coin_packages
  add column if not exists paid_coins integer not null default 0 check (paid_coins >= 0),
  add column if not exists bonus_coins integer not null default 0 check (bonus_coins >= 0);

alter table public.hearttalk_manual_upi_recharges
  add column if not exists paid_coins integer not null default 0,
  add column if not exists bonus_coins integer not null default 0;

update public.coin_packages set active=false;

insert into public.coin_packages(package_code,title,coins,amount_paise,active,sort_order,paid_coins,bonus_coins)
values
 ('welcome','Welcome Pack',25,2000,true,1,20,5),
 ('popular','Popular Pack',114,9900,true,2,99,15),
 ('super','Super Pack',359,29900,true,3,299,60),
 ('mega','Mega Pack',1249,99900,true,4,999,250)
on conflict(package_code) do update set
 title=excluded.title,
 coins=excluded.coins,
 amount_paise=excluded.amount_paise,
 active=true,
 sort_order=excluded.sort_order,
 paid_coins=excluded.paid_coins,
 bonus_coins=excluded.bonus_coins;

create or replace function public.hearttalk_submit_manual_upi_recharge(p_package_code text,p_utr text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 v_user uuid:=auth.uid();
 v_package public.coin_packages%rowtype;
 v_id uuid;
 v_utr text:=upper(trim(coalesce(p_utr,'')));
begin
 if v_user is null then raise exception 'Please log in first'; end if;
 if p_package_code is null or char_length(trim(p_package_code)) not between 2 and 40 then raise exception 'Select a valid coin package'; end if;
 if v_utr !~ '^[A-Z0-9]{8,30}$' then raise exception 'Enter the UTR / reference number shown in your UPI app'; end if;
 select * into v_package from public.coin_packages
  where package_code=trim(p_package_code) and active=true;
 if not found then raise exception 'This coin package is unavailable'; end if;
 insert into public.hearttalk_manual_upi_recharges(user_id,package_code,package_title,amount_paise,coins,paid_coins,bonus_coins,utr)
 values(v_user,v_package.package_code,v_package.title,v_package.amount_paise,v_package.coins,v_package.paid_coins,v_package.bonus_coins,v_utr)
 returning id into v_id;
 return jsonb_build_object('request_id',v_id,'status','pending','amount_paise',v_package.amount_paise,
  'coins',v_package.coins,'paid_coins',v_package.paid_coins,'bonus_coins',v_package.bonus_coins);
exception when unique_violation then
 raise exception 'This UTR has already been submitted. Contact support if you believe this is a mistake';
end;
$$;
revoke all on function public.hearttalk_submit_manual_upi_recharge(text,text) from public,anon;
grant execute on function public.hearttalk_submit_manual_upi_recharge(text,text) to authenticated;

create or replace function public.admin_list_manual_upi_recharges(p_status text default 'pending')
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_rows jsonb;
begin
 if auth.uid() is null or not public.is_hearttalk_admin() then raise exception 'Admin access required'; end if;
 if p_status not in ('all','pending','approved','rejected') then raise exception 'Invalid status filter'; end if;
 select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at desc),'[]'::jsonb) into v_rows
 from (
  select r.id,r.user_id,r.package_code,r.package_title,r.amount_paise,r.coins,
   r.paid_coins,r.bonus_coins,r.utr,r.status,r.admin_note,r.created_at,
   coalesce(p.display_name,u.raw_user_meta_data->>'display_name',u.email,'HeartTalk User') as user_name,
   u.email
  from public.hearttalk_manual_upi_recharges r
  left join auth.users u on u.id=r.user_id
  left join public.profiles p on p.id=r.user_id
  where p_status='all' or r.status=p_status
  order by r.created_at desc limit 500
 ) q;
 return v_rows;
end;
$$;
revoke all on function public.admin_list_manual_upi_recharges(text) from public,anon;
grant execute on function public.admin_list_manual_upi_recharges(text) to authenticated;
