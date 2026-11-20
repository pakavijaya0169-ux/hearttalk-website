-- Persist Live room gifts and credit Hosts using the existing 50/50 gift ledger.
create table if not exists public.hearttalk_live_room_gift_events (
 id uuid primary key default gen_random_uuid(),
 room_id uuid not null references public.live_rooms(id) on delete cascade,
 sender_id uuid not null references auth.users(id) on delete restrict,
 host_id uuid not null references auth.users(id) on delete restrict,
 request_id uuid not null,
 gift_code text not null references public.hearttalk_gift_catalog(gift_code),
 gift_title text not null,
 emoji text not null,
 coin_price integer not null check(coin_price>0),
 created_at timestamptz not null default now(),
 unique(sender_id,request_id)
);
create index if not exists hearttalk_live_gifts_room_created_idx on public.hearttalk_live_room_gift_events(room_id,created_at desc);
alter table public.hearttalk_live_room_gift_events enable row level security;
revoke all on public.hearttalk_live_room_gift_events from public,anon,authenticated;
grant select on public.hearttalk_live_room_gift_events to authenticated;
drop policy if exists "Active live room participants view gifts" on public.hearttalk_live_room_gift_events;
create policy "Active live room participants view gifts" on public.hearttalk_live_room_gift_events for select to authenticated
using(exists(select 1 from public.live_room_members m where m.room_id=hearttalk_live_room_gift_events.room_id and m.user_id=auth.uid() and m.left_at is null));

create or replace function public.hearttalk_send_live_room_gift(p_room_id uuid,p_gift_code text,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid();v_host uuid;v_title text;v_emoji text;v_price integer;v_balance bigint;v_event uuid;v_result jsonb;v_room_status text;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 if p_request_id is null or p_room_id is null then raise exception 'Gift request is incomplete'; end if;
 perform 1 from auth.users where id=v_user for update;
 select result into v_result from public.hearttalk_gift_requests where sender_id=v_user and request_id=p_request_id;
 if v_result is not null then return v_result; end if;
 select host_id,status into v_host,v_room_status from public.live_rooms where id=p_room_id for update;
 if v_host is null or v_room_status<>'live' then raise exception 'Live room is no longer active'; end if;
 if v_host=v_user then raise exception 'Hosts cannot gift themselves'; end if;
 if not exists(select 1 from public.live_room_members where room_id=p_room_id and user_id=v_user and left_at is null) then raise exception 'Join the Live room before sending gifts'; end if;
 if not exists(select 1 from public.live_room_members where room_id=p_room_id and user_id=v_host and left_at is null) then raise exception 'Host is not currently in the Live room'; end if;
 select title,emoji,coin_price into v_title,v_emoji,v_price from public.hearttalk_gift_catalog where gift_code=p_gift_code and active=true;
 if v_price is null then raise exception 'Gift is unavailable'; end if;
 select coalesce(sum(amount),0) into v_balance from public.wallet_ledger where user_id=v_user;
 if v_balance<v_price then raise exception 'Not enough coins. Please recharge your wallet.'; end if;
 insert into public.wallet_ledger(user_id,amount,entry_type,reference_id) values(v_user,-v_price,'spend','live_gift:'||p_request_id::text);
 insert into public.hearttalk_gift_events(sender_id,host_id,gift_code,coin_price,host_share_coins,platform_share_coins) values(v_user,v_host,p_gift_code,v_price,floor(v_price*0.50)::integer,v_price-floor(v_price*0.50)::integer) returning id into v_event;
 insert into public.hearttalk_host_earnings(host_id,gift_event_id,earned_coins) values(v_host,v_event,floor(v_price*0.50)::integer);
 insert into public.hearttalk_live_room_gift_events(room_id,sender_id,host_id,request_id,gift_code,gift_title,emoji,coin_price) values(p_room_id,v_user,v_host,p_request_id,p_gift_code,v_title,v_emoji,v_price);
 v_result:=jsonb_build_object('gift_event_id',v_event,'gift_title',v_title,'emoji',v_emoji,'coin_price',v_price,'host_earned_coins',floor(v_price*0.50)::integer,'status','recorded');
 insert into public.hearttalk_gift_requests(sender_id,request_id,result) values(v_user,p_request_id,v_result);
 return v_result;
end;$$;
revoke all on function public.hearttalk_send_live_room_gift(uuid,text,uuid) from public,anon;
grant execute on function public.hearttalk_send_live_room_gift(uuid,text,uuid) to authenticated;

do $$begin
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='hearttalk_live_room_gift_events') then
  alter publication supabase_realtime add table public.hearttalk_live_room_gift_events;
 end if;
end$$;
