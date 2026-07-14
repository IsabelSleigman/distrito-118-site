(() => {
const client=window.distritoSupabase;
const money=v=>Number(v||0).toLocaleString("pt-BR",{style:"currency",currency:"BRL",maximumFractionDigits:0});
const labels={pending:"Aguardando análise",under_review:"Em análise",accepted:"Aceita",waiting_materials:"Aguardando materiais",in_production:"Em produção",ready:"Pronta",awaiting_delivery:"Aguardando entrega",delivered:"Entregue",rejected:"Recusada",cancelled:"Cancelada"};
const statusClass=value=>`status-${value||"unknown"}`;
const esc=v=>String(v??"").replace(/[&<>'"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"}[c]));
async function load(){
 const [{data:orders,error:oe},{data:cash,error:ce},{data:materials,error:me}]=await Promise.all([
  client.from("orders").select("code,customer_name,cnpj_name,total_amount,status,created_at").order("created_at",{ascending:false}).limit(50),
  client.from("cash_movements").select("movement_type,amount"),
  client.from("materials").select("name,stock_quantity,reserved_quantity,minimum_stock,is_active").eq("is_active",true)
 ]);
 if(oe||ce||me){console.error(oe||ce||me);toast("Não foi possível carregar todo o dashboard.");}
 const list=orders||[];document.getElementById("statPending").textContent=list.filter(o=>["pending","under_review"].includes(o.status)).length;
 document.getElementById("statProduction").textContent=list.filter(o=>["accepted","waiting_materials","in_production"].includes(o.status)).length;
 document.getElementById("statDelivered").textContent=list.filter(o=>o.status==="delivered").length;
 const balance=(cash||[]).reduce((s,c)=>s+(c.movement_type==="entry"?Number(c.amount):-Number(c.amount)),0);document.getElementById("statCash").textContent=money(balance);
 document.getElementById("latestOrders").innerHTML=list.slice(0,6).map(o=>`<tr><td>${esc(o.code)}</td><td>${esc(o.cnpj_name||o.customer_name)}</td><td>${money(o.total_amount)}</td><td><span class="badge ${statusClass(o.status)}">${esc(labels[o.status]||o.status)}</span></td></tr>`).join("")||`<tr><td colspan="4" class="empty">Nenhuma encomenda registrada.</td></tr>`;
 const low=(materials||[]).filter(m=>Math.max(0,Number(m.stock_quantity||0)-Number(m.reserved_quantity||0))<=Number(m.minimum_stock||0));
 const box=document.getElementById("lowStockList");if(box)box.innerHTML=low.slice(0,6).map(m=>`<div class="summary-row"><span>${esc(m.name)}</span><strong>${Math.max(0,Number(m.stock_quantity||0)-Number(m.reserved_quantity||0))} disponível</strong></div>`).join("")||`<div class="empty">Nenhum material com estoque baixo.</div>`;
}
document.addEventListener("district-auth-ready",load,{once:true});
})();