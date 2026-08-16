(() => {
  const client=window.distritoSupabase,esc=v=>String(v??"").replace(/[&<>'"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"}[c]));
  let members=[];
  const labels={active:"Ativo",absent:"Ausente",away:"Afastado",dismissed:"Exonerado",membro:"Membro",gerencia:"Gerência","01":"01","02":"02","03":"03"};
  function toast(x){const e=document.querySelector(".toast");e.textContent=x;e.classList.add("show");setTimeout(()=>e.classList.remove("show"),3000)}
  async function load(){let q=client.from("members").select("*").order("name");const f=document.getElementById("memberFilter").value;if(f)q=q.eq("status",f);const{data,error}=await q;if(error)return toast(error.message);members=data||[];document.getElementById("membersTable").innerHTML=members.map(m=>`<tr><td><strong>${esc(m.name)}</strong><div class="muted-caption">${esc(m.member_code||m.email||"Sem passaporte")}</div></td><td>${esc(labels[m.access_level]||m.access_level)}</td><td>${esc(m.discord_user_id||"Não vinculado")}</td><td>${esc(m.discord_channel_id||"Não vinculado")}</td><td><span class="badge ${m.status==='active'?'green':m.status==='dismissed'?'red':'warning'}">${esc(labels[m.status])}</span></td><td><div class="table-actions"><button class="icon-btn edit" data-id="${m.id}">Editar</button>${m.status==='dismissed'?`<button class="icon-btn reactivate" data-id="${m.id}">Reintegrar</button>`:`<button class="icon-btn danger dismiss" data-id="${m.id}">Exonerar</button>`}</div></td></tr>`).join("")||`<tr><td colspan="6" class="empty">Nenhum usuário encontrado.</td></tr>`}
  function open(m={}){document.getElementById("memberForm").reset();document.getElementById("memberId").value=m.id||"";document.getElementById("memberName").value=m.name||"";document.getElementById("memberCode").value=m.member_code||"";document.getElementById("memberEmail").value=m.email||"";document.getElementById("memberAccess").value=m.access_level||"membro";document.getElementById("memberStatus").value=m.status||"active";document.getElementById("memberDiscord").value=m.discord_user_id||"";document.getElementById("memberChannel").value=m.discord_channel_id||"";document.getElementById("memberModalTitle").textContent=m.id?"Editar usuário":"Novo usuário";document.getElementById("memberModal").classList.add("open")}
  function close(){document.getElementById("memberModal").classList.remove("open")}
  document.addEventListener("district-auth-ready",async()=>{document.getElementById("newMember").onclick=()=>open();document.getElementById("closeMemberModal").onclick=close;document.getElementById("cancelMemberModal").onclick=close;document.getElementById("memberFilter").onchange=load;document.getElementById("memberForm").onsubmit=async e=>{e.preventDefault();const{error}=await client.rpc("save_member",{p_id:document.getElementById("memberId").value||null,p_name:document.getElementById("memberName").value,p_member_code:document.getElementById("memberCode").value||null,p_email:document.getElementById("memberEmail").value||null,p_access_level:document.getElementById("memberAccess").value,p_discord_user_id:document.getElementById("memberDiscord").value||null,p_discord_channel_id:document.getElementById("memberChannel").value||null,p_status:document.getElementById("memberStatus").value});if(error)return toast(error.message);close();toast("Usuário salvo.");await load()};document.getElementById("membersTable").onclick=async e=>{const id=e.target.dataset.id,m=members.find(x=>x.id===id);if(e.target.classList.contains("edit"))open(m);if(e.target.classList.contains("dismiss")){const reason=prompt(`Motivo da exoneração de ${m.name}:`);if(reason===null)return;const{error}=await client.rpc("dismiss_member",{p_member_id:id,p_reason:reason||null});if(error)toast(error.message);else{toast("Usuário exonerado e histórico preservado.");await load()}}if(e.target.classList.contains("reactivate")){const{error}=await client.rpc("save_member",{p_id:id,p_name:m.name,p_member_code:m.member_code,p_email:m.email,p_access_level:m.access_level,p_discord_user_id:m.discord_user_id,p_discord_channel_id:m.discord_channel_id,p_status:"active"});if(error)toast(error.message);else{toast("Usuário reintegrado.");await load()}}};await load();window.lucide?.createIcons()},{once:true});
})();

// Gestão segura de acesso: adiciona ações sem armazenar a senha temporária.
document.addEventListener("district-auth-ready", () => {
  const table = document.getElementById("membersTable");
  if (!table) return;
  const showCredential = (login,password) => {
    const wrapper=document.createElement("div"); wrapper.className="modal-backdrop open credential-backdrop";
    wrapper.innerHTML=`<div class="modal-card credential-card"><button class="modal-close" type="button">×</button><div class="credential-body"><span class="eyebrow">Acesso gerado</span><h2>Credencial temporária</h2><p>Envie estes dados ao membro. A senha não ficará salva nesta tela.</p><label>Login</label><div class="credential-value"><code>${login}</code></div><label>Senha temporária</label><div class="credential-value"><code>${password}</code></div><div class="form-actions"><button class="btn ghost credential-close" type="button">Fechar</button><button class="btn primary credential-copy" type="button">Copiar credenciais</button></div></div></div>`;
    document.body.appendChild(wrapper); const close=()=>{wrapper.remove();location.reload()};
    wrapper.querySelector(".modal-close").onclick=close;wrapper.querySelector(".credential-close").onclick=close;
    wrapper.querySelector(".credential-copy").onclick=async e=>{await navigator.clipboard.writeText(`Login: ${login}\nSenha temporária: ${password}`);e.currentTarget.textContent="Copiado ✓"};
  };
  const enhance = async () => {
    const { data } = await window.distritoSupabase.from("members").select("id,name,email,username,profile_id,access_status");
    const map = new Map((data || []).map(x => [x.id, x]));
    table.querySelectorAll("tr").forEach(row => {
      const base = row.querySelector("button[data-id]");
      if (!base || row.querySelector(".member-access-action")) return;
      const member = map.get(base.dataset.id), actions = base.parentElement;
      if (!member || !actions) return;
      const button = document.createElement("button");
      button.type="button"; button.dataset.id=member.id; button.className="icon-btn member-access-action";
      button.textContent=member.profile_id ? "Redefinir senha" : "Gerar acesso";
      button.dataset.action=member.profile_id ? "reset" : "create";
      actions.prepend(button);
    });
  };
  new MutationObserver(enhance).observe(table,{childList:true,subtree:true}); enhance();
  table.addEventListener("click",async event=>{
    const button=event.target.closest(".member-access-action"); if(!button)return;
    const action=button.dataset.action;
    if(action==="reset"&&!confirm("A senha atual deixará de funcionar. Gerar uma nova senha temporária?"))return;
    button.disabled=true;button.textContent="Gerando...";
    const {data,error}=await window.distritoSupabase.functions.invoke("manage-member-access",{body:{member_id:button.dataset.id,action}});
    button.disabled=false;
    if(error||data?.error){alert(data?.error||error?.message||"Não foi possível gerar o acesso.");button.textContent=action==="create"?"Gerar acesso":"Redefinir senha";return}
    showCredential(data.login,data.temporary_password);
  });
},{once:true});
