// HeartTalk: verify Razorpay checkout signature AND fetch captured payment server-side.
// Secrets: RAZORPAY_KEY_ID, RAZORPAY_KEY_SECRET, SUPABASE_URL,
// SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, apikey, x-client-info, content-type","Access-Control-Allow-Methods":"POST, OPTIONS"};
const reply=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,"Content-Type":"application/json","Cache-Control":"no-store"}});
const hex=(bytes:ArrayBuffer)=>Array.from(new Uint8Array(bytes)).map(b=>b.toString(16).padStart(2,"0")).join("");
async function hmac(secret:string,message:string){const key=await crypto.subtle.importKey("raw",new TextEncoder().encode(secret),{name:"HMAC",hash:"SHA-256"},false,["sign"]);return hex(await crypto.subtle.sign("HMAC",key,new TextEncoder().encode(message)));}
function safeEqual(a:string,b:string){if(a.length!==b.length)return false;let x=0;for(let i=0;i<a.length;i++)x|=a.charCodeAt(i)^b.charCodeAt(i);return x===0;}
Deno.serve(async(req)=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
 if(req.method!=="POST")return reply({error:"Method not allowed"},405);
 try{
  const jwt=(req.headers.get("Authorization")||"").replace(/^Bearer\s+/i,"");
  const url=Deno.env.get("SUPABASE_URL"),anon=Deno.env.get("SUPABASE_ANON_KEY"),service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const keyId=Deno.env.get("RAZORPAY_KEY_ID"),secret=Deno.env.get("RAZORPAY_KEY_SECRET");
  if(!jwt)return reply({error:"Please sign in first."},401);
  if(!url||!anon||!service||!keyId||!secret)return reply({error:"Payment verification service is not configured."},503);
  const authClient=createClient(url,anon,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data:auth,error:authError}=await authClient.auth.getUser(jwt);
  if(authError||!auth.user)return reply({error:"Your session expired. Please sign in again."},401);
  const body=await req.json().catch(()=>({}));
  const orderId=String(body.razorpay_order_id||""),paymentId=String(body.razorpay_payment_id||""),signature=String(body.razorpay_signature||"");
  if(!orderId||!paymentId||!signature)return reply({error:"Missing Razorpay payment verification fields."},400);
  const expected=await hmac(secret,orderId+"|"+paymentId);
  if(!safeEqual(expected,signature))return reply({error:"Payment signature verification failed. Coins were not credited."},400);
  const admin=createClient(url,service,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data:order,error:orderError}=await admin.from("payment_orders").select("user_id,amount_paise,currency,status,coins").eq("provider_order_id",orderId).maybeSingle();
  if(orderError||!order||order.user_id!==auth.user.id)return reply({error:"Payment order not found for this account."},404);
  if(order.status==="paid")return reply({status:"already_credited",coins:order.coins});
  const paymentResponse=await fetch("https://api.razorpay.com/v1/payments/"+encodeURIComponent(paymentId),{
   headers:{"Authorization":"Basic "+btoa(keyId+":"+secret)}
  });
  const payment=await paymentResponse.json().catch(()=>({}));
  if(!paymentResponse.ok||payment.order_id!==orderId||payment.status!=="captured"||
     Number(payment.amount)!==Number(order.amount_paise)||payment.currency!==order.currency){
   return reply({error:"Razorpay payment is not captured or its amount does not match. Coins were not credited."},409);
  }
  const {data:credit,error:creditError}=await admin.rpc("credit_verified_coin_purchase",{
   p_provider_order_id:orderId,p_provider_payment_id:paymentId,
   p_amount_paise:Number(payment.amount),p_currency:payment.currency
  });
  if(creditError){console.error("Wallet credit RPC failed",creditError);return reply({error:"Payment was verified, but wallet credit needs server review. Do not pay again; contact support with payment ID "+paymentId+"."},500);}
  return reply({status:credit?.status||"credited",coins:credit?.coins||order.coins});
 }catch(error){console.error("verify-razorpay-payment:",error);return reply({error:"Could not verify the payment. Please do not retry payment until transaction status is checked."},500);}
});
