import { createClient } from 'npm:@supabase/supabase-js@2.95.3';
import { buildEmail } from './mail.ts';
const json=(status:number,data:unknown)=>new Response(JSON.stringify(data),{status,headers:{'Content-Type':'application/json'}});
Deno.serve(async(req:Request)=>{
 if(req.method!=='POST')return json(405,{error:'method_not_allowed'});
 const dispatchKey=req.headers.get('x-mw-dispatch');if(!dispatchKey||dispatchKey.length>200)return json(401,{error:'unauthorized'});
 const url=Deno.env.get('SUPABASE_URL');
 let serverKey=Deno.env.get('MW_BACKEND_KEY')||Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
 if(!serverKey){try{serverKey=Object.values(JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS')||'{}'))[0] as string;}catch{}}
 if(!url||!serverKey)return json(503,{error:'server_configuration_missing'});
 const db=createClient(url,serverKey,{auth:{persistSession:false,autoRefreshToken:false}});
 const mailKey=Deno.env.get('RESEND_API_KEY'),from=Deno.env.get('MAIL_FROM');
 const {data:rows,error}=await db.rpc('mw_claim_notifications',{dispatch_key:dispatchKey,configured:!!(mailKey&&from)});
 if(error)return json(error.message.includes('unauthorized')?401:503,{error:'dispatch_unavailable'});
 if(!mailKey||!from)return json(503,{error:'mail_configuration_missing'});
 let sent=0,failed=0;
 for(const event of rows||[]){
  let delivered=false,providerId=null,failure='network_error';
  try{
   const email=buildEmail(event,from);
   const res=await fetch('https://api.resend.com/emails',{method:'POST',signal:AbortSignal.timeout(8000),headers:{Authorization:'Bearer '+mailKey,'Content-Type':'application/json','Idempotency-Key':'mw-admin/'+event.id},body:JSON.stringify(email)});
   const result=await res.json().catch(()=>({}));delivered=res.ok&&typeof result.id==='string';providerId=delivered?result.id:null;failure='provider_http_'+res.status;
  }catch{}
  const finish=await db.rpc('mw_finish_notification',{notification_id:event.id,claim_id:event.lease_id,delivered,mail_id:providerId,failure:delivered?null:failure});
  if(delivered&&!finish.error)sent++;else failed++;
 }
 return json(200,{processed:(rows||[]).length,sent,failed});
});
