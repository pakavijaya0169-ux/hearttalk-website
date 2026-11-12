// HeartTalk: create a server-priced Razorpay order.
// Secrets: RAZORPAY_KEY_ID, RAZORPAY_KEY_SECRET, SUPABASE_URL,
// SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const cors = {"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, apikey, x-client-info, content-type","Access-Control-Allow-Methods":"POST, OPTIONS"};
const reply=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,"Content-Type":"application/json","Cache-Control":"no-store"}});
Deno.serve(async(req)=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
 if(req.method!=="POST")return reply({error:"Method not allowed"},405);
 try{
  const jwt=(req.headers.get("Authorization")||"").replace(/^Bearer\s+/i,"");
  const url=Deno.env.get("SUPABASE_URL"),anon=Deno.env.get("SUPABASE_ANON_KEY"),service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const keyId=Deno.env.get("RAZORPAY_KEY_ID"),keySecret=Deno.env.get("RAZORPAY_KEY_SECRET");
  if(!jwt)return reply({error:"Please sign in first."},401);
  if(!url||!anon||!service||!keyId||!keySecret)return reply({error:"Razorpay TEST credentials are not configured in Supabase Edge Function Secrets."},503);
  const authClient=createClient(url,anon,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data:auth,error:authError}=await authClient.auth.getUser(jwt);
  if(authError||!auth.user)return reply({error:"Your session expired. Please sign in again."},401);
  const admin=createClient(url,service,{auth:{persistSession:false,autoRefreshToken:false}});
  const body=await req.json().catch(()=>({}));
  const code=typeof body.package_code==="string"?body.package_code:"";
  const {data:pkg,error:pkgError}=await admin.from("coin_packages").select("package_code,title,coins,amount_paise").eq("package_code",code).eq("active",true).maybeSingle();
  if(pkgError||!pkg)return reply({error:"This coin package is unavailable."},404);
  const receipt="ht_"+crypto.randomUUID().replace(/-/g,"").slice(0,24);
  const provider=await fetch("https://api.razorpay.com/v1/orders",{
   method:"POST",headers:{"Authorization":"Basic "+btoa(keyId+":"+keySecret),"Content-Type":"application/json"},
   body:JSON.stringify({amount:Number(pkg.amount_paise),currency:"INR",receipt,notes:{user_id:auth.user.id,package_code:pkg.package_code,coins:String(pkg.coins)}})
  });
  const providerData=await provider.json().catch(()=>({}));
  if(!provider.ok||!providerData.id){console.error("Razorpay order creation failed",provider.status,providerData);return reply({error:"Razorpay could not create the order. Check TEST keys and account setup."},502);}
  const {error:insertError}=await admin.from("payment_orders").insert({
   user_id:auth.user.id,package_code:pkg.package_code,coins:pkg.coins,amount_paise:pkg.amount_paise,
   currency:"INR",provider:"razorpay",provider_order_id:providerData.id,status:"created"
  });
  if(insertError){console.error("payment_orders insert failed",insertError);return reply({error:"The payment order could not be saved securely."},500);}
  return reply({key_id:keyId,order_id:providerData.id,amount:pkg.amount_paise,currency:"INR",
   name:"HeartTalk",description:pkg.title+" · "+pkg.coins+" coins",prefill:{email:auth.user.email||""},
   package:{code:pkg.package_code,coins:pkg.coins}});
 }catch(error){console.error("create-razorpay-order:",error);return reply({error:"Unable to start coin purchase."},500);}
});
