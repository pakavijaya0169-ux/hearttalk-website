-- HeartTalk Admin Commerce Controls. No live payment or payout execution is enabled.
create table if not exists public.hearttalk_admin_offers (
 id uuid primary key default gen_random_uuid(),
 title text not null check(char_length(title) between 1 and 100),
 code text not null unique check(code ~ '^[A-Z0-9_-]{3,30}$'),
 description text not null default '',
 offer_type text not null check(offer_type in ('bonus_coins','discount_percent','announcement')),
 value numeric(12,2) not null default 0 check(value>=0),
 active boolean not null default false,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create table if not exists public.hearttalk_admin_announcements (
 id uuid primary key default gen_random_uuid(),
 title text not null check(char_length(title) between 1 and 120),
 body text not null check(char_length(body) between 1 and 2000),
 audience text not null default 'all' check(audience in ('all','active')),
 status text not null default 'draft' check(status in ('draft','queued')),
 created_at timestamptz not null default now(),
 created_by uuid references auth.users(id)
);
alter table public.hearttalk_admin_offers enable row level security;
alter table public.hearttalk_admin_announcements enable row level security;
revoke all on public.hearttalk_admin_offers,public.hearttalk_admin_announcements from anon,authenticated,public;

create or replace function public.admin_get_commerce_settings()
returns jsonb language plpgsql security definer set search_path='' as $$
declare v jsonb;
begin
 if auth.uid() is null or not public.is_hearttalk_admin() then raise exception 'Admin access required'; end if;
 select jsonb_build_object(
 'packages',coalesce((select jsonb_agg(to_jsonb(p) order by sort_order) from public.coin_packages p),'[]'::jsonb),
 'gifts',coalesce((select jsonb_agg(to_jsonb(g) order by gift_code) from public.hearttalk_gift_catalog g),'[]'::jsonb),
 'offers',coalesce((select jsonb_agg(to_jsonb(o) order by created_at desc) from public.hearttalk_admin_offers o),'[]'::jsonb),
 'announcements',coalesce((select jsonb_agg(to_jsonb(n) order by created_at desc) from public.hearttalk_admin_announcements n),'[]'::jsonb)
 ) into v;
 return v;
end; $$;
revoke all on function public.admin_get_commerce_settings() from public,anon;
grant execute on function public.admin_get_commerce_settings() to authenticated;

create or replace function public.admin_save_coin_package(p_code text,p_title text,p_coins integer,p_amount_paise bigint,p_active boolean)
returns boolean language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not public.is_hearttalk_admin() then raise exception 'Admin access required'; end if;
 if p_title is null or char_length(trim(p_title)) not between 1 and 60 or p_coins is null or p_coins<1 or p_amount_paise is null or p_amount_paise<1 then raise exception 'Invalid package values'; end if;
 update public.coin_packages set title=trim(p_title),coins=p_coins,amount_paise=p_amount_paise,active=p_active where package_code=p_code;
 if not found then raise exception 'Coin package not found'; end if;
 return true;
end; $$;
revoke all on function public.admin_save_coin_package(text,text,integer,bigint,boolean) from public,anon;
grant execute on function public.admin_save_coin_package(text,text,integer,bigint,boolean) to authenticated;

create or replace function public.admin_save_gift(p_code text,p_title text,p_emoji text,p_coin_price integer,p_active boolean)
returns boolean language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not public.is_hearttalk_admin() then raise exception 'Admin access required'; end if;
 if p_title is null or char_length(trim(p_title)) not between 1 and 60 or p_emoji is null or char_length(p_emoji)>12 or p_coin_price is null or p_coin_price<1 then raise exception 'Invalid gift values'; end if;
 update public.hearttalk_gift_catalog set title=trim(p_title),emoji=p_emoji,coin_price=p_coin_price,active=p_active where gift_code=p_code;
 if not found then raise exception 'Gift not found'; end if;
 return true;
end; $$;
revoke all on function public.admin_save_gift(text,text,text,integer,boolean) from public,anon;
grant execute on function public.admin_save_gift(text,text,text,integer,boolean) to authenticated;

create or replace function public.admin_create_offer(p_title text,p_code text,p_description text,p_type text,p_value numeric)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid;
begin
 if auth.uid() is null or not public.is_hearttalk_admin() then raise exception 'Admin access required'; end if;
 if p_title is null or char_length(trim(p_title)) not between 1 and 100 or p_code is null or p_code !~ '^[A-Z0-9_-]{3,30}$' or p_type not in ('bonus_coins','discount_percent','announcement') or p_value is null or p_value<0 or (p_type='discount_percent' and p_value>100) then raise exception 'Invalid offer details'; end if;
 insert into public.hearttalk_admin_offers(title,code,description,offer_type,value)
 values(trim(p_title),p_code,coalesce(p_description,''),p_type,p_value) returning id into v_id;
 return v_id;
end; $$;
revoke all on function public.admin_create_offer(text,text,text,text,numeric) from public,anon;
grant execute on function public.admin_create_offer(text,text,text,text,numeric) to authenticated;

create or replace function public.admin_set_offer_active(p_offer_id uuid,p_active boolean)
returns boolean language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not public.is_hearttalk_admin() then raise exception 'Admin access required'; end if;
 update public.hearttalk_admin_offers set active=p_active,updated_at=now() where id=p_offer_id;
 if not found then raise exception 'Offer not found'; end if;
 return true;
end; $$;
revoke all on function public.admin_set_offer_active(uuid,boolean) from public,anon;
grant execute on function public.admin_set_offer_active(uuid,boolean) to authenticated;

create or replace function public.admin_create_announcement(p_title text,p_body text,p_audience text)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid;
begin
 if auth.uid() is null or not public.is_hearttalk_admin() then raise exception 'Admin access required'; end if;
 if p_title is null or char_length(trim(p_title)) not between 1 and 120 or p_body is null or char_length(trim(p_body)) not between 1 and 2000 or p_audience not in ('all','active') then raise exception 'Invalid announcement'; end if;
 insert into public.hearttalk_admin_announcements(title,body,audience,created_by)
 values(trim(p_title),trim(p_body),p_audience,auth.uid()) returning id into v_id;
 return v_id;
end; $$;
revoke all on function public.admin_create_announcement(text,text,text) from public,anon;
grant execute on function public.admin_create_announcement(text,text,text) to authenticated;
