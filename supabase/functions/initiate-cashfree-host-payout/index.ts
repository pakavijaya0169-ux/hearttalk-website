// HeartTalk: initiate an approved host payout through Cashfree Payouts Transfers V2.
// Requires separate Cashfree Payouts API credentials; never expose them to the browser.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, apikey, x-client-info, content-type","Access-Control-Allow-Methods":"POST, OPTIONS"};
const reply=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,"Content-Type":"application/json","Cache-Control":"no-store"}});
const cleanName=(s:string)=>s.replace(/[^A-Za-z\s]/g," ").trim().replace(/\s+/g," ").slice(0,100);

Deno.serve(async(req)=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
 if(req.method!=="POST")return reply({error:"Method not allowed"},405);
 try{
  const jwt=(req.headers.get("Authorization")||"").replace(/^Bearer\s+/i,"");
  const supabaseUrl=Deno.env.get("SUPABASE_URL"),anon=Deno.env.get("SUPABASE_ANON_KEY"),service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const cfId=Deno.env.get("CASHFREE_PAYOUT_CLIENT_ID"),cfSecret=Deno.env.get("CASHFREE_PAYOUT_CLIENT_SECRET");
  // HeartTalk payout testing is sandbox-only until the user explicitly authorizes production payouts.
  const env=(Deno.env.get("CASHFREE_PAYOUT_ENV")||"sandbox").toLowerCase();
  if(!jwt)return reply({error:"Authentication required"},401);
  if(!supabaseUrl||!anon||!service||!cfId||!cfSecret)return reply({error:"Cashfree Payouts credentials not configured"},503);
  if(env!=="sandbox")return reply({error:"Production payouts are disabled. Configure Cashfree sandbox to continue testing."},403);
  const auth=createClient(supabaseUrl,anon,{global:{headers:{Authorization:`Bearer ${jwt}`}},auth:{persistSession:false,autoRefreshToken:false}});
  const {data:userData,error:userError}=await auth.auth.getUser(jwt);
  if(userError||!userData.user)return reply({error:"Session expired"},401);
  const {data:canManageWithdrawals,error:permissionError}=await auth.rpc("has_hearttalk_admin_permission",{p_permission:"withdrawals.manage"});
  if(permissionError||canManageWithdrawals!==true)return reply({error:"Withdrawal management permission required"},403);
  const body=await req.json().catch(()=>({}));
  const requestId=String(body.request_id||"");
  if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(requestId))return reply({error:"Invalid payout request id"},400);

  const db=createClient(supabaseUrl,service,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data:request,error:readError}=await db.from("hearttalk_cashfree_payout_requests").select("*").eq("id",requestId).maybeSingle();
  if(readError||!request)return reply({error:"Payout request not found"},404);
  if(request.status==="processing"||request.status==="paid")return reply({status:request.status,transfer_id:request.cashfree_reference_id||null,cf_transfer_id:request.cashfree_transfer_id||null,already_initiated:true});
  if(request.status!=="approved")return reply({error:"Only approved requests can be sent to Cashfree"},409);

  // Stable provider transfer ID derived from the request ID; never create a fresh transfer on retry.
  const transferId="HTP_"+request.id.replace(/-/g,"").slice(0,32);
  const {data:claimed,error:claimError}=await db.from("hearttalk_cashfree_payout_requests")
   .update({status:"processing",cashfree_reference_id:transferId,cashfree_status:"INITIATING",updated_at:new Date().toISOString()})
   .eq("id",requestId).eq("status","approved").select("id").maybeSingle();
  if(claimError||!claimed)return reply({error:"Request was already claimed or changed. Check payout status before retry."},409);

  const base="https://sandbox.cashfree.com/payout";
  const payload:any={transfer_id:transferId,transfer_amount:Number(request.amount_paise)/100,transfer_currency:"INR",transfer_mode:request.payout_method==="upi"?"upi":"imps",beneficiary_details:{beneficiary_name:cleanName(request.account_holder_name),beneficiary_instrument_details:request.payout_method==="upi"?{vpa:request.upi_id}:{bank_account_number:request.bank_account_number,bank_ifsc:request.bank_ifsc}}};
  let response:Response;
  try{
   response=await fetch(base+"/transfers",{method:"POST",headers:{"Content-Type":"application/json","Accept":"application/json","x-api-version":"2024-01-01","x-client-id":cfId,"x-client-secret":cfSecret},body:JSON.stringify(payload)});
  }catch(fetchError){
   // Network outcome is ambiguous. Keep processing/reserved; do not auto-retry a transfer.
   console.error("Cashfree payout network outcome is unknown",fetchError);
   await db.from("hearttalk_cashfree_payout_requests").update({cashfree_status:"UNKNOWN_RESPONSE",updated_at:new Date().toISOString()}).eq("id",requestId);
   return reply({status:"processing",message:"Cashfree response is uncertain. Request stays reserved; verify transfer status before retrying.",transfer_id:transferId},202);
  }
  const provider=await response.json().catch(()=>({}));
  if(!response.ok){
   // A definitive API rejection; Step 3 will handle verified failure/release semantics.
   console.error("Cashfree payout API rejected request",response.status,provider);
   await db.from("hearttalk_cashfree_payout_requests").update({cashfree_status:String(provider.status||provider.message||"API_REJECTED").slice(0,100),failure_reason:"Cashfree API rejected payout initiation.",updated_at:new Date().toISOString()}).eq("id",requestId);
   return reply({status:"processing",message:"Cashfree rejected/needs review. Reserved funds remain locked until verified status handling.",transfer_id:transferId},502);
  }
  const cfTransferId=provider.cf_transfer_id?String(provider.cf_transfer_id):null;
  const providerStatus=String(provider.status||"RECEIVED").slice(0,100);
  const {error:updateError}=await db.from("hearttalk_cashfree_payout_requests").update({cashfree_transfer_id:cfTransferId,cashfree_status:providerStatus,updated_at:new Date().toISOString()}).eq("id",requestId).eq("status","processing");
  if(updateError){console.error("Could not store Cashfree payout response",updateError);return reply({status:"processing",message:"Cashfree transfer response received; database update needs review.",transfer_id:transferId},202);}
  return reply({status:"processing",transfer_id:transferId,cf_transfer_id:cfTransferId,cashfree_status:providerStatus,message:"Transfer submitted to Cashfree. Final status is not confirmed until provider verification/webhook."},202);
 }catch(error){console.error("initiate-cashfree-host-payout:",error);return reply({error:"Unable to initiate payout"},500);}
});
