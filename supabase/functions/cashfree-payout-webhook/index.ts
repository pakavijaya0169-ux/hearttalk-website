// HeartTalk Cashfree Payouts V2 webhook.
// Verifies Cashfree's signed raw body, fetches the authoritative transfer state,
// then applies an idempotent ledger/status transition in Postgres.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const reply=(body:unknown,status=200)=>new Response(JSON.stringify(body),{
  status,headers:{"Content-Type":"application/json","Cache-Control":"no-store"}
});
const enc=new TextEncoder();

async function hmacBase64(message:string,secret:string):Promise<string>{
  const key=await crypto.subtle.importKey("raw",enc.encode(secret),{name:"HMAC",hash:"SHA-256"},false,["sign"]);
  const signed=await crypto.subtle.sign("HMAC",key,enc.encode(message));
  return btoa(String.fromCharCode(...new Uint8Array(signed)));
}
function safeEqual(a:string,b:string):boolean{
  if(a.length!==b.length)return false;
  let mismatch=0;
  for(let i=0;i<a.length;i++)mismatch|=a.charCodeAt(i)^b.charCodeAt(i);
  return mismatch===0;
}
async function sha256Hex(value:string):Promise<string>{
  const digest=await crypto.subtle.digest("SHA-256",enc.encode(value));
  return Array.from(new Uint8Array(digest)).map(x=>x.toString(16).padStart(2,"0")).join("");
}
function amountToPaise(value:unknown):number{
  const match=String(value??"").trim().match(/^(\d{1,12})(?:\.(\d{1,2}))?$/);
  if(!match)return NaN;
  return Number(match[1])*100+Number((match[2]||"").padEnd(2,"0"));
}

Deno.serve(async(req)=>{
  if(req.method!=="POST")return reply({error:"Method not allowed"},405);
  try{
    const raw=await req.text();
    const signature=req.headers.get("x-webhook-signature")||"";
    const timestamp=req.headers.get("x-webhook-timestamp")||"";
    const url=Deno.env.get("SUPABASE_URL");
    const service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const cfId=Deno.env.get("CASHFREE_PAYOUT_CLIENT_ID");
    const cfSecret=Deno.env.get("CASHFREE_PAYOUT_CLIENT_SECRET");
    const env=(Deno.env.get("CASHFREE_PAYOUT_ENV")||"sandbox").toLowerCase();

    if(!url||!service||!cfId||!cfSecret)return reply({error:"Cashfree Payouts credentials are not configured"},503);
    if(env!=="sandbox")return reply({error:"Production payout webhook is disabled; sandbox only"},403);
    if(!/^\d{10,15}$/.test(timestamp)||!signature)return reply({error:"Missing Cashfree webhook signature"},401);
    const expected=await hmacBase64(timestamp+raw,cfSecret);
    if(!safeEqual(expected,signature))return reply({error:"Invalid Cashfree Payouts webhook signature"},401);

    let event:any;
    try{event=JSON.parse(raw);}catch{return reply({error:"Invalid JSON webhook body"},400);}
    const eventType=String(event?.type||"").toUpperCase();
    const supported=new Set(["TRANSFER_ACKNOWLEDGED","TRANSFER_SUCCESS","TRANSFER_FAILED","TRANSFER_REVERSED","TRANSFER_REJECTED"]);
    if(!supported.has(eventType))return reply({status:"ignored",reason:"Unsupported payout event type"},200);

    const data=event?.data||{};
    const transferId=String(data.transfer_id||"");
    const cfTransferId=data.cf_transfer_id?String(data.cf_transfer_id):null;
    if(!/^HTP_[a-f0-9]{32}$/i.test(transferId))return reply({status:"ignored",reason:"Unknown transfer ID format"},200);

    const db=createClient(url,service,{auth:{persistSession:false,autoRefreshToken:false}});
    const {data:request,error:requestError}=await db.from("hearttalk_cashfree_payout_requests")
      .select("id,amount_paise,status,cashfree_reference_id,cashfree_transfer_id")
      .eq("cashfree_reference_id",transferId).maybeSingle();
    if(requestError){console.error("Cashfree payout request lookup failed",requestError);return reply({error:"Could not locate payout request"},500);}
    if(!request)return reply({status:"ignored",reason:"No matching HeartTalk payout request"},200);

    // Always fetch the current transfer state from Cashfree. A webhook is a notification,
    // not the authoritative source for the final payout state.
    const api="https://sandbox.cashfree.com/payout/transfers?transfer_id="+encodeURIComponent(transferId);
    const response=await fetch(api,{method:"GET",headers:{
      "Accept":"application/json","x-api-version":"2024-01-01",
      "x-client-id":cfId,"x-client-secret":cfSecret
    }});
    const provider=await response.json().catch(()=>({}));
    if(!response.ok){console.error("Cashfree transfer status lookup failed",response.status,provider);return reply({error:"Could not verify Cashfree transfer status"},502);}

    const transfer=provider?.data&&typeof provider.data==="object"?provider.data:provider;
    const verifiedTransferId=String(transfer.transfer_id||"");
    const verifiedStatus=String(transfer.status||"").toUpperCase();
    const amountPaise=amountToPaise(transfer.transfer_amount);
    if(verifiedTransferId!==transferId)return reply({error:"Cashfree transfer ID mismatch"},409);
    if(!Number.isSafeInteger(amountPaise)||amountPaise!==Number(request.amount_paise)){
      console.error("Cashfree payout amount mismatch",transferId);
      return reply({error:"Cashfree transfer amount mismatch; manual review required"},409);
    }
    if(cfTransferId&&transfer.cf_transfer_id&&cfTransferId!==String(transfer.cf_transfer_id)){
      return reply({error:"Cashfree transfer reference mismatch"},409);
    }
    if(!["SUCCESS","FAILED","REVERSED","REJECTED","CANCELLED","RECEIVED","PENDING","QUEUED","PROCESSING"].includes(verifiedStatus)){
      return reply({error:"Unrecognized Cashfree transfer status"},502);
    }

    const eventTime=event?.event_time?new Date(event.event_time):null;
    const validEventTime=eventTime&&!Number.isNaN(eventTime.getTime())?eventTime.toISOString():null;
    const eventHash=await sha256Hex(timestamp+raw);
    const failureReason=String(transfer.status_description||transfer.failure_reason||transfer.message||"").slice(0,500);
    const {data:result,error:applyError}=await db.rpc("hearttalk_apply_cashfree_payout_status",{
      p_event_hash:eventHash,
      p_transfer_id:transferId,
      p_cf_transfer_id:transfer.cf_transfer_id?String(transfer.cf_transfer_id):cfTransferId,
      p_provider_status:verifiedStatus,
      p_status_code:transfer.status_code?String(transfer.status_code):null,
      p_amount_paise:amountPaise,
      p_utr:transfer.transfer_utr?String(transfer.transfer_utr):null,
      p_failure_reason:failureReason||null,
      p_event_type:eventType,
      p_event_time:validEventTime
    });
    if(applyError){console.error("Cashfree payout state update failed",applyError);return reply({error:"Payout status could not be updated"},500);}
    return reply({status:"processed",transfer_id:transferId,provider_status:verifiedStatus,result});
  }catch(error){
    console.error("cashfree-payout-webhook:",error);
    return reply({error:"Payout webhook processing failed"},500);
  }
});
