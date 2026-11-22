const form = document.querySelector('#instructor-application');
const status = document.querySelector('#application-status');
const db = window.supabase?.createClient(
  'https://hmdlrjzgzefuylfljdlc.supabase.co',
  'sb_publishable_n7kO1KIYQGuGoH4RZ6E0Ww_FRQZpEqW'
);
form.graduate.onchange = () => {
  document.querySelector('#education-label').textContent = form.graduate.value === 'yes'
    ? '수료 과정과 기수 또는 수료 시기'
    : '관련 교육·자격과 지도 경험';
};
form.onsubmit = async event => {
  event.preventDefault();
  if (!db) {
    status.textContent = '연결을 불러오지 못했습니다. 페이지를 새로고침해 주세요.';
    return;
  }
  const button = form.querySelector('button');
  button.disabled = true;
  status.textContent = '지원서를 접수하고 있습니다.';
  try {
    const data = Object.fromEntries(new FormData(form));
    for (const name of ['name','email','background','specialty','proposal','availability','website']) {
      data[name] = data[name].trim();
    }
    const { error } = await db.from('mw_instructor_applications').insert({
      ...data, graduate: data.graduate === 'yes', consent: true
    });
    if (error) throw error;
    form.hidden = true;
    status.textContent = '지원서를 접수했습니다. 검토 후 작성하신 이메일로 연락드리겠습니다.';
    status.focus();
  } catch {
    status.textContent = '지원서를 저장하지 못했습니다. 입력 내용을 확인하고 다시 시도해 주세요.';
  } finally {
    button.disabled = false;
  }
};
