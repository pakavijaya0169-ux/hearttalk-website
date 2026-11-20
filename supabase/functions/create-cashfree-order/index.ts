// HeartTalk: create a Cashfree SANDBOX order using server-side package pricing.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, apikey, x-client-info, content-type","Access-Control-Allow-Methods":"POST, OPTIONS"};
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
    if(!url||!anon||!service||!clientId||!clientSecret) return reply({error:"Cashfree TEST credentials are not configured in Supabase Edge Function Secrets."},503);
    if(env!=="sandbox" && env!=="production") return reply({error:"CASHFREE_ENV must be sandbox or production."},503);

    const authClient=createClient(url,anon,{auth:{persistSession:false,autoRefreshToken:false}});
    const {data:auth,error:authError}=await authClient.auth.getUser(jwt);
    if(authError||!auth.user) return reply({error:"Your session expired. Please sign in again."},401);

    const body=await req.json().catch(()=>({}));
    const packageCode=typeof body.package_code==="string"?body.package_code.trim():"";
    const phone=String(body.customer_phone||"").replace(/\D/g,"");
    if(!/^[6-9]\d{9}$/.test(phone)) return reply({error:"Enter a valid 10-digit Indian mobile number."},400);

    const admin=createClient(url,service,{auth:{persistSession:false,autoRefreshToken:false}});
    const {data:pkg,error:pkgError}=await admin.from("coin_packages")
      .select("package_code,title,coins,amount_paise")
      .eq("package_code",packageCode).eq("active",true).maybeSingle();
    if(pkgError||!pkg) return reply({error:"This coin package is unavailable."},404);

    const orderId="ht_"+crypto.randomUUID().replace(/-/g,"");
    const amount=(Number(pkg.amount_paise)/100).toFixed(2);
    const api=(env==="production"?"https://api.cashfree.com/pg":"https://sandbox.cashfree.com/pg")+"/orders";
    const payload={
      order_id:orderId,
      order_amount:Number(amount),
      order_currency:"INR",
      customer_details:{
        customer_id:auth.user.id.replace(/-/g,"").slice(0,50),
        customer_phone:phone,
        ...(auth.user.email?{customer_email:auth.user.email}:{})
      },
      order_meta:{
        return_url:"https://pakavijaya0169-ux.github.io/hearttalk-website/?cashfree_return=1&order_id={order_id}",
        notify_url:url+"/functions/v1/cashfree-webhook"
      },
      order_note:"HeartTalk "+pkg.title+" coin package"
    };

    const response=await fetch(api,{
      method:"POST",
      headers:{
        "Content-Type":"application/json",
        "Accept":"application/json",
        "x-api-version":"2025-01-01",
        "x-client-id":clientId,
        "x-client-secret":clientSecret,
        "x-idempotency-key":crypto.randomUUID()
      },
      body:JSON.stringify(payload)
    });
    const result=await response.json().catch(()=>({}));
    if(!response.ok||!result.payment_session_id||result.order_id!==orderId){
      console.error("Cashfree sandbox order creation failed",response.status,result);
      return reply({error:"Cashfree could not create the test order. Check sandbox credentials and Cashfree account settings."},502);
    }

    const {error:insertError}=await admin.from("payment_orders").insert({
      user_id:auth.user.id,
      package_code:pkg.package_code,
      coins:pkg.coins,
      amount_paise:pkg.amount_paise,
      currency:"INR",
      provider:"cashfree",
      provider_order_id:orderId,
      status:"created"
    });
    if(insertError){
      console.error("Cashfree payment_orders insert failed",insertError);
      return reply({error:"The payment order could not be saved securely."},500);
    }

    return reply({
      order_id:orderId,
      payment_session_id:result.payment_session_id,
      amount_paise:pkg.amount_paise,
      coins:pkg.coins,
      environment:env
    });
  } catch(error) {
    console.error("create-cashfree-order:",error);
    return reply({error:"Unable to start Cashfree test payment."},500);
  }
});
