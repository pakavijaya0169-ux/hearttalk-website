// HeartTalk Cashfree payment webhook: verify signature, then independently verify order/payment with Cashfree.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const reply=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{"Content-Type":"application/json","Cache-Control":"no-store"}});
const enc=new TextEncoder();
async function verifySignature(rawBody:string,timestamp:string,signature:string,secret:string){
  const key=await crypto.subtle.importKey("raw",enc.encode(secret),{name:"HMAC",hash:"SHA-256"},false,["sign"]);
  const signed=await crypto.subtle.sign("HMAC",key,enc.encode(timestamp+rawBody));
  const expected=btoa(String.fromCharCode(...new Uint8Array(signed)));
  if(expected.length!==signature.length)return false;
  let mismatch=0;for(let i=0;i<expected.length;i++)mismatch|=expected.charCodeAt(i)^signature.charCodeAt(i);
  return mismatch===0;
}
Deno.serve(async(req)=>{
  if(req.method==="OPTIONS")return new Response("ok");
  if(req.method!=="POST")return reply({error:"Method not allowed"},405);
  try{
    const raw=await req.text();
    const signature=req.headers.get("x-webhook-signature")||"";
    const timestamp=req.headers.get("x-webhook-timestamp")||"";
    const secret=Deno.env.get("CASHFREE_CLIENT_SECRET")||"";
    const url=Deno.env.get("SUPABASE_URL"),service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const clientId=Deno.env.get("CASHFREE_CLIENT_ID"),clientSecret=Deno.env.get("CASHFREE_CLIENT_SECRET");
    const env=(Deno.env.get("CASHFREE_ENV")||"sandbox").toLowerCase();
    if(!url||!service||!clientId||!clientSecret||!(env==="sandbox"||env==="production"))return reply({error:"Cashfree API secrets or environment are not configured"},503);
    if(!secret)return reply({error:"Webhook signing secret is not configured"},503);
    if(!/^\d{10,15}$/.test(timestamp)||!signature||!(await verifySignature(raw,timestamp,signature,secret)))return reply({error:"Invalid Cashfree webhook signature"},401);
    const event=JSON.parse(raw);
    const orderId=String(event?.data?.order?.order_id||event?.data?.order_id||event?.order_id||"");
    if(!/^ht_[a-f0-9]{32}$/.test(orderId))return reply({error:"Invalid order identifier"},400);
    const admin=createClient(url,service,{auth:{persistSession:false,autoRefreshToken:false}});
    const {data:order,error:orderError}=await admin.from("payment_orders").select("user_id,provider,amount_paise,currency,coins,status").eq("provider_order_id",orderId).eq("provider","cashfree").maybeSingle();
    if(orderError||!order)return reply({error:"Order not found"},404);
    if(order.status==="paid")return reply({status:"already_credited",coins:order.coins});
    const apiBase=env==="production"?"https://api.cashfree.com/pg":"https://sandbox.cashfree.com/pg";
    const headers={"Accept":"application/json","x-api-version":"2025-01-01","x-client-id":clientId,"x-client-secret":clientSecret};
    const orderRes=await fetch(apiBase+"/orders/"+encodeURIComponent(orderId),{headers});
    const orderData=await orderRes.json().catch(()=>({}));
    if(!orderRes.ok||orderData.order_status!=="PAID"||Number(Math.round(Number(orderData.order_amount)*100))!==Number(order.amount_paise)||orderData.order_currency!==order.currency)return reply({error:"Cashfree order not verified"},409);
    const payRes=await fetch(apiBase+"/orders/"+encodeURIComponent(orderId)+"/payments",{headers});
    const payments=await payRes.json().catch(()=>[]);
    if(!payRes.ok||!Array.isArray(payments))return reply({error:"Could not verify payments"},502);
    const payment=payments.find((p:any)=>p.payment_status==="SUCCESS"&&p.cf_payment_id&&Number(Math.round(Number(p.payment_amount)*100))===Number(order.amount_paise)&&p.payment_currency===order.currency);
    if(!payment)return reply({status:"pending"},200);
    const {data:credit,error:creditError}=await admin.rpc("credit_verified_cashfree_coin_purchase",{p_provider_order_id:orderId,p_provider_payment_id:String(payment.cf_payment_id),p_amount_paise:Number(order.amount_paise),p_currency:order.currency});
    if(creditError){console.error("Webhook credit error",creditError);return reply({error:"Verified payment requires review"},500);}
    return reply({status:credit?.status||"credited",coins:credit?.coins||order.coins});
  }catch(e){console.error("cashfree-webhook",e);return reply({error:"Webhook processing failed"},500);}
});
