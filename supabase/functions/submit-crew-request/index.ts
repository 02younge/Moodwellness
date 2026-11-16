import { createClient } from 'npm:@supabase/supabase-js@2.95.3';

const ORIGIN = 'https://02younge.github.io';
const cors = {
  'Access-Control-Allow-Origin': ORIGIN,
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Vary': 'Origin',
};
const response = (status: number, data: unknown) => new Response(JSON.stringify(data), {
  status, headers: {...cors,'Content-Type':'application/json; charset=utf-8'},
});

Deno.serve(async (req: Request) => {
  if (req.headers.get('origin') !== ORIGIN) return response(403,{error:'허용되지 않은 요청입니다.'});
  if (req.method==='OPTIONS') return new Response(null,{status:204,headers:cors});
  if (req.method!=='POST') return response(405,{error:'POST 요청만 가능합니다.'});
  // This endpoint accepts anonymous website submissions, not staff operations.
  // Validate the public application key here because JWT verification is off.
  const appKey='sb_publishable_n7kO1KIYQGuGoH4RZ6E0Ww_FRQZpEqW';
  if(req.headers.get('apikey')!==appKey)
    return response(401,{error:'홈페이지에서 다시 신청해 주세요.'});
  const length=Number(req.headers.get('content-length')||0);
  if(length>16000) return response(413,{error:'신청 내용이 너무 깁니다.'});
  const url=Deno.env.get('SUPABASE_URL');
  const serverKey=Deno.env.get('MW_BACKEND_KEY')||Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if(!url||!serverKey) return response(503,{error:'신청 접수 설정이 아직 완료되지 않았습니다.'});
  let body;
  try {
    // Bound the streamed body even when Content-Length is not provided.
    const reader=req.body?.getReader();
    if(!reader) throw new Error('empty');
    const parts:Uint8Array[]=[];let bytes=0;
    while(true){const {value,done}=await reader.read();if(done)break;bytes+=value.length;
      if(bytes>16000){await reader.cancel();return response(413,{error:'신청 내용이 너무 깁니다.'});}
      parts.push(value);}
    const all=new Uint8Array(bytes);let offset=0;
    for(const part of parts){all.set(part,offset);offset+=part.length;}
    body=JSON.parse(new TextDecoder().decode(all));
    if(body.website) return response(400,{error:'신청 항목을 확인해 주세요.'});
    if(!/^[0-9a-f-]{36}$/i.test(body.submission_id||'') || !body.consent)
      return response(400,{error:'신청 항목과 동의를 확인해 주세요.'});
  } catch {return response(400,{error:'신청 내용을 확인해 주세요.'});}
  try {
    const ip=req.headers.get('x-forwarded-for')?.split(',')[0]?.trim()||'unknown';
    const hash=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(serverKey+':'+ip));
    const fingerprint=Array.from(new Uint8Array(hash),b=>b.toString(16).padStart(2,'0')).join('');
    const db=createClient(url,serverKey,{auth:{persistSession:false,autoRefreshToken:false}});
    const {data:id,error}=await db.rpc('mw_submit_request',{payload:body,fingerprint});
    if(error) return response(error.message.includes('잠시')?429:400,{error:'신청 항목을 확인하거나 잠시 후 다시 신청해 주세요.'});
    const {data:record,error:readError}=await db.from('mw_requests').select('*').eq('id',id).single();
    if(readError) return response(200,{saved:true,notified:false});
    return response(200,{saved:true,notified:record.notification_status==='sent',notification_status:record.notification_status});
  } catch {return response(503,{error:'접수를 확인하지 못했습니다. 잠시 후 다시 시도해 주세요.'});}
});
