(() => {
  const client=window.distritoSupabase,table=document.getElementById("goalMembersTable");
  if(!table)return;
  let busy=false;
  async function enhance(){
    if(busy)return;const goalId=document.getElementById("goalSelector")?.value,rows=[...table.querySelectorAll("tr[data-member-id]")];if(!goalId||!rows.length)return;
    busy=true;
    const[{data:goal},{data:members},{data:progress}]=await Promise.all([
      client.from("weekly_goals").select("target_amount,reward_name").eq("id",goalId).single(),
      client.from("weekly_goal_members").select("id,amount_paid,status,target_multiplier").eq("goal_id",goalId),
      client.from("weekly_goal_member_progress").select("member_id,remaining_quantity,credited_quantity").eq("goal_id",goalId)
    ]);
    const base=Number(goal?.target_amount||0),list=members||[],prog=progress||[];
    rows.forEach(row=>{
      const member=list.find(m=>m.id===row.dataset.memberId);if(!member)return;const mult=Number(member.target_multiplier||1),first=row.cells[0],cash=row.cells[1];
      let control=first.querySelector(".member-multiplier-control");if(!control){control=document.createElement("label");control.className="member-multiplier-control";control.innerHTML=`<span>Exigência</span><select><option value="1">Normal · 1x</option><option value="2">Dobro · 2x</option></select>`;first.appendChild(control)}control.querySelector("select").value=String(mult);
      const target=base*mult,cashSmall=cash?.querySelector("small");if(cashSmall)cashSmall.textContent=`de ${target.toLocaleString("pt-BR",{style:"currency",currency:"BRL",maximumFractionDigits:0})}`;
      const itemRows=prog.filter(p=>p.member_id===member.id),itemsOk=!itemRows.length||itemRows.every(p=>Number(p.remaining_quantity)===0),cashOk=!target||Number(member.amount_paid)>=target,eligible=itemsOk&&cashOk||["completed","completed_with_extra"].includes(member.status);
      if(!eligible){const deliver=row.querySelector(".deliver-bonus");if(deliver){const state=deliver.closest(".bonus-state");state.innerHTML='<span class="muted-caption">Aguardando conclusão</span>'}}
    });
    const valid=list.filter(m=>!["absent","excused"].includes(m.status));const isDone=m=>{const target=base*Number(m.target_multiplier||1),pr=prog.filter(p=>p.member_id===m.id);return(["completed","completed_with_extra"].includes(m.status)||((!target||Number(m.amount_paid)>=target)&&(!pr.length||pr.every(p=>Number(p.remaining_quantity)===0))))};
    const done=valid.filter(isDone).length,partial=valid.filter(m=>!isDone(m)&&(Number(m.amount_paid)>0||prog.some(p=>p.member_id===m.id&&Number(p.credited_quantity)>0))).length;
    document.getElementById("goalPaidCount").textContent=done;document.getElementById("goalPartialCount").textContent=partial;document.getElementById("goalPendingCount").textContent=Math.max(0,valid.length-done-partial);document.getElementById("goalPaidPercent").textContent=`${valid.length?Math.round(done/valid.length*100):0}% dos participantes`;busy=false
  }
  new MutationObserver(()=>setTimeout(enhance,0)).observe(table,{childList:true});
  table.addEventListener("change",async event=>{const select=event.target.closest(".member-multiplier-control select");if(!select)return;select.disabled=true;const{error}=await client.rpc("set_weekly_goal_member_multiplier",{p_member_id:select.closest("tr").dataset.memberId,p_multiplier:Number(select.value)});select.disabled=false;if(error)return toast(error.message);toast(select.value==="2"?"Meta dobrada para este membro.":"Meta normal restaurada.");document.getElementById("goalSelector")?.dispatchEvent(new Event("change"))});
  document.addEventListener("district-auth-ready",()=>setTimeout(enhance,100));
})();
