(() => {
  const client = window.distritoSupabase;
  let products = [], materials = [], components = [];
  const esc = value => String(value ?? "").replace(/[&<>'"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"}[c]));
  const materialById = id => materials.find(item => item.id === id);
  const componentsFor = id => components.filter(item => item.material_id === id);
  const formatQty = value => Number(value || 0).toLocaleString("pt-BR", { maximumFractionDigits: 2 });

  function options(selected="") { return products.map(p => `<option value="${p.id}" ${p.id===selected?"selected":""}>${esc(p.name)}</option>`).join(""); }
  function addItem(productId=products[0]?.id, quantity=1) {
    if (!productId) return;
    const row=document.createElement("div"); row.className="calculator-item";
    row.innerHTML=`<div class="field"><label>Produto</label><select class="calculator-product">${options(productId)}</select></div><div class="field"><label>Quantidade</label><input class="calculator-quantity" type="number" min="1" value="${quantity}"></div><button class="icon-btn danger calculator-remove" type="button" aria-label="Remover">×</button>`;
    row.querySelectorAll("select,input").forEach(el=>el.addEventListener("input",calculate));
    row.querySelector(".calculator-remove").addEventListener("click",()=>{row.remove();calculate();});
    document.getElementById("calculatorItems").appendChild(row); calculate();
  }
  function add(map, material, quantity) {
    if (!material || quantity<=0) return;
    const current=map.get(material.id)||{id:material.id,name:material.name,unit:material.unit||"unidade",quantity:0};
    current.quantity+=quantity; map.set(material.id,current);
  }
  function buildPlan(items, considerStock) {
    const stock=new Map(materials.map(m=>[m.id,considerStock?Math.max(0,Number(m.stock_quantity||0)-Number(m.reserved_quantity||0)):0]));
    const direct=new Map(), separate=new Map(), produce=new Map(), missing=new Map();
    const consume=(materialId,quantity,stack=[])=>{
      const material=materialById(materialId); if(!material||quantity<=0)return;
      if(stack.includes(materialId)){add(missing,material,quantity);return;}
      const available=stock.get(materialId)||0, fromStock=Math.min(available,quantity);
      if(fromStock>0){add(separate,material,fromStock);stock.set(materialId,available-fromStock);}
      const remaining=quantity-fromStock; if(remaining<=0)return;
      const recipe=componentsFor(materialId);
      if(!recipe.length){add(missing,material,remaining);return;}
      add(produce,material,remaining);
      recipe.forEach(c=>consume(c.component_material_id,remaining*Number(c.quantity_required||0),[...stack,materialId]));
    };
    items.forEach(item=>{
      const product=products.find(p=>p.id===item.product_id);
      (product?.product_materials||[]).forEach(recipe=>{
        const material=materialById(recipe.material_id)||recipe.materials;
        const qty=item.quantity*Number(recipe.quantity_required||0);
        add(direct,material,qty); consume(material.id,qty);
      });
    });
    const sort=map=>[...map.values()].sort((a,b)=>a.name.localeCompare(b.name));
    return {direct:sort(direct),separate:sort(separate),produce:sort(produce),missing:sort(missing)};
  }
  function renderList(id,items,empty) {
    document.getElementById(id).innerHTML=items.length?items.map(i=>`<div><span>${esc(i.name)}</span><strong>${formatQty(i.quantity)} ${esc(i.unit)}</strong></div>`).join(""):`<p class="calculator-empty-list">${empty}</p>`;
  }
  function calculate() {
    const items=[...document.querySelectorAll(".calculator-item")].map(row=>({product_id:row.querySelector(".calculator-product").value,quantity:Math.max(1,Number(row.querySelector(".calculator-quantity").value||1))})).filter(i=>i.product_id);
    const empty=document.getElementById("calculatorEmpty"), planBox=document.getElementById("calculatorPlan");
    if(!items.length){empty.hidden=false;planBox.hidden=true;return;}
    const consider=document.getElementById("considerStock").checked, plan=buildPlan(items,consider);
    empty.hidden=true;planBox.hidden=false;
    document.getElementById("calculatorResultHint").textContent=consider?"O cálculo considera o estoque disponível.":"O cálculo mostra tudo necessário do zero, sem descontar estoque.";
    renderList("calculatorDirect",plan.direct,"Nenhum material cadastrado nas receitas.");
    renderList("calculatorSeparate",plan.separate,consider?"Nada disponível para separar.":"Modo sem estoque.");
    renderList("calculatorProduce",plan.produce,"Nenhum material intermediário precisa ser produzido.");
    renderList("calculatorMissing",plan.missing,consider?"Nada falta obter.":"Materiais básicos necessários do zero.");
  }
  async function load() {
    const [p,m,c]=await Promise.all([
      client.from("products").select("id,name,product_materials(material_id,quantity_required,materials(id,name,unit))").eq("is_active",true).eq("allows_order",true).order("name"),
      client.from("materials").select("id,name,unit,stock_quantity,reserved_quantity").eq("is_active",true).order("name"),
      client.from("material_components").select("material_id,component_material_id,quantity_required")
    ]);
    if(p.error)throw p.error;if(m.error)throw m.error;if(c.error)throw c.error;
    products=p.data||[];materials=m.data||[];components=c.data||[];addItem();
  }
  document.getElementById("addCalculatorItem")?.addEventListener("click",()=>addItem());
  document.getElementById("considerStock")?.addEventListener("change",calculate);
  document.getElementById("clearCalculator")?.addEventListener("click",()=>{document.getElementById("calculatorItems").innerHTML="";addItem();});
  document.addEventListener("district-auth-ready",async()=>{try{await load();}catch(e){console.error(e);toast("Não foi possível iniciar a calculadora.");}},{once:true});
})();
