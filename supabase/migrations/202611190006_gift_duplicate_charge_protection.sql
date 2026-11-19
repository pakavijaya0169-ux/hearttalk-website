-- Prevent duplicate gift charges when the same client request is retried.
create table if not exists public.hearttalk_gift_requests (
 sender_id uuid not null references auth.users(id) on delete cascade,
 request_id uuid not null,
 result jsonb not null,
 created_at timestamptz not null default now(),
 primary key(sender_id,request_id)
);
alter table public.hearttalk_gift_requests enable row level security;
revoke all on public.hearttalk_gift_requests from public,anon,authenticated;

drop function if exists public.hearttalk_send_gift(uuid,text);

create or replace function public.hearttalk_send_gift(
 target_host_id uuid,
 selected_gift_code text,
 p_request_id uuid
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 v_sender uuid:=auth.uid(); v_price integer; v_host_share integer;
 v_platform_share integer; v_balance bigint; v_event uuid; v_result jsonb;
begin
 if v_sender is null then raise exception 'Please log in first'; end if;
 if p_request_id is null then raise exception 'Gift request ID is required'; end if;
 if target_host_id is null or target_host_id=v_sender then raise exception 'Choose another member'; end if;

 perform 1 from auth.users where id=v_sender for update;

 select result into v_result from public.hearttalk_gift_requests
 where sender_id=v_sender and request_id=p_request_id;
 if v_result is not null then return v_result; end if;

 select coin_price into v_price from public.hearttalk_gift_catalog
 where gift_code=selected_gift_code and active=true;
 if v_price is null then raise exception 'Gift is unavailable'; end if;
 select coalesce(sum(amount),0) into v_balance from public.wallet_ledger where user_id=v_sender;
 if v_balance<v_price then raise exception 'Not enough coins. Please add coins to your wallet.'; end if;

 v_host_share:=floor(v_price*0.50)::integer;
 v_platform_share:=v_price-v_host_share;
 insert into public.wallet_ledger(user_id,amount,entry_type,reference_id)
 values(v_sender,-v_price,'spend','gift:'||selected_gift_code);
 insert into public.hearttalk_gift_events(sender_id,host_id,gift_code,coin_price,host_share_coins,platform_share_coins)
 values(v_sender,target_host_id,selected_gift_code,v_price,v_host_share,v_platform_share) returning id into v_event;
 insert into public.hearttalk_host_earnings(host_id,gift_event_id,earned_coins)
 values(target_host_id,v_event,v_host_share);

 v_result:=jsonb_build_object('gift_event_id',v_event,'coin_price',v_price,
  'host_earned_coins',v_host_share,'platform_share_coins',v_platform_share,'status','recorded');
 insert into public.hearttalk_gift_requests(sender_id,request_id,result)
 values(v_sender,p_request_id,v_result);
 return v_result;
end; $$;
revoke all on function public.hearttalk_send_gift(uuid,text,uuid) from public;
grant execute on function public.hearttalk_send_gift(uuid,text,uuid) to authenticated;
