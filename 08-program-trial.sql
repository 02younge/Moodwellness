begin;
alter table public.mw_programs add column trial_status text not null default 'inquiry' check(trial_status in ('available','unavailable','inquiry')), add column trial_note text not null default '' check(length(trial_note)<=1000);
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
      normal_price = (program->>'normal_price')::integer,
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
      (program->>'normal_price')::integer,
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


  if program ? 'image_urls' then
    if jsonb_typeof(program->'image_urls') is distinct from 'array' then raise exception '사진 목록 형식을 확인해 주세요.'; end if;
    if jsonb_array_length(program->'image_urls')>5 then raise exception '프로그램 사진은 최대 5장입니다.'; end if;
    if exists(select 1 from jsonb_array_elements(program->'image_urls') v where jsonb_typeof(v)<>'string' or (v#>>'{}') !~ '^https://' or length(v#>>'{}')>2000) then raise exception '사진 주소를 확인해 주세요.'; end if;
    update public.mw_programs set image_urls=array(select jsonb_array_elements_text(program->'image_urls')),image_url=program->'image_urls'->>0 where id=pid;
  end if;

  if program ? 'trial_status' then
    update public.mw_programs set trial_status=program->>'trial_status',trial_note=coalesce(program->>'trial_note','') where id=pid;
  end if;
  return pid;
end;
$function$
;
commit;