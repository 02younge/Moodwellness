
begin;
create table public.mw_promotion_plans(
 program_id uuid primary key references public.mw_programs(id) on delete cascade,
 program_title text not null,
 teacher_name text not null,
 target_audience text not null default '' check(length(target_audience)<=2000),
 own_plan text not null default '' check(length(own_plan)<=2000),
 joint_request text not null default '' check(length(joint_request)<=2000),
 board_copy text not null default '' check(length(board_copy)<=2000),
 content_url text not null default '' check(length(content_url)<=1000 and (content_url='' or content_url ~ '^https://')),
 planned_date date,
 workflow text not null default 'preparing' check(workflow in ('preparing','coordination','ready','posted')),
 use_consent boolean not null default false,
 consent_at timestamptz,
 consent_by uuid references auth.users(id),
 consent_text text,
 updated_at timestamptz not null default now()
);
alter table public.mw_promotion_plans enable row level security;
revoke all on public.mw_promotion_plans from public,anon,authenticated;
grant select,insert,update on public.mw_promotion_plans to authenticated;
grant all on public.mw_promotion_plans to service_role;
create policy mw_promo_read on public.mw_promotion_plans for select to authenticated using(public.mw_is_staff() and exists(select 1 from public.mw_programs p where p.id=program_id and (p.owner_id=auth.uid() or public.mw_is_admin())));
create policy mw_promo_insert on public.mw_promotion_plans for insert to authenticated with check(public.mw_is_staff() and exists(select 1 from public.mw_programs p where p.id=program_id and (p.owner_id=auth.uid() or public.mw_is_admin())));
create policy mw_promo_update on public.mw_promotion_plans for update to authenticated using(public.mw_is_staff() and exists(select 1 from public.mw_programs p where p.id=program_id and (p.owner_id=auth.uid() or public.mw_is_admin()))) with check(public.mw_is_staff() and exists(select 1 from public.mw_programs p where p.id=program_id and (p.owner_id=auth.uid() or public.mw_is_admin())));
create function public.mw_guard_promotion_plan() returns trigger language plpgsql security invoker set search_path='' as $$
declare p public.mw_programs;
begin
 if not public.mw_is_staff() then raise exception '활성 강사 계정이 필요합니다.'; end if;
 select * into p from public.mw_programs where id=new.program_id;
 if p.id is null or (p.owner_id<>auth.uid() and not public.mw_is_admin()) then raise exception '권한이 없습니다.'; end if;
 if tg_op='UPDATE' and new.program_id<>old.program_id then raise exception '프로그램 변경 불가'; end if;
 if not public.mw_is_admin() and new.workflow not in ('preparing','coordination') then raise exception '센터 검토 단계는 관리자만 변경할 수 있습니다.'; end if;
 if new.workflow<>'preparing' and (not new.use_consent or btrim(new.content_url)='' or btrim(new.joint_request)='') then raise exception '자료 링크·강조 문구·활용 동의가 필요합니다.'; end if;
 new.program_title:=p.title; new.teacher_name:=p.teacher_name;new.updated_at:=now();
 if tg_op='UPDATE' and new.use_consent and old.use_consent and
 (new.target_audience,new.own_plan,new.joint_request,new.board_copy,new.content_url) is not distinct from
 (old.target_audience,old.own_plan,old.joint_request,old.board_copy,old.content_url) then
 new.consent_at:=old.consent_at;new.consent_by:=old.consent_by;new.consent_text:=old.consent_text;
 elsif new.use_consent then
  new.consent_at:=now();new.consent_by:=auth.uid();
  new.consent_text:='제출 자료에 필요한 저작권·초상권 등 사용 권한을 확보했습니다. 센터가 프로그램·강사·센터 홍보를 위해 제출한 자료와 문구를 별도 건별 승인 없이 복제·게시·편집·재구성하고 반복 활용하는 데 동의합니다.';
 else new.consent_at:=null;new.consent_by:=null;new.consent_text:=null;
 end if;
 return new;
end;$$;
revoke all on function public.mw_guard_promotion_plan() from public,anon,authenticated;
create trigger mw_guard_promotion_plan before insert or update on public.mw_promotion_plans for each row execute function public.mw_guard_promotion_plan();
CREATE OR REPLACE FUNCTION public.mw_save_program(program jsonb, slots jsonb, program_id uuid DEFAULT NULL::uuid, expected_updated_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  pid uuid := program_id;
  old_updated_at timestamptz;
  slot jsonb;
  new_owner uuid := (program->>'owner_id')::uuid;
begin
  if not public.mw_is_staff() then
    raise exception '활성 강사 계정으로 로그인해 주세요.';
  end if;
  if new_owner <> auth.uid() and not public.mw_is_admin() then
    raise exception '담당 계정을 변경할 권한이 없습니다.';
  end if;
  if jsonb_typeof(slots) <> 'array' or jsonb_array_length(slots) > 30 then
    raise exception '시간표는 최대 30개까지 등록할 수 있습니다.';
  end if;
  if jsonb_typeof(program->'tags') <> 'array'
     or jsonb_array_length(program->'tags') > 5 then
    raise exception '추천 태그는 최대 5개까지 선택해 주세요.';
  end if;
  if exists (
    select 1 from jsonb_array_elements_text(program->'tags') t
    where t not in ('힐링','체형교정','바디라인','근력·체력',
      '유연성·가동성','리듬감','섬세한 집중','교류','에너제틱')
  ) then raise exception '허용되지 않은 추천 태그입니다.'; end if;
  if not exists (
    select 1 from public.mw_staff s
    where s.user_id = new_owner and s.active
  ) then raise exception '활성 강사 계정을 선택해 주세요.'; end if;
  if program->>'category' = 'regular' and
     (program->>'normal_price' is null) then
    raise exception '정규 크루는 회당 정상가를 입력해 주세요.';
  end if;

  if pid is not null then
    select p.updated_at into old_updated_at
    from public.mw_programs p
    where p.id = pid
      and (p.owner_id = auth.uid() or public.mw_is_admin())
    for update;
    if not found then raise exception '수정할 수 없는 프로그램입니다.'; end if;
    if expected_updated_at is null or old_updated_at <> expected_updated_at then
      raise exception '다른 화면에서 수정되었습니다. 목록을 새로고침한 뒤 다시 열어주세요.';
    end if;
    update public.mw_programs p set
      owner_id = new_owner,
      teacher_name = program->>'teacher_name',
      title = program->>'title',
      category = program->>'category',
      description = program->>'description',
      recommended_for = coalesce(program->>'recommended_for',''),
      preparation = coalesce(program->>'preparation',''),
      location = coalesce(program->>'location',''),
      image_url = program->>'image_url',
      inquiry_url = program->>'inquiry_url',
      tags = array(select jsonb_array_elements_text(program->'tags')),
      energy = program->>'energy',
      intensity = program->>'intensity',
      beginner_friendly = (program->>'beginner_friendly')::boolean,
      duration_minutes = (program->>'duration_minutes')::integer,
      capacity = (program->>'capacity')::integer,
      normal_price = case when program->>'category'='private' then null
        else (program->>'normal_price')::integer end,
      status = program->>'status',
      published = (program->>'published')::boolean,
      approval_status = coalesce(program->>'approval_status','draft'),
      review_note = coalesce(program->>'review_note','')
    where p.id = pid;
  else
    insert into public.mw_programs (
      owner_id,teacher_name,title,category,description,recommended_for,
      preparation,location,image_url,inquiry_url,tags,energy,intensity,
      beginner_friendly,duration_minutes,capacity,normal_price,status,published,approval_status,review_note
    ) values (
      new_owner,program->>'teacher_name',program->>'title',
      program->>'category',program->>'description',
      coalesce(program->>'recommended_for',''),coalesce(program->>'preparation',''),
      coalesce(program->>'location',''),program->>'image_url',program->>'inquiry_url',
      array(select jsonb_array_elements_text(program->'tags')),
      program->>'energy',program->>'intensity',
      (program->>'beginner_friendly')::boolean,
      (program->>'duration_minutes')::integer,(program->>'capacity')::integer,
      case when program->>'category'='private' then null
        else (program->>'normal_price')::integer end,
      program->>'status',(program->>'published')::boolean,
      coalesce(program->>'approval_status','draft'),coalesce(program->>'review_note','')
    ) returning id into pid;
  end if;

  -- RLS enforces the current user's ownership on both tables.
  -- A failure here rolls back the entire save.
  delete from public.mw_sessions s where s.program_id = pid;
  for slot in select value from jsonb_array_elements(slots) loop
    insert into public.mw_sessions (
      id,program_id,weekday,start_time,end_time,start_date,end_date,status,note
    ) values (
      (slot->>'id')::uuid,pid,(slot->>'weekday')::smallint,
      (slot->>'start_time')::time,(slot->>'end_time')::time,
      nullif(slot->>'start_date','')::date,nullif(slot->>'end_date','')::date,
      slot->>'status',coalesce(slot->>'note','')
    );
  end loop;

  if program ? 'promotion_plan' then
    if program->>'approval_status'='pending' and
      (btrim(coalesce(program->'promotion_plan'->>'target_audience',''))='' or btrim(coalesce(program->'promotion_plan'->>'own_plan',''))='') then
      raise exception '모집 대상과 본인의 홍보·모집 계획이 필요합니다.';
    end if;
    insert into public.mw_promotion_plans(program_id,program_title,teacher_name,target_audience,own_plan,joint_request,board_copy,content_url,planned_date,workflow,use_consent)
    values(pid,program->>'title',program->>'teacher_name',coalesce(program->'promotion_plan'->>'target_audience',''),coalesce(program->'promotion_plan'->>'own_plan',''),coalesce(program->'promotion_plan'->>'joint_request',''),coalesce(program->'promotion_plan'->>'board_copy',''),coalesce(program->'promotion_plan'->>'content_url',''),nullif(program->'promotion_plan'->>'planned_date','')::date,coalesce(program->'promotion_plan'->>'workflow','preparing'),coalesce((program->'promotion_plan'->>'use_consent')::boolean,false))
    on conflict on constraint mw_promotion_plans_pkey do update set target_audience=excluded.target_audience,own_plan=excluded.own_plan,joint_request=excluded.joint_request,board_copy=excluded.board_copy,content_url=excluded.content_url,planned_date=excluded.planned_date,workflow=excluded.workflow,use_consent=excluded.use_consent;
  end if;

  return pid;
end;
$function$;

commit;