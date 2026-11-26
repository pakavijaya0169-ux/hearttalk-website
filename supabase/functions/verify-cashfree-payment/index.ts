// HeartTalk: verify Cashfree payments and safely recover pending orders for the signed-in user.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, apikey, x-client-info, content-type","Access-Control-Allow-Methods":"POST, OPTIONS"};
const reply=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,"Content-Type":"application/json","Cache-Control":"no-store"}});

Deno.serve(async(req)=>{
  if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
  if(req.method!=="POST")return reply({error:"Method not allowed"},405);
  try{
    const jwt=(req.headers.get("Authorization")||"").replace(/^Bearer\s+/i,"");
    const url=Deno.env.get("SUPABASE_URL"),anon=Deno.env.get("SUPABASE_ANON_KEY"),service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const clientId=Deno.env.get("CASHFREE_CLIENT_ID"),clientSecret=Deno.env.get("CASHFREE_CLIENT_SECRET");
    const env=(Deno.env.get("CASHFREE_ENV")||"sandbox").toLowerCase();
    if(!jwt)return reply({error:"Please sign in first."},401);
    if(!url||!anon||!service||!clientId||!clientSecret||!(env==="sandbox"||env==="production"))return reply({error:"Cashfree verification is not configured for the selected environment."},503);

    const authClient=createClient(url,anon,{auth:{persistSession:false,autoRefreshToken:false}});
    const {data:auth,error:authError}=await authClient.auth.getUser(jwt);
    if(authError||!auth.user)return reply({error:"Your session expired. Please sign in again."},401);
    const body=await req.json().catch(()=>({}));
    const requestedId=typeof body.order_id==="string"?body.order_id.trim():"";
    if(requestedId&&!/^ht_[a-f0-9]{32}$/.test(requestedId))return reply({error:"Invalid Cashfree order ID."},400);

    const admin=createClient(url,service,{auth:{persistSession:false,autoRefreshToken:false}});
    let query=admin.from("payment_orders").select("id,user_id,provider,amount_paise,currency,status,coins,provider_order_id")
      .eq("user_id",auth.user.id).eq("provider","cashfree");
    if(requestedId)query=query.eq("provider_order_id",requestedId);
    else query=query.eq("status","created").order("created_at",{ascending:false}).limit(10);
    const {data:orders,error:ordersError}=await query;
    if(ordersError)return reply({error:"Could not load your pending payment orders."},500);
    if(!orders?.length)return reply({status:"no_pending_orders",coins:0,message:"No pending Cashfree orders were found for this account."});

    const base=env==="production"?"https://api.cashfree.com/pg":"https://sandbox.cashfree.com/pg";
    const headers={"Accept":"application/json","x-api-version":"2025-01-01","x-client-id":clientId,"x-client-secret":clientSecret};
    const results=[];
    for(const order of orders){
      if(order.status==="paid"){results.push({status:"already_credited",coins:order.coins,order_id:order.provider_order_id});continue;}
      const orderResponse=await fetch(base+"/orders/"+encodeURIComponent(order.provider_order_id),{headers});
      const orderData=await orderResponse.json().catch(()=>({}));
      if(!orderResponse.ok){console.error("Cashfree order status fetch failed",orderResponse.status,orderData);results.push({status:"verification_error",order_id:order.provider_order_id});continue;}
      if(orderData.order_status!=="PAID"){results.push({status:String(orderData.order_status||"PENDING").toLowerCase(),coins:0,order_id:order.provider_order_id});continue;}
      if(Number(Math.round(Number(orderData.order_amount)*100))!==Number(order.amount_paise)||orderData.order_currency!==order.currency){
        console.error("Cashfree amount/currency mismatch",order.provider_order_id);results.push({status:"amount_mismatch",order_id:order.provider_order_id});continue;
      }
      const paymentsResponse=await fetch(base+"/orders/"+encodeURIComponent(order.provider_order_id)+"/payments",{headers});
      const payments=await paymentsResponse.json().catch(()=>[]);
      if(!paymentsResponse.ok||!Array.isArray(payments)){results.push({status:"payment_lookup_error",order_id:order.provider_order_id});continue;}
      const payment=payments.find((p:any)=>p.payment_status==="SUCCESS"&&p.cf_payment_id&&Number(Math.round(Number(p.payment_amount)*100))===Number(order.amount_paise)&&p.payment_currency===order.currency);
      if(!payment){results.push({status:"pending",coins:0,order_id:order.provider_order_id});continue;}
      const {data:credit,error:creditError}=await admin.rpc("credit_verified_cashfree_coin_purchase",{
        p_provider_order_id:order.provider_order_id,p_provider_payment_id:String(payment.cf_payment_id),
        p_amount_paise:Number(order.amount_paise),p_currency:order.currency
      });
      if(creditError){console.error("Cashfree wallet credit RPC failed",creditError);results.push({status:"credit_error",order_id:order.provider_order_id});continue;}
      results.push({status:credit?.status||"credited",coins:Number(credit?.coins||order.coins),order_id:order.provider_order_id});
    }
    const credited=results.find(x=>x.status==="credited"||x.status==="already_credited");
    if(credited)return reply({...credited,results});
    return reply({status:results.some(x=>x.status==="verification_error"||x.status==="credit_error")?"needs_review":"pending",coins:0,results,
      message:"Payment is not yet confirmed or requires review. Do not pay again."});
  }catch(error){console.error("verify-cashfree-payment:",error);return reply({error:"Could not verify the Cashfree payment. Please do not pay again until the order status is checked."},500);}
});
