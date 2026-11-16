-- HeartTalk manual UPI coin recharge.
-- No gateway, provider API, or automatic bank verification is used.
-- Admin must verify the UPI credit in their own bank app before approving a request.

create table if not exists public.hearttalk_manual_upi_recharges (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete restrict,
 package_code text not null references public.coin_packages(package_code),
 package_title text not null,
 amount_paise bigint not null check(amount_paise > 0),
 coins integer not null check(coins > 0),
 utr text not null,
 status text not null default 'pending' check(status in ('pending','approved','rejected')),
 admin_note text not null default '',
 reviewed_by uuid references auth.users(id),
 reviewed_at timestamptz,
 created_at timestamptz not null default now()
);
create unique index if not exists hearttalk_manual_upi_recharges_utr_unique
 on public.hearttalk_manual_upi_recharges (upper(trim(utr)));
create index if not exists hearttalk_manual_upi_recharges_status_idx
 on public.hearttalk_manual_upi_recharges(status,created_at desc);
create index if not exists hearttalk_manual_upi_recharges_user_idx
 on public.hearttalk_manual_upi_recharges(user_id,created_at desc);
alter table public.hearttalk_manual_upi_recharges enable row level security;
revoke all on public.hearttalk_manual_upi_recharges from anon,authenticated,public;
grant select on public.hearttalk_manual_upi_recharges to authenticated;

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
 insert into public.hearttalk_manual_upi_recharges(user_id,package_code,package_title,amount_paise,coins,utr)
 values(v_user,v_package.package_code,v_package.title,v_package.amount_paise,v_package.coins,v_utr)
 returning id into v_id;
 return jsonb_build_object('request_id',v_id,'status','pending','amount_paise',v_package.amount_paise,'coins',v_package.coins);
exception when unique_violation then
 raise exception 'This UTR has already been submitted. Contact support if you believe this is a mistake';
end;
$$;
revoke all on function public.hearttalk_submit_manual_upi_recharge(text,text) from public,anon;
grant execute on function public.hearttalk_submit_manual_upi_recharge(text,text) to authenticated;

create or replace function public.hearttalk_get_my_manual_upi_recharges()
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid(); v_rows jsonb;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at desc),'[]'::jsonb) into v_rows
 from (
  select id,package_title,amount_paise,coins,utr,status,admin_note,created_at
  from public.hearttalk_manual_upi_recharges
  where user_id=v_user order by created_at desc limit 30
 ) q;
 return v_rows;
end;
$$;
revoke all on function public.hearttalk_get_my_manual_upi_recharges() from public,anon;
grant execute on function public.hearttalk_get_my_manual_upi_recharges() to authenticated;

create or replace function public.admin_list_manual_upi_recharges(p_status text default 'pending')
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_rows jsonb;
begin
 if auth.uid() is null or not public.is_hearttalk_admin() then raise exception 'Admin access required'; end if;
 if p_status not in ('all','pending','approved','rejected') then raise exception 'Invalid status filter'; end if;
 select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at desc),'[]'::jsonb) into v_rows
 from (
  select r.id,r.user_id,r.package_code,r.package_title,r.amount_paise,r.coins,r.utr,r.status,r.admin_note,r.created_at,
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

create or replace function public.admin_approve_manual_upi_recharge(p_request_id uuid,p_admin_note text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.hearttalk_manual_upi_recharges%rowtype;
begin
 if auth.uid() is null or not public.is_hearttalk_admin() then raise exception 'Admin access required'; end if;
 select * into v from public.hearttalk_manual_upi_recharges where id=p_request_id for update;
 if not found or v.status<>'pending' then raise exception 'Pending recharge request not found'; end if;
 -- Idempotency guard: each approved request has one unique ledger reference.
 if exists(select 1 from public.wallet_ledger where reference_id='manual-upi:'||v.id::text and entry_type='purchase') then
  raise exception 'This recharge has already been credited';
 end if;
 insert into public.wallet_ledger(user_id,amount,entry_type,reference_id)
 values(v.user_id,v.coins,'purchase','manual-upi:'||v.id::text);
 update public.hearttalk_manual_upi_recharges
 set status='approved',admin_note=coalesce(p_admin_note,''),reviewed_by=auth.uid(),reviewed_at=now()
 where id=v.id;
 return jsonb_build_object('status','approved','coins',v.coins,'user_id',v.user_id);
end;
$$;
revoke all on function public.admin_approve_manual_upi_recharge(uuid,text) from public,anon;
grant execute on function public.admin_approve_manual_upi_recharge(uuid,text) to authenticated;

create or replace function public.admin_reject_manual_upi_recharge(p_request_id uuid,p_admin_note text)
returns boolean language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not public.is_hearttalk_admin() then raise exception 'Admin access required'; end if;
 if p_admin_note is null or char_length(trim(p_admin_note))<3 then raise exception 'Enter a rejection reason'; end if;
 update public.hearttalk_manual_upi_recharges
 set status='rejected',admin_note=trim(p_admin_note),reviewed_by=auth.uid(),reviewed_at=now()
 where id=p_request_id and status='pending';
 if not found then raise exception 'Pending recharge request not found'; end if;
 return true;
end;
$$;
revoke all on function public.admin_reject_manual_upi_recharge(uuid,text) from public,anon;
grant execute on function public.admin_reject_manual_upi_recharge(uuid,text) to authenticated;
