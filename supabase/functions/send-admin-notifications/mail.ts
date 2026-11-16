type Event={id:string;kind:string;source_id:string;created_at:string;payload?:{title?:string;teacher_name?:string}};
export function buildEmail(event:Event,from:string){
 const teacher=event.kind==='program_submission';
 const subject=event.kind==='test'?'[무드웰니스] 관리자 알림 연결 테스트':teacher?'[무드웰니스] 강사 프로그램 승인 요청':'[무드웰니스] 회원 프로그램 개설 신청';
 const lines=event.kind==='test'?['관리자 이메일 알림 연결 테스트입니다.']:teacher?['강사 프로그램의 최종 승인 요청이 접수되었습니다.',`담당 강사: ${event.payload?.teacher_name||'관리자 화면에서 확인'}`,`프로그램: ${event.payload?.title||'관리자 화면에서 확인'}`,'강사 전용 관리 → 프로그램 관리에서 승인 또는 수정 요청을 해 주세요.']:['회원의 새로운 프로그램 개설 신청이 접수되었습니다.','강사 전용 관리 → 개설 신청 확인에서 요청 내용을 확인해 주세요.','회원의 연락처와 상세 요청은 개인정보 보호를 위해 관리자 화면에서만 확인할 수 있습니다.'];
 lines.push(`접수번호: ${event.source_id||event.id}`,`접수 시간: ${new Date(event.created_at).toLocaleString('ko-KR',{timeZone:'Asia/Seoul'})}`,'관리자 화면: https://02younge.github.io/Moodwellness/#home','홈페이지 오른쪽 상단의 강사 전용 관리에서 관리자 계정으로 로그인해 주세요.');
 return{from,to:['moodwellness@kakao.com'],subject,text:lines.join('\n')};
}
