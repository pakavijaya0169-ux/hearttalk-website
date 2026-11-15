-- Public read-only feed for active promotional banners. No wallet credit or discount is applied here.
create or replace function public.get_active_hearttalk_offers()
returns table(id uuid,title text,description text,offer_type text,value numeric)
language sql stable security definer set search_path=''
as $$
 select o.id,o.title,o.description,o.offer_type,o.value
 from public.hearttalk_admin_offers o
 where o.active=true
 order by o.created_at desc
 limit 5;
$$;
revoke all on function public.get_active_hearttalk_offers() from public;
grant execute on function public.get_active_hearttalk_offers() to anon,authenticated;
