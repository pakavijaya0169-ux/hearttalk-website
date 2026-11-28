-- Enable Live Room Gifts using the same ₹1 User Wallet Coin / ₹0.50 Host Reward Coin model.

create table if not exists public.hearttalk_live_room_gift_events (
 id uuid primary key default gen_random_uuid(),
 room_id uuid not null references public.live_rooms(id) on delete cascade,
 gift_event_id uuid not null unique references public.hearttalk_gift_events(id) on delete cascade,
 request_id uuid not null,
 sender_id uuid not null references auth.users(id) on delete cascade,
 host_id uuid not null references auth.users(id) on delete cascade,
 sender_name text not null,
 gift_code text not null,
 gift_title text not null,
 emoji text not null,
 coin_price integer not null check(coin_price>0),
 host_earned_coins integer not null check(host_earned_coins>0),
 host_earned_value_paise bigint not null check(host_earned_value_paise>0),
 platform_share_value_paise bigint not null check(platform_share_value_paise>0),
 created_at timestamptz not null default now(),
 constraint hearttalk_live_room_gift_not_self check(sender_id<>host_id),
 constraint hearttalk_live_room_gift_request_unique unique(sender_id,request_id)
);

alter table public.hearttalk_live_room_gift_events enable row level security;
drop policy if exists "Live room members can view live gifts" on public.hearttalk_live_room_gift_events;
create policy "Live room members can view live gifts"
on public.hearttalk_live_room_gift_events
for select to authenticated
using (
 exists(
  select 1 from public.live_room_members m
  where m.room_id=hearttalk_live_room_gift_events.room_id
    and m.user_id=auth.uid()
    and m.left_at is null
 )
);
revoke all on public.hearttalk_live_room_gift_events from anon,public;
grant select on public.hearttalk_live_room_gift_events to authenticated;

do $$
begin
 if exists(select 1 from pg_publication where pubname='supabase_realtime')
  and not exists(
   select 1 from pg_publication_tables
   where pubname='supabase_realtime' and schemaname='public'
     and tablename='hearttalk_live_room_gift_events'
  ) then
  alter publication supabase_realtime add table public.hearttalk_live_room_gift_events;
 end if;
end
$$;

create or replace function public.hearttalk_send_live_room_gift(
 p_room_id uuid,p_gift_code text,p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path=''
as $function$
declare
 v_sender uuid:=auth.uid(); v_host uuid; v_price integer; v_title text; v_emoji text;
 v_balance bigint; v_event uuid; v_live_event uuid; v_sender_name text; v_result jsonb;
 v_cash_paise bigint;
begin
 if v_sender is null then raise exception 'Authentication required'; end if;
 if p_room_id is null or p_gift_code is null or p_request_id is null then
  raise exception 'Live room, gift and request ID are required';
 end if;
 perform 1 from auth.users where id=v_sender for update;
 select result into v_result from public.hearttalk_gift_requests
 where sender_id=v_sender and request_id=p_request_id;
 if v_result is not null then return v_result; end if;

 select r.host_id into v_host from public.live_rooms r
 where r.id=p_room_id and r.status='live' for update;
 if v_host is null then raise exception 'This live room is no longer active'; end if;
 if v_host=v_sender then raise exception 'Hosts cannot send gifts to themselves'; end if;
 if not exists(select 1 from public.live_room_members m
  where m.room_id=p_room_id and m.user_id=v_sender and m.left_at is null) then
  raise exception 'Join the live room before sending a gift';
 end if;
 if not exists(
  select 1 from public.hosts h
  join public.host_applications a on a.user_id=h.user_id and a.status='approved'
  join public.host_kyc_documents d on d.user_id=h.user_id
   and d.status='approved' and d.document_type in ('selfie','video_selfie')
  where h.user_id=v_host and h.host_status='active'
 ) then raise exception 'Live Host verification is not active'; end if;
 if exists(select 1 from public.blocked_users b
  where (b.blocker_id=v_sender and b.blocked_user_id=v_host)
     or (b.blocker_id=v_host and b.blocked_user_id=v_sender)) then
  raise exception 'You cannot gift this Host because the member relationship is blocked';
 end if;

 select c.coin_price,c.title,c.emoji into v_price,v_title,v_emoji
 from public.hearttalk_gift_catalog c where c.gift_code=p_gift_code and c.active=true;
 if v_price is null or v_price<1 then raise exception 'Gift is unavailable'; end if;
 select coalesce(sum(amount),0) into v_balance from public.wallet_ledger where user_id=v_sender;
 if v_balance<v_price then raise exception 'Not enough coins'; end if;

 v_cash_paise:=v_price::bigint*50;
 insert into public.wallet_ledger(user_id,amount,entry_type,reference_id)
 values(v_sender,-v_price,'spend','live_gift:'||p_room_id::text||':'||p_request_id::text);

 insert into public.hearttalk_gift_events(
  sender_id,host_id,gift_code,coin_price,host_share_coins,platform_share_coins,
  host_share_paise,platform_share_paise
 ) values(v_sender,v_host,p_gift_code,v_price,v_price,v_price,v_cash_paise,v_cash_paise)
 returning id into v_event;

 insert into public.hearttalk_host_earnings(host_id,gift_event_id,earned_coins)
 values(v_host,v_event,v_price);
 insert into public.hearttalk_host_cash_ledger(
  host_id,amount_paise,entry_type,reference_id,source_reference,note,created_by
 ) values(v_host,v_cash_paise,'earning_credit',v_event,'gift:'||v_event::text,
  'Live gift Host rewards at ₹0.50 per Host Reward Coin',null)
 on conflict(host_id,source_reference) do nothing;

 select coalesce(nullif(trim(p.display_name),''),nullif(trim(p.username),''),'A HeartTalk member')
 into v_sender_name from public.profiles p where p.id=v_sender;
 if v_sender_name is null then v_sender_name:='A HeartTalk member'; end if;

 insert into public.hearttalk_live_room_gift_events(
  room_id,gift_event_id,request_id,sender_id,host_id,sender_name,
  gift_code,gift_title,emoji,coin_price,host_earned_coins,
  host_earned_value_paise,platform_share_value_paise
 ) values(p_room_id,v_event,p_request_id,v_sender,v_host,v_sender_name,
  p_gift_code,v_title,v_emoji,v_price,v_price,v_cash_paise,v_cash_paise)
 returning id into v_live_event;

 insert into public.notifications(user_id,kind,title,body,data)
 values(v_host,'gift_received','You received a live gift!',
  v_sender_name||' sent you '||coalesce(v_emoji,'🎁')||' '||v_title||' in your live room.',
  jsonb_build_object('gift_event_id',v_event,'live_gift_event_id',v_live_event,
   'room_id',p_room_id,'sender_id',v_sender,'sender_name',v_sender_name,
   'gift_code',p_gift_code,'gift_title',v_title,'gift_emoji',v_emoji,
   'coin_price',v_price,'host_earned_coins',v_price,
   'host_earned_value_paise',v_cash_paise,'platform_share_value_paise',v_cash_paise));

 v_result:=jsonb_build_object('request_id',p_request_id,'gift_event_id',v_event,
  'emoji',v_emoji,'gift_title',v_title,'coin_price',v_price,
  'host_earned_coins',v_price,'host_earned_value_paise',v_cash_paise,
  'platform_share_value_paise',v_cash_paise,'status','delivered');
 insert into public.hearttalk_gift_requests(sender_id,request_id,result)
 values(v_sender,p_request_id,v_result);
 return v_result;
end;
$function$;

revoke all on function public.hearttalk_send_live_room_gift(uuid,text,uuid) from public,anon;
grant execute on function public.hearttalk_send_live_room_gift(uuid,text,uuid) to authenticated;
