(() => {
  const client=window.distritoSupabase;
  const esc=v=>String(v??"").replace(/[&<>'"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"}[c]));
  const table=document.getElementById("goalMembersTable"),modal=document.getElementById("manualProgressModal");
  if(!table||!modal)return;
  function addButtons(){table.querySelectorAll("tr[data-member-id] .table-actions").forEach(actions=>{if(actions.querySelector(".edit-item-progress"))return;const button=document.createElement("button");button.type="button";button.className="icon-btn edit-item-progress";button.textContent="Editar progresso";actions.prepend(button)})}
  new MutationObserver(addButtons).observe(table,{childList:true,subtree:true});addButtons();
  const close=()=>modal.classList.remove("open");document.getElementById("closeManualProgress").onclick=close;document.getElementById("cancelManualProgress").onclick=close;
  table.addEventListener("click",async event=>{
    const button=event.target.closest(".edit-item-progress");if(!button)return;
    const row=button.closest("tr[data-member-id]"),memberId=row.dataset.memberId,name=row.querySelector("td strong")?.textContent||"Membro";
    button.disabled=true;
    const [progress,ledger]=await Promise.all([
      client.from("weekly_goal_member_progress").select("inventory_item_id,item_name,required_quantity").eq("member_id",memberId).order("item_name"),
      client.from("weekly_goal_ledger").select("inventory_item_id,entry_type,quantity").eq("member_id",memberId)
    ]);button.disabled=false;if(progress.error||ledger.error)return toast(progress.error?.message||ledger.error?.message);
    const rows=progress.data||[];if(!rows.length)return toast("Esta meta não possui itens obrigatórios.");
    document.getElementById("manualProgressMemberId").value=memberId;document.getElementById("manualProgressTitle").textContent=`Editar progresso · ${name}`;document.getElementById("manualProgressNote").value="";
    document.getElementById("manualProgressRows").innerHTML=rows.map(item=>{const entries=(ledger.data||[]).filter(x=>x.inventory_item_id===item.inventory_item_id),counted=entries.filter(x=>["submission","correction","carry_in"].includes(x.entry_type)).reduce((s,x)=>s+Number(x.quantity),0),carried=entries.filter(x=>x.entry_type==="carry_out").reduce((s,x)=>s+Number(x.quantity),0);return`<div class="manual-progress-row"><div><strong>${esc(item.item_name)}</strong><small>Meta: ${Number(item.required_quantity)}${carried>0?` · ${carried} levado para a seguinte`:""}</small></div><label>Total contabilizado<input class="manual-item-total" data-item-id="${item.inventory_item_id}" type="number" min="0" step="0.01" value="${counted}"></label></div>`}).join("");modal.classList.add("open")
  });
  document.getElementById("manualProgressForm").addEventListener("submit",async event=>{event.preventDefault();const button=event.currentTarget.querySelector('button[type="submit"]');button.disabled=true;button.textContent="Salvando...";const payload=[...document.querySelectorAll(".manual-item-total")].map(input=>({item_id:input.dataset.itemId,quantity:Number(input.value||0)}));const{error}=await client.rpc("set_weekly_goal_member_item_totals",{p_member_id:document.getElementById("manualProgressMemberId").value,p_items:payload,p_note:document.getElementById("manualProgressNote").value.trim()||null});button.disabled=false;button.textContent="Salvar correção";if(error)return toast(error.message);close();toast("Progresso corrigido e adicionais recalculados.");document.getElementById("goalSelector")?.dispatchEvent(new Event("change"))});
})();
