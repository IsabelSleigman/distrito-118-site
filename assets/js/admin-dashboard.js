(() => {
const client=window.distritoSupabase;
const money=v=>Number(v||0).toLocaleString("pt-BR",{style:"currency",currency:"BRL",maximumFractionDigits:0});
const labels={pending:"Aguardando análise",under_review:"Em análise",accepted:"Aceita",waiting_materials:"Separação de materiais",in_production:"Em produção",ready:"Pronta",awaiting_delivery:"Aguardando entrega",delivered:"Entregue",rejected:"Recusada",cancelled:"Cancelada"};
const statusClass=value=>`status-${value||"unknown"}`;
const esc=v=>String(v??"").replace(/[&<>'"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"}[c]));
const normalize=v=>String(v||"").normalize("NFD").replace(/[\u0300-\u036f]/g,"").trim().toLowerCase();
const moneyType=name=>{const n=normalize(name);if(!n.includes("dinheiro"))return null;if(n.includes("sujo"))return"dirty";if(n.includes("limpo"))return"clean";return null;};
async function load(){
 const [ordersResult,financeResult,materialsResult,stockResult,balancesResult]=await Promise.all([
  client.from("orders").select("code,customer_name,cnpj_name,total_amount,status,created_at").is("deleted_at",null).order("created_at",{ascending:false}).limit(50),
  client.from("orders").select("net_amount,vault_deposited_at").eq("status","delivered").is("deleted_at",null).not("cash_posted_at","is",null),
  client.from("materials").select("id,name,stock_quantity,reserved_quantity,minimum_stock,is_active").eq("is_active",true),
  client.from("inventory_stocks").select("id,scope").eq("scope","gerencia").maybeSingle(),
  client.from("inventory_balances").select("stock_id,material_id,quantity,reserved_quantity")
 ]);
 const error=ordersResult.error||financeResult.error||materialsResult.error||stockResult.error||balancesResult.error;
 if(error){console.error(error);toast("Não foi possível carregar todo o dashboard.");}
 const list=ordersResult.data||[];
 const financeOrders=financeResult.data||[];
 const materials=materialsResult.data||[];
 const managementStock=stockResult.data;
 const balances=balancesResult.data||[];
 document.getElementById("statPending").textContent=list.filter(o=>["pending","under_review"].includes(o.status)).length;
 document.getElementById("statProduction").textContent=list.filter(o=>["accepted","waiting_materials","in_production"].includes(o.status)).length;
 document.getElementById("statDelivered").textContent=list.filter(o=>o.status==="delivered").length;

 // O saldo do dashboard usa a mesma fonte de verdade da tela Caixa:
 // dinheiro atual no estoque da Gerência + pedidos líquidos ainda não depositados.
 const materialTypeById=new Map(materials.map(m=>[m.id,moneyType(m.name)]));
 let vaultTotal=0;
 if(managementStock?.id){
   balances.filter(b=>b.stock_id===managementStock.id).forEach(b=>{
     if(materialTypeById.get(b.material_id)) vaultTotal+=Number(b.quantity||0);
   });
 }
 const pendingTotal=financeOrders.filter(o=>!o.vault_deposited_at).reduce((s,o)=>s+Number(o.net_amount||0),0);
 document.getElementById("statCash").textContent=money(vaultTotal+pendingTotal);

 document.getElementById("latestOrders").innerHTML=list.slice(0,6).map(o=>`<tr><td>${esc(o.code)}</td><td>${esc(o.cnpj_name||o.customer_name)}</td><td>${money(o.total_amount)}</td><td><span class="badge ${statusClass(o.status)}">${esc(labels[o.status]||o.status)}</span></td></tr>`).join("")||`<tr><td colspan="4" class="empty">Nenhuma encomenda registrada.</td></tr>`;
 const gerenciaBalanceByMaterial=new Map(balances.filter(b=>b.stock_id===managementStock?.id).map(b=>[b.material_id,b]));
 const low=materials.filter(m=>{const b=gerenciaBalanceByMaterial.get(m.id);const available=Math.max(0,Number(b?.quantity??m.stock_quantity??0)-Number(b?.reserved_quantity??m.reserved_quantity??0));return available<=Number(m.minimum_stock||0);});
 const box=document.getElementById("lowStockList");if(box)box.innerHTML=low.slice(0,6).map(m=>{const b=gerenciaBalanceByMaterial.get(m.id);const available=Math.max(0,Number(b?.quantity??m.stock_quantity??0)-Number(b?.reserved_quantity??m.reserved_quantity??0));return `<div class="summary-row"><span>${esc(m.name)}</span><strong>${available} disponível</strong></div>`;}).join("")||`<div class="empty">Nenhum material com estoque baixo.</div>`;
}
document.addEventListener("district-auth-ready",load,{once:true});
})();
