(() => {
  const client = window.distritoSupabase;
  let catalog = [], products = [], recipes = [], balances = [], stocks = [];
  const strategies = new Map();
  const esc = value => String(value ?? "").replace(/[&<>'"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"}[c]));
  const fmt = value => Number(value || 0).toLocaleString("pt-BR", { maximumFractionDigits: 2 });
  const itemById = id => catalog.find(item => item.item_id === id);
  const recipeFor = id => recipes.filter(row => row.production_item_id === id);

  function groupedOptions(selected = "") {
    const productOptions = products.map(product => `<option value="product:${product.id}" ${`product:${product.id}` === selected ? "selected" : ""}>${esc(product.name)}</option>`).join("");
    const materials = catalog.filter(item => !item.is_product && item.is_craftable);
    const materialOptions = materials.map(item => `<option value="item:${item.item_id}" ${`item:${item.item_id}` === selected ? "selected" : ""}>${esc(item.name)}</option>`).join("");
    return `<optgroup label="PRODUTOS">${productOptions}</optgroup><optgroup label="MATERIAIS PRODUZÍVEIS">${materialOptions}</optgroup>`;
  }

  function addSelection(selectionKey = products[0] ? `product:${products[0].id}` : catalog.find(item => item.is_craftable) ? `item:${catalog.find(item => item.is_craftable).item_id}` : "", quantity = 1, mode = "auto") {
    if (!selectionKey) return;
    const row = document.createElement("div"); row.className = "calculator-item";
    row.innerHTML = `<div class="field"><label>Item</label><select class="calculator-selection">${groupedOptions(selectionKey)}</select></div><div class="field"><label>Quantidade</label><input class="calculator-quantity" type="number" min="1" value="${quantity}"></div><div class="field"><label>Como obter</label><select class="calculator-root-mode"><option value="auto" ${mode==="auto"?"selected":""}>Automático</option><option value="stock" ${mode==="stock"?"selected":""}>Pegar do baú</option><option value="produce" ${mode==="produce"?"selected":""}>Produzir</option></select></div><button class="icon-btn danger calculator-remove" type="button">×</button>`;
    row.querySelectorAll("select,input").forEach(element => element.addEventListener("input", calculate));
    row.querySelector("button").onclick = () => { row.remove(); calculate(); };
    document.getElementById("calculatorItems").appendChild(row); calculate();
  }

  function add(map, item, quantity, suffix = "", label = null) {
    if (!item || quantity <= 0) return;
    const key = `${item.item_id}${suffix}`;
    const row = map.get(key) || { id:key, name:label || item.name, unit:item.unit || "unidade", quantity:0 };
    row.quantity += quantity; map.set(key,row);
  }
  const sorted = map => [...map.values()].sort((a,b) => a.name.localeCompare(b.name,"pt-BR"));

  function selectedItems() {
    const merged = new Map();
    document.querySelectorAll(".calculator-item").forEach(row => {
      const key = row.querySelector("select").value;
      const quantity = Math.max(1,Number(row.querySelector("input").value || 1));
      const mode = row.querySelector(".calculator-root-mode")?.value || "auto";
      const mergedKey=`${key}:${mode}`;merged.set(mergedKey,(merged.get(mergedKey)||0)+quantity);
    });
    return [...merged].map(([mergedKey,quantity]) => {
      const [type,id,mode] = mergedKey.split(":");const key=`${type}:${id}`;
      if (type === "product") {
        const product = products.find(row => row.id === id);
        return product ? { key, id:product.inventory_item_id, quantity, displayName:product.name, mode } : null;
      }
      const item = itemById(id);
      return item ? { key, id, quantity, displayName:item.name, mode } : null;
    }).filter(Boolean);
  }

  function buildPlan(requested, considerStock) {
    const byScope = { geral:new Map(), gerencia:new Map() };
    const scopeByStock = new Map(stocks.map(stock => [stock.id,stock.scope]));
    balances.forEach(row => {
      const scope = scopeByStock.get(row.stock_id);
      if (byScope[scope]) byScope[scope].set(row.item_id,considerStock ? Math.max(0,Number(row.quantity||0)-Number(row.reserved_quantity||0)) : 0);
    });
    const selected = new Map(), separate = new Map(), produce = new Map(), missing = new Map(), surplus = new Map(), dependencies = new Map(), basics = new Map();
    requested.forEach(row => add(selected,{ ...itemById(row.id), item_id:row.key, name:row.displayName },row.quantity));

    const take = (item,quantity,displayName=null) => {
      let remaining=quantity;
      for (const scope of ["geral","gerencia"]) {
        const available=byScope[scope].get(item.item_id)||0, used=Math.min(available,remaining);
        if (used>0) {
          add(separate,item,used,`:${scope}`,`${displayName || item.name} · ${scope === "geral" ? "Geral" : "Gerência"}`);
          byScope[scope].set(item.item_id,available-used); remaining-=used;
        }
      }
      return remaining;
    };

    const process = (id,quantity,{root=false,stack=[],displayName=null,requestedMode=null}={}) => {
      const item=itemById(id); if(!item||quantity<=0)return;
      if(stack.includes(id)){add(missing,item,quantity);return;}
      const recipe=recipeFor(id);
      let remaining=quantity;
      const mode=root ? (requestedMode||"auto") : (strategies.get(id)||"auto");
      if(mode!=="produce") remaining=take(item,remaining,displayName);
      if(remaining<=0)return;
      if(!recipe.length || mode==="stock"){add(missing,item,remaining,"",displayName); if(!recipe.length)add(basics,item,remaining,"",displayName); return;}
      if(!root)add(dependencies,item,quantity);
      const output=Math.max(.000001,Number(recipe[0].output_quantity||1));
      const batches=Math.ceil((remaining/output)-1e-9), produced=batches*output, extra=produced-remaining;
      add(produce,item,produced,"",displayName); if(extra>0)add(surplus,item,extra,"",displayName);
      recipe.forEach(component => process(component.component_item_id,batches*Number(component.quantity_required||0),{stack:[...stack,id]}));
    };
    requested.forEach(row => process(row.id,row.quantity,{root:true,displayName:row.displayName,requestedMode:row.mode}));
    return {selected:sorted(selected),separate:sorted(separate),produce:sorted(produce),missing:sorted(missing),surplus:sorted(surplus),dependencies:sorted(dependencies),basics:sorted(basics)};
  }

  function renderList(id,items,empty) {
    const target=document.getElementById(id); if(!target)return;
    target.innerHTML=items.length?items.map(item=>`<div><span>${esc(item.name)}</span><strong>${fmt(item.quantity)} ${esc(item.unit)}</strong></div>`).join(""):`<p class="calculator-empty-list">${empty}</p>`;
  }

  function renderStrategies(items) {
    const section=document.getElementById("calculatorStrategiesSection"),container=document.getElementById("calculatorStrategies");
    if(!items.length){section.hidden=true;container.innerHTML="";return;} section.hidden=false;
    container.innerHTML=items.map(item=>`<div class="calculator-strategy-row"><div><strong>${esc(item.name)}</strong><span>Dependência produzível</span></div><div class="field"><label>Como obter</label><select class="calculator-strategy" data-id="${item.id}"><option value="auto">Automático</option><option value="stock" ${strategies.get(item.id)==="stock"?"selected":""}>Usar pronta</option><option value="produce" ${strategies.get(item.id)==="produce"?"selected":""}>Produzir</option></select></div></div>`).join("");
    container.querySelectorAll("select").forEach(select=>select.onchange=()=>{strategies.set(select.dataset.id,select.value);calculate(false);});
  }

  function calculate(refreshStrategies=true) {
    const requested=selectedItems(); if(!requested.length)return;
    const plan=buildPlan(requested,document.getElementById("considerStock").checked);
    document.getElementById("calculatorEmpty").hidden=true;document.getElementById("calculatorPlan").hidden=false;
    if(refreshStrategies)renderStrategies(plan.dependencies);
    renderList("calculatorSelected",plan.selected,"Nenhum item.");
    renderList("calculatorDirectMaterials",plan.produce,"Nada precisa ser fabricado.");
    renderList("calculatorDependencies",plan.dependencies,"Sem intermediários.");
    renderList("calculatorBasicTotal",plan.basics,"Sem material básico faltante.");
    renderList("calculatorSeparate",plan.separate,"Nada para separar.");
    renderList("calculatorProduce",plan.produce,"Nada para produzir.");
    renderList("calculatorMissing",plan.missing,"Nada falta obter.");
    renderList("calculatorSurplus",plan.surplus,"Nenhuma sobra de fabricação.");
  }

  async function load() {
    window.DistrictLoader?.show("Carregando itens, receitas e estoques...");
    if(window.currentDistrictUser?.accessLevel==="membro"){
      const{data,error}=await client.rpc("get_member_craft_data");if(error)throw error;
      catalog=data?.catalog||[];products=data?.products||[];recipes=data?.recipes||[];stocks=[];balances=[];
      const controls=document.querySelector(".calculator-stock-controls");if(controls)controls.hidden=true;
      const check=document.getElementById("considerStock");check.checked=false;check.disabled=true;
      document.getElementById("calculatorResultHint").textContent="Receita completa, sem consultar os estoques da organização.";
      document.querySelectorAll("#calculatorSeparate").forEach(x=>x.closest("section").hidden=true);
      document.getElementById("calculatorItems").innerHTML="";addSelection();window.DistrictLoader?.hide();return;
    }
    const [c,p,r,s,b]=await Promise.all([
      client.from("inventory_catalog").select("item_id,name,unit,is_active,is_product,is_material,is_craftable").eq("is_active",true).order("name"),
      client.from("products").select("id,name,inventory_item_id").eq("is_active",true).eq("allows_order",true).not("inventory_item_id","is",null).order("name"),
      client.from("inventory_craft_recipes").select("production_item_id,component_item_id,quantity_required,output_quantity"),
      client.from("inventory_stocks").select("id,scope").in("scope",["geral","gerencia"]),
      client.from("inventory_all_balances").select("stock_id,item_id,quantity,reserved_quantity")
    ]);
    if(c.error||p.error||r.error||s.error||b.error)throw(c.error||p.error||r.error||s.error||b.error);
    catalog=c.data||[];products=p.data||[];recipes=r.data||[];stocks=s.data||[];balances=b.data||[];
    document.getElementById("calculatorItems").innerHTML="";addSelection();window.DistrictLoader?.hide();
  }
  document.getElementById("addCalculatorItem")?.addEventListener("click",()=>addSelection());
  document.getElementById("considerStock")?.addEventListener("change",()=>calculate(false));
  document.getElementById("clearCalculator")?.addEventListener("click",()=>{strategies.clear();document.getElementById("calculatorItems").innerHTML="";addSelection();});
  document.addEventListener("district-auth-ready",()=>load().catch(error=>{console.error(error);window.DistrictLoader?.error("Não foi possível carregar a calculadora.");}),{once:true});
})();
