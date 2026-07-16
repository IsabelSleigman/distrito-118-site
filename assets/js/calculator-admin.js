(() => {
  const client = window.distritoSupabase;
  let products = [], materials = [], components = [], selectableItems = [];
  const esc = value => String(value ?? "").replace(/[&<>'"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"}[c]));
  const materialById = id => materials.find(item => item.id === id);
  const componentsFor = id => components.filter(item => item.material_id === id);
  const formatQty = value => Number(value || 0).toLocaleString("pt-BR", { maximumFractionDigits: 2 });

  function groupedOptions(selected="") {
    const productOptions = products.map(item => `<option value="product:${item.id}" ${`product:${item.id}`===selected?"selected":""}>${esc(item.name)}</option>`).join("");
    const craftableMaterials = materials.filter(item => componentsFor(item.id).length > 0);
    const materialOptions = craftableMaterials.map(item => `<option value="material:${item.id}" ${`material:${item.id}`===selected?"selected":""}>${esc(item.name)}</option>`).join("");
    return `${productOptions ? `<optgroup label="PRODUTOS">${productOptions}</optgroup>` : ""}${materialOptions ? `<optgroup label="MATERIAIS PRODUZÍVEIS">${materialOptions}</optgroup>` : ""}`;
  }

  function addItem(itemKey=selectableItems[0]?.key, quantity=1) {
    if (!itemKey) return;
    const row=document.createElement("div"); row.className="calculator-item";
    row.innerHTML=`<div class="field"><label>Item para craftar</label><select class="calculator-selection">${groupedOptions(itemKey)}</select></div><div class="field"><label>Quantidade</label><input class="calculator-quantity" type="number" min="1" value="${quantity}"></div><button class="icon-btn danger calculator-remove" type="button" aria-label="Remover">×</button>`;
    row.querySelectorAll("select,input").forEach(el=>el.addEventListener("input",calculate));
    row.querySelector(".calculator-remove").addEventListener("click",()=>{row.remove();calculate();});
    document.getElementById("calculatorItems").appendChild(row); calculate();
  }

  function add(map, item, quantity) {
    if (!item || quantity<=0) return;
    const current=map.get(item.id)||{id:item.id,name:item.name,unit:item.unit||"unidade",quantity:0};
    current.quantity+=quantity; map.set(item.id,current);
  }

  function buildPlan(items, considerStock) {
    const stock=new Map(materials.map(m=>[m.id,considerStock?Math.max(0,Number(m.stock_quantity||0)-Number(m.reserved_quantity||0)):0]));
    const selected=new Map(), intermediates=new Map(), basicTotal=new Map(), separate=new Map(), produce=new Map(), missing=new Map();

    const expandTotal=(materialId,quantity,stack=[])=>{
      const material=materialById(materialId); if(!material||quantity<=0)return;
      if(stack.includes(materialId)){add(basicTotal,material,quantity);return;}
      const recipe=componentsFor(materialId);
      if(!recipe.length){add(basicTotal,material,quantity);return;}
      add(intermediates,material,quantity);
      recipe.forEach(c=>expandTotal(c.component_material_id,quantity*Number(c.quantity_required||0),[...stack,materialId]));
    };

    const consume=(materialId,quantity,stack=[])=>{
      const material=materialById(materialId); if(!material||quantity<=0)return;
      if(stack.includes(materialId)){add(missing,material,quantity);return;}
      const available=stock.get(materialId)||0;
      const fromStock=Math.min(available,quantity);
      if(fromStock>0){add(separate,material,fromStock);stock.set(materialId,available-fromStock);}
      const remaining=quantity-fromStock; if(remaining<=0)return;
      const recipe=componentsFor(materialId);
      if(!recipe.length){add(missing,material,remaining);return;}
      add(produce,material,remaining);
      recipe.forEach(c=>consume(c.component_material_id,remaining*Number(c.quantity_required||0),[...stack,materialId]));
    };

    items.forEach(item=>{
      const selectedItem=item.type==="product"?products.find(p=>p.id===item.id):materialById(item.id);
      if(selectedItem){
        const selectedKey=`${item.type}:${item.id}`;
        const current=selected.get(selectedKey)||{id:selectedKey,name:selectedItem.name,unit:"unidade",quantity:0,type:item.type};
        current.quantity+=item.quantity; selected.set(selectedKey,current);
      }

      if(item.type === "product") {
        const product=products.find(p=>p.id===item.id);
        (product?.product_materials||[]).forEach(recipe=>{
          const material=materialById(recipe.material_id)||recipe.materials;
          const qty=item.quantity*Number(recipe.quantity_required||0);
          expandTotal(material.id,qty);
          consume(material.id,qty);
        });
      } else if(item.type === "material") {
        expandTotal(item.id,item.quantity);
        consume(item.id,item.quantity);
      }
    });

    const sort=map=>[...map.values()].sort((a,b)=>a.name.localeCompare(b.name,"pt-BR"));
    return {selected:sort(selected),intermediates:sort(intermediates),basicTotal:sort(basicTotal),separate:sort(separate),produce:sort(produce),missing:sort(missing)};
  }

  function renderList(id,items,empty) {
    document.getElementById(id).innerHTML=items.length?items.map(i=>`<div><span>${esc(i.name)}</span><strong>${formatQty(i.quantity)} ${esc(i.unit)}</strong></div>`).join(""):`<p class="calculator-empty-list">${empty}</p>`;
  }

  function calculate() {
    const items=[...document.querySelectorAll(".calculator-item")].map(row=>{
      const [type,id]=row.querySelector(".calculator-selection").value.split(":");
      return {type,id,quantity:Math.max(1,Number(row.querySelector(".calculator-quantity").value||1))};
    }).filter(i=>i.id);
    const empty=document.getElementById("calculatorEmpty"), planBox=document.getElementById("calculatorPlan");
    if(!items.length){empty.hidden=false;planBox.hidden=true;return;}
    const consider=document.getElementById("considerStock").checked, plan=buildPlan(items,consider);
    empty.hidden=true;planBox.hidden=false;
    document.getElementById("calculatorResultHint").textContent=consider?"O sistema soma todos os itens escolhidos e desconta o estoque apenas uma vez.":"O sistema soma todos os itens escolhidos e calcula tudo do zero, sem descontar estoque.";
    renderList("calculatorSelected",plan.selected,"Nenhum item selecionado.");
    renderList("calculatorIntermediates",plan.intermediates,"Nenhum material intermediário faz parte deste cálculo.");
    renderList("calculatorBasicTotal",plan.basicTotal,"Nenhum material básico encontrado nas receitas.");
    renderList("calculatorSeparate",plan.separate,consider?"Nada disponível para separar.":"Modo sem estoque.");
    renderList("calculatorProduce",plan.produce,"Nenhum material intermediário precisa ser produzido.");
    renderList("calculatorMissing",plan.missing,consider?"Nada falta obter.":"Materiais básicos necessários do zero.");
  }

  async function load() {
    window.DistrictLoader?.show("Carregando receitas e materiais...");
    const [p,m,c]=await Promise.all([
      client.from("products").select("id,name,product_materials(material_id,quantity_required,materials(id,name,unit))").eq("is_active",true).eq("allows_order",true).order("name"),
      client.from("materials").select("id,name,unit,stock_quantity,reserved_quantity").eq("is_active",true).order("name"),
      client.from("material_components").select("material_id,component_material_id,quantity_required")
    ]);
    if(p.error)throw p.error;if(m.error)throw m.error;if(c.error)throw c.error;
    products=p.data||[];materials=m.data||[];components=c.data||[];
    selectableItems=[...products.map(x=>({key:`product:${x.id}`})),...materials.filter(x=>componentsFor(x.id).length).map(x=>({key:`material:${x.id}`}))];
    document.getElementById("calculatorItems").innerHTML="";
    if(selectableItems.length)addItem();
    else document.getElementById("calculatorEmpty").textContent="Nenhum produto ou material produzível cadastrado.";
  }

  document.getElementById("addCalculatorItem")?.addEventListener("click",()=>addItem());
  document.getElementById("considerStock")?.addEventListener("change",calculate);
  document.getElementById("clearCalculator")?.addEventListener("click",()=>{document.getElementById("calculatorItems").innerHTML="";addItem();});
  document.addEventListener("district-auth-ready",async()=>{
    try{await load();}
    catch(e){console.error(e);window.DistrictLoader?.error("Não foi possível carregar a calculadora.");toast("Não foi possível iniciar a calculadora.");return;}
    window.DistrictLoader?.hide();
  },{once:true});
})();
