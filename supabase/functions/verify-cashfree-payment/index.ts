// HeartTalk: verify Cashfree order status server-side before crediting coins.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, apikey, x-client-info, content-type","Access-Control-Allow-Methods":"POST, OPTIONS"};
const reply=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,"Content-Type":"application/json","Cache-Control":"no-store"}});

Deno.serve(async(req)=>{
  if(req.method==="OPTIONS") return new Response("ok",{headers:cors});
  if(req.method!=="POST") return reply({error:"Method not allowed"},405);

  try {
    const jwt=(req.headers.get("Authorization")||"").replace(/^Bearer\s+/i,"");
    const url=Deno.env.get("SUPABASE_URL");
    const anon=Deno.env.get("SUPABASE_ANON_KEY");
    const service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const clientId=Deno.env.get("CASHFREE_CLIENT_ID");
    const clientSecret=Deno.env.get("CASHFREE_CLIENT_SECRET");
    const env=(Deno.env.get("CASHFREE_ENV")||"sandbox").toLowerCase();

    if(!jwt) return reply({error:"Please sign in first."},401);
    if(!url||!anon||!service||!clientId||!clientSecret||env!=="sandbox")
      return reply({error:"Cashfree verification is not configured."},503);

    const authClient=createClient(url,anon,{auth:{persistSession:false,autoRefreshToken:false}});
    const {data:auth,error:authError}=await authClient.auth.getUser(jwt);
    if(authError||!auth.user) return reply({error:"Your session expired. Please sign in again."},401);

    const body=await req.json().catch(()=>({}));
    const orderId=String(body.order_id||"");
    if(!/^ht_[a-f0-9]{32}$/.test(orderId)) return reply({error:"Invalid Cashfree order ID."},400);

    const admin=createClient(url,service,{auth:{persistSession:false,autoRefreshToken:false}});
    const {data:order,error:orderError}=await admin.from("payment_orders")
      .select("id,user_id,provider,amount_paise,currency,status,coins")
      .eq("provider_order_id",orderId).eq("provider","cashfree").maybeSingle();
    if(orderError||!order||order.user_id!==auth.user.id) return reply({error:"Payment order not found for this account."},404);
    if(order.status==="paid") return reply({status:"already_credited",coins:order.coins});

    const headers={
      "Accept":"application/json",
      "x-api-version":"2025-01-01",
      "x-client-id":clientId,
      "x-client-secret":clientSecret
    };
    const base=env==="production"?"https://api.cashfree.com/pg":"https://sandbox.cashfree.com/pg";
    const orderResponse=await fetch(base+"/orders/"+encodeURIComponent(orderId),{headers});
    const orderData=await orderResponse.json().catch(()=>({}));
    if(!orderResponse.ok){
      console.error("Cashfree order status fetch failed",orderResponse.status,orderData);
      return reply({error:"Could not fetch Cashfree order status."},502);
    }
    if(orderData.order_status!=="PAID"){
      return reply({status:String(orderData.order_status||"PENDING").toLowerCase(),message:"Payment is not confirmed yet. No coins were credited."},200);
    }
    if(Number(Math.round(Number(orderData.order_amount)*100))!==Number(order.amount_paise)||orderData.order_currency!==order.currency){
      return reply({error:"Cashfree order amount or currency mismatch. Coins were not credited."},409);
    }

    const paymentsResponse=await fetch(base+"/orders/"+encodeURIComponent(orderId)+"/payments",{headers});
    const payments=await paymentsResponse.json().catch(()=>[]);
    if(!paymentsResponse.ok||!Array.isArray(payments)){
      console.error("Cashfree payments fetch failed",paymentsResponse.status,payments);
      return reply({error:"Could not verify the Cashfree payment transaction."},502);
    }
    const payment=payments.find((p:any)=>p.payment_status==="SUCCESS"&&
      Number(Math.round(Number(p.payment_amount)*100))===Number(order.amount_paise)&&
      p.payment_currency===order.currency);
    if(!payment?.cf_payment_id) return reply({status:"pending",message:"No successful payment is confirmed yet. No coins were credited."},200);

    const {data:credit,error:creditError}=await admin.rpc("credit_verified_cashfree_coin_purchase",{
      p_provider_order_id:orderId,
      p_provider_payment_id:String(payment.cf_payment_id),
      p_amount_paise:Number(order.amount_paise),
      p_currency:order.currency
    });
    if(creditError){
      console.error("Cashfree wallet credit RPC failed",creditError);
      return reply({error:"Payment was verified, but wallet credit needs server review. Do not pay again; contact HeartTalk support with order ID "+orderId+"."},500);
    }
    return reply({status:credit?.status||"credited",coins:credit?.coins||order.coins});
  } catch(error) {
    console.error("verify-cashfree-payment:",error);
    return reply({error:"Could not verify the Cashfree payment. Please do not pay again until the order status is checked."},500);
  }
});
