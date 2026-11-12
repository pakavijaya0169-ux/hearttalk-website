-- HeartTalk Commerce & Razorpay test-mode activation
-- Apply AFTER supabase/schema.sql and the existing admin role foundation.
-- This migration never stores provider secrets and never trusts browser-supplied prices/coin amounts.
-- Live payments must remain disabled until Razorpay approval and production secrets are configured.

create table if not exists public.coin_packages (
  package_code text primary key,
  title text not null,
  coins integer not null check (coins > 0),
  amount_paise bigint not null check (amount_paise > 0),
  active boolean not null default true,
  sort_order integer not null default 0
);
insert into public.coin_packages(package_code,title,coins,amount_paise,sort_order) values
 ('starter','Starter',20,900,1),
 ('basic','Basic',40,2500,2),
 ('popular','Popular',250,12500,3),
 ('plus','Plus',500,25000,4),
 ('pro','Pro',1000,50000,5),
 ('value','Value',2000,100000,6),
 ('premium','Premium',5000,250000,7),
 ('ultimate','Ultimate',10000,500000,8),
 ('max','Max',20000,1000000,9)
on conflict(package_code) do update set title=excluded.title,coins=excluded.coins,
 amount_paise=excluded.amount_paise,sort_order=excluded.sort_order;

create table if not exists public.payment_orders (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete restrict,
 package_code text not null references public.coin_packages(package_code),
 coins integer not null check(coins>0),
 amount_paise bigint not null check(amount_paise>0),
 currency text not null default 'INR' check(currency='INR'),
 provider text not null default 'razorpay',
 provider_order_id text not null unique,
 provider_payment_id text unique,
 status text not null default 'created' check(status in ('created','paid','failed','expired')),
 created_at timestamptz not null default now(),
 paid_at timestamptz
);
create index if not exists payment_orders_user_created_idx on public.payment_orders(user_id,created_at desc);
alter table public.payment_orders enable row level security;
revoke all on public.payment_orders from anon,authenticated,public;
grant all on public.payment_orders to service_role;

create table if not exists public.payment_transactions (
 id uuid primary key default gen_random_uuid(),
 user_id uuid references auth.users(id) on delete set null,
 provider text not null,
 provider_transaction_id text not null unique,
 amount_paise bigint not null check(amount_paise>=0),
 currency text not null default 'INR' check(currency='INR'),
 status text not null check(status in ('pending','succeeded','failed','refunded')),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
alter table public.payment_transactions enable row level security;
revoke all on public.payment_transactions from anon,authenticated,public;
grant all on public.payment_transactions to service_role;

create unique index if not exists wallet_purchase_reference_unique_idx
 on public.wallet_ledger(reference_id) where entry_type='purchase' and reference_id is not null;

create table if not exists public.hearttalk_gift_catalog (
 gift_code text primary key, title text not null, emoji text not null,
 coin_price integer not null check(coin_price>0), active boolean not null default true
);
insert into public.hearttalk_gift_catalog(gift_code,title,emoji,coin_price) values
 ('chai','Chai','☕',19),('maggi','Maggi','🍜',19),('congrats','Congrats!','💐',19),
 ('birthday','Happy Birthday!','🎂',29),('cool','I''m So Cool','😎',9),('party','Party Mode!','😂',9),
 ('rose','Rose','🌹',49),('teddy','Teddy Bear','🧸',49),('heart','Heart','❤️',20),
 ('diamond','Diamond','💎',250),('crown','Royal Crown','👑',500),('surprise','Surprise Gift','🎁',100)
on conflict(gift_code) do update set title=excluded.title,emoji=excluded.emoji,coin_price=excluded.coin_price;

create table if not exists public.hearttalk_gift_events (
 id uuid primary key default gen_random_uuid(),
 sender_id uuid not null references auth.users(id) on delete restrict,
 host_id uuid not null references auth.users(id) on delete restrict,
 gift_code text not null references public.hearttalk_gift_catalog(gift_code),
 coin_price integer not null check(coin_price>0),
 host_share_coins integer not null check(host_share_coins>=0),
 platform_share_coins integer not null check(platform_share_coins>=0),
 created_at timestamptz not null default now(),
 check(sender_id<>host_id), check(host_share_coins+platform_share_coins=coin_price)
);
create index if not exists hearttalk_gift_host_created_idx on public.hearttalk_gift_events(host_id,created_at desc);
create index if not exists hearttalk_gift_sender_created_idx on public.hearttalk_gift_events(sender_id,created_at desc);
alter table public.hearttalk_gift_events enable row level security;
revoke all on public.hearttalk_gift_events from anon,authenticated,public;
grant select on public.hearttalk_gift_events to authenticated;
drop policy if exists "Gift participants can view their gifts" on public.hearttalk_gift_events;
create policy "Gift participants can view their gifts" on public.hearttalk_gift_events
 for select to authenticated using(sender_id=auth.uid() or host_id=auth.uid());

create table if not exists public.hearttalk_host_earnings (
 id bigint generated by default as identity primary key,
 host_id uuid not null references auth.users(id) on delete cascade,
 gift_event_id uuid not null unique references public.hearttalk_gift_events(id) on delete restrict,
 earned_coins integer not null check(earned_coins>=0),
 created_at timestamptz not null default now()
);
alter table public.hearttalk_host_earnings enable row level security;
revoke all on public.hearttalk_host_earnings from anon,authenticated,public;
grant select on public.hearttalk_host_earnings to authenticated;
drop policy if exists "Hosts can view own earnings" on public.hearttalk_host_earnings;
create policy "Hosts can view own earnings" on public.hearttalk_host_earnings
 for select to authenticated using(host_id=auth.uid());

create table if not exists public.host_payout_requests (
 id uuid primary key default gen_random_uuid(),
 host_id uuid not null references auth.users(id) on delete restrict,
 requested_coins integer not null check(requested_coins>0),
 status text not null default 'pending' check(status in ('pending','approved','rejected','paid')),
 admin_note text,
 created_at timestamptz not null default now(),
 reviewed_at timestamptz,
 reviewed_by uuid references auth.users(id)
);
alter table public.host_payout_requests enable row level security;
revoke all on public.host_payout_requests from anon,authenticated,public;
grant select on public.host_payout_requests to authenticated;
drop policy if exists "Hosts can view own payout requests" on public.host_payout_requests;
create policy "Hosts can view own payout requests" on public.host_payout_requests
 for select to authenticated using(host_id=auth.uid());

create or replace function public.hearttalk_send_gift(target_host_id uuid, selected_gift_code text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_sender uuid:=auth.uid(); v_price integer; v_host_share integer;
 v_platform_share integer; v_balance bigint; v_event uuid;
begin
 if v_sender is null then raise exception 'Please log in first'; end if;
 if target_host_id is null or target_host_id=v_sender then raise exception 'Choose another member'; end if;
 select coin_price into v_price from public.hearttalk_gift_catalog
  where gift_code=selected_gift_code and active=true;
 if v_price is null then raise exception 'Gift is unavailable'; end if;
 perform 1 from auth.users where id=v_sender for update;
 select coalesce(sum(amount),0) into v_balance from public.wallet_ledger where user_id=v_sender;
 if v_balance<v_price then raise exception 'Not enough coins. Please add coins to your wallet.'; end if;
 v_host_share:=floor(v_price*0.60)::integer;
 v_platform_share:=v_price-v_host_share;
 insert into public.wallet_ledger(user_id,amount,entry_type,reference_id)
  values(v_sender,-v_price,'spend','gift:'||selected_gift_code);
 insert into public.hearttalk_gift_events(sender_id,host_id,gift_code,coin_price,host_share_coins,platform_share_coins)
  values(v_sender,target_host_id,selected_gift_code,v_price,v_host_share,v_platform_share) returning id into v_event;
 insert into public.hearttalk_host_earnings(host_id,gift_event_id,earned_coins)
  values(target_host_id,v_event,v_host_share);
 return jsonb_build_object('gift_event_id',v_event,'coin_price',v_price,
  'host_earned_coins',v_host_share,'platform_share_coins',v_platform_share,'status','recorded');
end; $$;
revoke all on function public.hearttalk_send_gift(uuid,text) from public;
grant execute on function public.hearttalk_send_gift(uuid,text) to authenticated;

create or replace function public.hearttalk_get_host_earnings()
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid(); v_total bigint; v_count bigint; v_recent jsonb;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 select coalesce(sum(earned_coins),0),count(*) into v_total,v_count
  from public.hearttalk_host_earnings where host_id=v_user;
 select coalesce(jsonb_agg(x),'[]'::jsonb) into v_recent from (
  select jsonb_build_object('gift_event_id',e.gift_event_id,'earned_coins',e.earned_coins,
   'created_at',e.created_at,'gift_title',c.title,'emoji',c.emoji) x
  from public.hearttalk_host_earnings e
  join public.hearttalk_gift_events g on g.id=e.gift_event_id
  join public.hearttalk_gift_catalog c on c.gift_code=g.gift_code
  where e.host_id=v_user order by e.created_at desc limit 50
 ) q;
 return jsonb_build_object('earned_coins',v_total,'gift_count',v_count,'history',v_recent,
  'cash_withdrawal_enabled',false);
end; $$;
revoke all on function public.hearttalk_get_host_earnings() from public;
grant execute on function public.hearttalk_get_host_earnings() to authenticated;

-- Called only by trusted Edge Functions after Razorpay signature AND payment capture are verified.
create or replace function public.credit_verified_coin_purchase(
 p_provider_order_id text, p_provider_payment_id text, p_amount_paise bigint, p_currency text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_order public.payment_orders%rowtype;
begin
 if coalesce(current_setting('request.jwt.claim.role',true),'') <> 'service_role' then
  raise exception 'Trusted payment service required';
 end if;
 select * into v_order from public.payment_orders
  where provider_order_id=p_provider_order_id for update;
 if not found then raise exception 'Payment order not found'; end if;
 if v_order.status='paid' and v_order.provider_payment_id=p_provider_payment_id then
  return jsonb_build_object('status','already_credited','coins',v_order.coins);
 end if;
 if v_order.status<>'created' then raise exception 'Payment order is not payable'; end if;
 if v_order.amount_paise<>p_amount_paise or v_order.currency<>p_currency then
  raise exception 'Payment amount or currency mismatch';
 end if;
 insert into public.payment_transactions(user_id,provider,provider_transaction_id,amount_paise,currency,status)
  values(v_order.user_id,'razorpay',p_provider_payment_id,p_amount_paise,p_currency,'succeeded');
 insert into public.wallet_ledger(user_id,amount,entry_type,reference_id)
  values(v_order.user_id,v_order.coins,'purchase','razorpay:'||p_provider_payment_id);
 update public.payment_orders set status='paid',provider_payment_id=p_provider_payment_id,paid_at=now()
  where id=v_order.id;
 return jsonb_build_object('status','credited','coins',v_order.coins);
end; $$;
revoke all on function public.credit_verified_coin_purchase(text,text,bigint,text) from public,anon,authenticated;
grant execute on function public.credit_verified_coin_purchase(text,text,bigint,text) to service_role;

create or replace function public.admin_get_payment_dashboard()
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_result jsonb;
begin
 if auth.uid() is null or not public.is_hearttalk_admin() then
  raise exception 'Admin access required';
 end if;
 select jsonb_build_object(
  'total_revenue_paise',(select coalesce(sum(amount_paise),0) from public.payment_transactions where status='succeeded'),
  'successful_payments',(select count(*) from public.payment_transactions where status='succeeded'),
  'pending_orders',(select count(*) from public.payment_orders where status='created'),
  'coins_sold',(select coalesce(sum(coins),0) from public.payment_orders where status='paid'),
  'host_earned_coins',(select coalesce(sum(earned_coins),0) from public.hearttalk_host_earnings),
  'gift_count',(select count(*) from public.hearttalk_gift_events),
  'recent_payments',coalesce((select jsonb_agg(x) from (
   select jsonb_build_object('payment_id',t.provider_transaction_id,'amount_paise',t.amount_paise,
    'currency',t.currency,'status',t.status,'created_at',t.created_at,
    'email',u.email,'coins',o.coins) x
   from public.payment_transactions t
   left join auth.users u on u.id=t.user_id
   left join public.payment_orders o on o.provider_payment_id=t.provider_transaction_id
   order by t.created_at desc limit 50
  ) q),'[]'::jsonb)
 ) into v_result;
 return v_result;
end; $$;
revoke all on function public.admin_get_payment_dashboard() from public,anon;
grant execute on function public.admin_get_payment_dashboard() to authenticated;
