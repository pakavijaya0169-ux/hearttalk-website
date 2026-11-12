// HeartTalk Razorpay webhook. Configure this URL in Razorpay Dashboard.
// Subscribe to payment.captured. Secret: RAZORPAY_WEBHOOK_SECRET.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const reply=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{"Content-Type":"application/json","Cache-Control":"no-store"}});
const hex=(bytes:ArrayBuffer)=>Array.from(new Uint8Array(bytes)).map(b=>b.toString(16).padStart(2,"0")).join("");
async function hmac(secret:string,message:string){const key=await crypto.subtle.importKey("raw",new TextEncoder().encode(secret),{name:"HMAC",hash:"SHA-256"},false,["sign"]);return hex(await crypto.subtle.sign("HMAC",key,new TextEncoder().encode(message)));}
function safeEqual(a:string,b:string){if(a.length!==b.length)return false;let x=0;for(let i=0;i<a.length;i++)x|=a.charCodeAt(i)^b.charCodeAt(i);return x===0;}
Deno.serve(async(req)=>{
 if(req.method!=="POST")return reply({error:"Method not allowed"},405);
 try{
  const secret=Deno.env.get("RAZORPAY_WEBHOOK_SECRET"),url=Deno.env.get("SUPABASE_URL"),service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if(!secret||!url||!service)return reply({error:"Webhook is not configured"},503);
  const raw=await req.text(),signature=req.headers.get("x-razorpay-signature")||"";
  if(!signature||!safeEqual(await hmac(secret,raw),signature))return reply({error:"Invalid webhook signature"},401);
  const event=JSON.parse(raw);
  if(event.event!=="payment.captured")return reply({status:"ignored"});
  const payment=event.payload?.payment?.entity;
  if(!payment?.order_id||!payment?.id||!Number.isFinite(Number(payment.amount))||payment.currency!=="INR")return reply({error:"Incomplete captured payment event"},400);
  const admin=createClient(url,service,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data,error}=await admin.rpc("credit_verified_coin_purchase",{
   p_provider_order_id:payment.order_id,p_provider_payment_id:payment.id,
   p_amount_paise:Number(payment.amount),p_currency:payment.currency
  });
  if(error){console.error("Webhook wallet credit failed",error);return reply({error:"Payment event could not be applied"},500);}
  return reply({status:data?.status||"processed"});
 }catch(error){console.error("razorpay-webhook:",error);return reply({error:"Webhook processing failed"},500);}
});
