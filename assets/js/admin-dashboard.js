(() => {
const client=window.distritoSupabase;
const money=v=>Number(v||0).toLocaleString("pt-BR",{style:"currency",currency:"BRL",maximumFractionDigits:0});
const labels={pending:"Aguardando análise",under_review:"Em análise",accepted:"Aceita",waiting_materials:"Separação de materiais",in_production:"Em produção",ready:"Pronta",awaiting_delivery:"Aguardando entrega",delivered:"Entregue",rejected:"Recusada",cancelled:"Cancelada"};
const statusClass=value=>`status-${value||"unknown"}`;
const esc=v=>String(v??"").replace(/[&<>'"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"}[c]));
const normalize=v=>String(v||"").normalize("NFD").replace(/[\u0300-\u036f]/g,"").trim().toLowerCase();
const moneyType=name=>{const n=normalize(name);if(!n.includes("dinheiro"))return null;if(n.includes("sujo"))return"dirty";return"clean";};
async function load(){
 if(window.currentDistrictUser?.accessLevel==="membro"){
  const{data,error}=await client.rpc("get_my_member_dashboard");if(error){toast(error.message);return}
  const g=data?.goal,main=document.querySelector(".admin-main");
  main.innerHTML=`<div class="admin-top"><div><span class="eyebrow">Meu painel</span><h1>Olá, ${esc(data.member?.name||"Membro")}</h1><p class="page-subtitle">Acompanhe sua meta semanal e acesse a calculadora.</p></div></div><section class="panel member-goal-card"><span class="eyebrow">Meta atual</span>${g?`<h2>${esc(g.title)}</h2><p>${esc(g.start_date)} até ${esc(g.end_date)} · <strong>${esc(g.member_status||"Em andamento")}</strong></p><div class="member-requirements">${(g.requirements||[]).map(r=>`<div><span>${esc(r.item_name)}</span><strong>${r.credited}/${r.required}</strong><small>${Number(r.remaining)>0?`Faltam ${r.remaining}`:Number(r.extra)>0?`Extra ${r.extra}`:"Concluído ✓"}</small></div>`).join("")||"<p>Nenhum item obrigatório.</p>"}</div>${g.reward_name?`<p>Prêmio: <strong>${esc(g.reward_name)}</strong></p>`:""}`:`<h2>Nenhuma meta ativa</h2><p>Quando uma nova semana for criada, ela aparecerá aqui.</p>`}</section>`;return;
 }
 const [ordersResult,financeResult,materialsResult,stockResult,balancesResult]=await Promise.all([
  client.from("orders").select("code,customer_name,cnpj_name,total_amount,status,created_at").is("deleted_at",null).order("created_at",{ascending:false}).limit(50),
  client.from("orders").select("net_amount,vault_deposited_at").eq("status","delivered").is("deleted_at",null).not("cash_posted_at","is",null),
  client.from("inventory_catalog").select("item_id,name,minimum_stock,is_active").eq("is_active",true),
  client.from("inventory_stocks").select("id,scope,name").in("scope",["geral","gerencia"]),
  client.from("inventory_all_balances").select("stock_id,item_id,quantity,reserved_quantity")
 ]);
 const error=ordersResult.error||financeResult.error||materialsResult.error||stockResult.error||balancesResult.error;
 if(error){console.error(error);toast("Não foi possível carregar todo o dashboard.");}
 const list=ordersResult.data||[];
 const financeOrders=financeResult.data||[];
 const materials=materialsResult.data||[];
 const stocks=stockResult.data||[];
 const balances=balancesResult.data||[];
 document.getElementById("statPending").textContent=list.filter(o=>["pending","under_review"].includes(o.status)).length;
 document.getElementById("statProduction").textContent=list.filter(o=>["accepted","waiting_materials","in_production"].includes(o.status)).length;
 document.getElementById("statDelivered").textContent=list.filter(o=>o.status==="delivered").length;

 // O saldo do dashboard mostra somente o dinheiro que já está fisicamente
 // nos estoques Geral e Gerência. Pedidos aguardando depósito ficam no Caixa e Baú.
 const materialTypeById=new Map(materials.map(m=>[m.item_id,moneyType(m.name)]));
 let vaultTotal=0;
 const activeStockIds=new Set(stocks.map(stock=>stock.id));
 balances.filter(b=>activeStockIds.has(b.stock_id)).forEach(b=>{
   if(materialTypeById.get(b.item_id)) vaultTotal+=Number(b.quantity||0);
 });
 document.getElementById("statCash").textContent=money(vaultTotal);

 document.getElementById("latestOrders").innerHTML=list.slice(0,6).map(o=>`<tr><td>${esc(o.code)}</td><td>${esc(o.cnpj_name||o.customer_name)}</td><td>${money(o.total_amount)}</td><td><span class="badge ${statusClass(o.status)}">${esc(labels[o.status]||o.status)}</span></td></tr>`).join("")||`<tr><td colspan="4" class="empty">Nenhuma encomenda registrada.</td></tr>`;
 const totalsByMaterial=new Map();
 balances.filter(b=>activeStockIds.has(b.stock_id)).forEach(b=>{
   const current=totalsByMaterial.get(b.item_id)||{quantity:0,reserved:0};
   current.quantity+=Number(b.quantity||0);
   current.reserved+=Number(b.reserved_quantity||0);
   totalsByMaterial.set(b.item_id,current);
 });
 const stockById=new Map(stocks.map(stock=>[stock.id,stock]));
 const low=materials.map(m=>{
   const total=totalsByMaterial.get(m.item_id)||{quantity:0,reserved:0};
   const available=Math.max(0,total.quantity-total.reserved);
   const locations=balances.filter(b=>b.item_id===m.item_id&&activeStockIds.has(b.stock_id)&&Number(b.quantity||0)>0)
     .map(b=>`${stockById.get(b.stock_id)?.scope==="gerencia"?"Gerência":"Geral"}: ${Number(b.quantity||0)}`);
   return {material:m,available,locations};
 }).filter(row=>{
   const minimum=Number(row.material.minimum_stock||0);
   return minimum>0 && row.available<minimum;
 });
 const box=document.getElementById("lowStockList");if(box)box.innerHTML=low.slice(0,6).map(row=>`<div class="summary-row"><span>${esc(row.material.name)}${row.locations.length?`<small>${esc(row.locations.join(" · "))}</small>`:""}</span><strong>${row.available} disponível</strong></div>`).join("")||`<div class="empty">Nenhum material com estoque baixo.</div>`;
}
document.addEventListener("district-auth-ready",load,{once:true});
})();
