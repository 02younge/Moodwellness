alter table public.mw_notifications add column if not exists transport text check(transport in ('smtp','resend'));
-- Keep the old function for migration history but remove API execution.
revoke all on function public.mw_claim_notifications(text,boolean) from service_role;
create or replace function public.mw_claim_notifications(dispatch_key text,configured boolean,mail_transport text)
returns setof public.mw_notifications language plpgsql security definer set search_path='' as $$
begin
 if dispatch_key is null or not exists(select 1 from mw_private.notification_config c where c.dispatch_key=mw_claim_notifications.dispatch_key) then raise exception 'unauthorized'; end if;
 if mail_transport not in ('smtp','resend') then raise exception 'invalid_transport';end if;
 if not configured then
  update public.mw_notifications set last_error='mail_configuration_missing' where status='pending';return;
 end if;
 update public.mw_notifications set status='failed',last_error='smtp_delivery_unknown' where status='sending' and transport='smtp' and lease_until<now();
 update public.mw_notifications set status='failed',last_error='transport_changed_review_required' where status in ('pending','sending') and transport is not null and transport<>mail_transport;
 -- Never blindly resend outside the provider's 24-hour deduplication window.
 update public.mw_notifications set status='failed',last_error='retry_window_expired'
 where status in ('pending','sending') and first_attempt_at<now()-interval '22 hours';
 update public.mw_notifications n set status='cancelled',last_error='request_removed'
 where n.kind='member_request' and n.status in ('pending','sending') and not exists(select 1 from public.mw_requests r where r.id=n.source_id);
 update public.mw_notifications n set status='cancelled',last_error='review_no_longer_pending'
 where n.kind='program_submission' and n.status in ('pending','sending') and not exists(select 1 from public.mw_programs p where p.id=n.source_id and p.approval_status='pending');
 update public.mw_notifications set status='failed',last_error=coalesce(last_error,'attempt_limit') where status in ('pending','sending') and attempts>=5 and (lease_until is null or lease_until<now());
 return query with picked as (
  select n.id from public.mw_notifications n where n.attempts<5 and ((n.status='pending' and n.next_attempt_at<=now()) or (n.status='sending' and n.lease_until<now())) order by n.created_at for update skip locked limit 5
 ) update public.mw_notifications n set status='sending',transport=mail_transport,attempts=n.attempts+1,lease_id=gen_random_uuid(),lease_until=now()+interval '2 minutes',first_attempt_at=coalesce(n.first_attempt_at,now()),last_error=null from picked where n.id=picked.id returning n.*;
end;$$;
revoke all on function public.mw_claim_notifications(text,boolean,text) from public,anon,authenticated;
grant execute on function public.mw_claim_notifications(text,boolean,text) to service_role;

create or replace function public.mw_finish_notification(notification_id uuid,claim_id uuid,delivered boolean,mail_id text default null,failure text default null)
returns boolean language plpgsql security definer set search_path='' as $$
declare row public.mw_notifications;
begin
 update public.mw_notifications n set status=case when delivered then 'sent' when attempts>=5 or failure='smtp_delivery_unknown' then 'failed' else 'pending' end,
 sent_at=case when delivered then now() else null end,provider_id=mail_id,last_error=case when delivered then null else left(failure,160) end,lease_until=null,
 next_attempt_at=now()+make_interval(mins=>power(2,least(attempts,5))::integer)
 where n.id=notification_id and n.status='sending' and n.lease_id=claim_id returning n.* into row;
 if not found then return false;end if;
 if row.kind='member_request' then update public.mw_requests set notification_status=case when delivered then 'sent' when row.status='failed' then 'failed' else 'pending' end where id=row.source_id;end if;
 return true;
end;$$;
revoke all on function public.mw_finish_notification(uuid,uuid,boolean,text,text) from public,anon,authenticated;
grant execute on function public.mw_finish_notification(uuid,uuid,boolean,text,text) to service_role;

