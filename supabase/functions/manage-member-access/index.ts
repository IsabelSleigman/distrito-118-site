import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type"};
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,"Content-Type":"application/json"}});
const password=()=>`DT-${crypto.randomUUID().replaceAll("-","").slice(0,12)}!`;
const normalize=(v:string)=>v.normalize("NFD").replace(/[\u0300-\u036f]/g,"").toLowerCase().replace(/[^a-z0-9._-]+/g,"").replace(/^\.+|\.+$/g,"");

Deno.serve(async(req)=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
 try{
  const url=Deno.env.get("SUPABASE_URL")!,anon=Deno.env.get("SUPABASE_ANON_KEY")!,service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const auth=req.headers.get("Authorization")||"";
  const caller=createClient(url,anon,{global:{headers:{Authorization:auth}}});
  const {data:{user}}=await caller.auth.getUser(); if(!user)return json({error:"Sessão inválida."},401);
  const {data:roles}=await caller.from("profile_roles").select("user_roles(name)").eq("profile_id",user.id);
  const allowed=(roles||[]).some((r:any)=>["admin","lideranca","01","02","03"].includes(String(r.user_roles?.name||"").toLowerCase()));
  if(!allowed)return json({error:"Apenas a liderança pode gerenciar acessos."},403);
  const admin=createClient(url,service,{auth:{autoRefreshToken:false,persistSession:false}});
  const {member_id,action,username:requested}=await req.json();
  const {data:member,error:memberError}=await admin.from("members").select("*").eq("id",member_id).single();
  if(memberError||!member)return json({error:"Membro não encontrado."},404);
  const username=normalize(requested||member.username||`${member.name}.${member.member_code||member.id.slice(0,6)}`);
  if(username.length<3)return json({error:"Nome de usuário inválido."},400);
  const temporaryPassword=password(),internalEmail=`${username}@login.distrito.invalid`;
  let profileId=member.profile_id;
  if(action==="create"){
   if(profileId)return json({error:"Este membro já possui acesso."},409);
   const {data,error}=await admin.auth.admin.createUser({email:internalEmail,password:temporaryPassword,email_confirm:true,user_metadata:{name:member.name,must_change_password:true}});
   if(error)return json({error:error.message},400); profileId=data.user.id;
  }else if(action==="reset"){
   if(!profileId)return json({error:"Este membro ainda não possui acesso."},400);
   const {error}=await admin.auth.admin.updateUserById(profileId,{password:temporaryPassword}); if(error)return json({error:error.message},400);
  }else return json({error:"Ação inválida."},400);
  await admin.from("profiles").update({name:member.name,must_change_password:true,is_active:true}).eq("id",profileId);
  await admin.from("members").update({profile_id:profileId,...(action==="create"?{username}:{}),access_status:"temporary_password",access_created_at:new Date().toISOString()}).eq("id",member.id);
  const {data:role}=await admin.from("user_roles").select("id").eq("name",member.access_level).maybeSingle();
  if(role)await admin.from("profile_roles").upsert({profile_id:profileId,role_id:role.id});
  return json({success:true,login:action==="create"?username:(member.email||member.username),temporary_password:temporaryPassword});
 }catch(error){return json({error:error instanceof Error?error.message:"Erro inesperado."},500)}
});
