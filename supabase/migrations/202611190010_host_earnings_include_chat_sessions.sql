-- Add chat-session earnings to the existing Host earnings summary.
-- Existing gift earnings and all historical data remain untouched.
create or replace function public.hearttalk_get_host_earnings()
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 v_user uuid:=auth.uid(); v_total bigint; v_count bigint; v_recent jsonb;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 select coalesce((select sum(earned_coins) from public.hearttalk_host_earnings where host_id=v_user),0)
      +coalesce((select sum(earned_coins) from public.hearttalk_chat_session_earnings where host_id=v_user),0),
      (select count(*) from public.hearttalk_host_earnings where host_id=v_user)
      +(select count(*) from public.hearttalk_chat_session_earnings where host_id=v_user)
 into v_total,v_count;
 select coalesce(jsonb_agg(item),'[]'::jsonb) into v_recent from (
  select item from (
   select jsonb_build_object('gift_event_id',e.gift_event_id,'earned_coins',e.earned_coins,
    'created_at',e.created_at,'gift_title',c.title,'emoji',c.emoji) as item,e.created_at as sort_at
   from public.hearttalk_host_earnings e
   join public.hearttalk_gift_events g on g.id=e.gift_event_id
   join public.hearttalk_gift_catalog c on c.gift_code=g.gift_code
   where e.host_id=v_user
   union all
   select jsonb_build_object('gift_event_id',null,'earned_coins',ce.earned_coins,
    'created_at',ce.created_at,'gift_title','Chat earnings','emoji','💬') as item,ce.created_at as sort_at
   from public.hearttalk_chat_session_earnings ce where ce.host_id=v_user
  ) combined order by sort_at desc limit 50
 ) q;
 return jsonb_build_object('earned_coins',v_total,'gift_count',v_count,'history',v_recent,'cash_withdrawal_enabled',false);
end; $$;
revoke all on function public.hearttalk_get_host_earnings() from public;
grant execute on function public.hearttalk_get_host_earnings() to authenticated;
