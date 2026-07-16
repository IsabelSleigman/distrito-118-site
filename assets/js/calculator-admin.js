(() => {
  const client = window.distritoSupabase;
  let products = [], materials = [], components = [], selectableItems = [], balanceRows = [];
  const strategies = new Map();

  const esc = value => String(value ?? "").replace(/[&<>'"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"}[c]));
  const materialById = id => materials.find(item => item.id === id);
  const componentsFor = id => components.filter(item => item.material_id === id);
  const isCraftable = id => componentsFor(id).length > 0;
  const formatQty = value => Number(value || 0).toLocaleString("pt-BR", { maximumFractionDigits: 2 });

  function groupedOptions(selected = "") {
    const productOptions = products.map(item => `<option value="product:${item.id}" ${`product:${item.id}` === selected ? "selected" : ""}>${esc(item.name)}</option>`).join("");
    const materialOptions = materials.filter(item => isCraftable(item.id)).map(item => `<option value="material:${item.id}" ${`material:${item.id}` === selected ? "selected" : ""}>${esc(item.name)}</option>`).join("");
    return `${productOptions ? `<optgroup label="PRODUTOS">${productOptions}</optgroup>` : ""}${materialOptions ? `<optgroup label="MATERIAIS PRODUZÍVEIS">${materialOptions}</optgroup>` : ""}`;
  }

  function addItem(itemKey = selectableItems[0]?.key, quantity = 1) {
    if (!itemKey) return;
    const row = document.createElement("div");
    row.className = "calculator-item";
    row.innerHTML = `<div class="field"><label>Item para craftar</label><select class="calculator-selection">${groupedOptions(itemKey)}</select></div><div class="field"><label>Quantidade</label><input class="calculator-quantity" type="number" min="1" value="${quantity}"></div><button class="icon-btn danger calculator-remove" type="button" aria-label="Remover">×</button>`;
    row.querySelectorAll("select,input").forEach(el => el.addEventListener("input", calculate));
    row.querySelector(".calculator-remove").addEventListener("click", () => { row.remove(); calculate(); });
    document.getElementById("calculatorItems").appendChild(row);
    calculate();
  }

  function add(map, item, quantity, extra = {}) {
    if (!item || quantity <= 0) return;
    const current = map.get(item.id) || { id: item.id, name: item.name, unit: item.unit || "unidade", quantity: 0, ...extra };
    current.quantity += quantity;
    map.set(item.id, current);
  }

  function mapSorted(map) {
    return [...map.values()].sort((a, b) => a.name.localeCompare(b.name, "pt-BR"));
  }

  function collectOverview(items) {
    const selected = new Map();
    const directMaterials = new Map();
    const dependencies = new Map();
    const intermediatesTotal = new Map();
    const basicTotal = new Map();

    const expandFromZero = (materialId, quantity, stack = [], isRootDirect = false) => {
      const material = materialById(materialId);
      if (!material || quantity <= 0) return;
      if (stack.includes(materialId)) { add(basicTotal, material, quantity); return; }
      const recipe = componentsFor(materialId);
      if (!recipe.length) { add(basicTotal, material, quantity); return; }
      add(intermediatesTotal, material, quantity);
      if (!isRootDirect) add(dependencies, material, quantity);
      recipe.forEach(component => expandFromZero(component.component_material_id, quantity * Number(component.quantity_required || 0), [...stack, materialId], false));
    };

    items.forEach(item => {
      const selectedItem = item.type === "product" ? products.find(product => product.id === item.id) : materialById(item.id);
      if (!selectedItem) return;
      const key = `${item.type}:${item.id}`;
      const current = selected.get(key) || { id: key, name: selectedItem.name, unit: "unidade", quantity: 0, type: item.type };
      current.quantity += item.quantity;
      selected.set(key, current);

      if (item.type === "product") {
        const product = products.find(productItem => productItem.id === item.id);
        (product?.product_materials || []).forEach(recipe => {
          const material = materialById(recipe.material_id) || recipe.materials;
          expandFromZero(material.id, item.quantity * Number(recipe.quantity_required || 0), [], false);
        });
      } else {
        const material = materialById(item.id);
        add(directMaterials, material, item.quantity);
        expandFromZero(item.id, item.quantity, [], true);
      }
    });


    return {
      selected: mapSorted(selected),
      directMaterials: mapSorted(directMaterials),
      dependencies: mapSorted(dependencies),
      intermediatesTotal: mapSorted(intermediatesTotal),
      basicTotal: mapSorted(basicTotal)
    };
  }

  function buildExecutionPlan(items, considerStock) {
    const balancesByScope = { geral: new Map(), gerencia: new Map() };
    balanceRows.forEach(row => {
      const scope = row.inventory_stocks?.scope;
      if (!balancesByScope[scope]) return;
      balancesByScope[scope].set(row.material_id, Math.max(0, Number(row.quantity || 0) - Number(row.reserved_quantity || 0)));
    });
    const stocks = {
      geral: new Map(materials.map(material => [material.id, considerStock ? (balancesByScope.geral.get(material.id) || 0) : 0])),
      gerencia: new Map(materials.map(material => [material.id, considerStock ? (balancesByScope.gerencia.get(material.id) || 0) : 0]))
    };
    const separate = new Map(), produce = new Map(), missing = new Map();

    const addLocated = (map, material, quantity, scope) => {
      if (!material || quantity <= 0) return;
      const key = `${material.id}:${scope}`;
      const label = scope === "geral" ? "Estoque Geral" : "Estoque da Gerência";
      const current = map.get(key) || { id: key, name: `${material.name} · ${label}`, unit: material.unit || "unidade", quantity: 0 };
      current.quantity += quantity;
      map.set(key, current);
    };

    const takeFromStocks = (material, quantity) => {
      let remaining = quantity;
      for (const scope of ["geral", "gerencia"]) {
        if (!considerStock || remaining <= 0) break;
        const available = stocks[scope].get(material.id) || 0;
        const used = Math.min(available, remaining);
        if (used > 0) {
          addLocated(separate, material, used, scope);
          stocks[scope].set(material.id, available - used);
          remaining -= used;
        }
      }
      return remaining;
    };

    const consumeBasic = (materialId, quantity) => {
      const material = materialById(materialId);
      if (!material || quantity <= 0) return;
      const remaining = takeFromStocks(material, quantity);
      if (remaining > 0) add(missing, material, remaining);
    };

    const processMaterial = (materialId, quantity, { direct = false, stack = [] } = {}) => {
      const material = materialById(materialId);
      if (!material || quantity <= 0) return;
      if (stack.includes(materialId)) { add(missing, material, quantity); return; }
      const recipe = componentsFor(materialId);
      if (!recipe.length) { consumeBasic(materialId, quantity); return; }

      const mode = direct ? "produce" : (strategies.get(materialId) || "auto");
      let quantityToProduce = 0;
      if (mode === "produce") {
        quantityToProduce = quantity;
      } else {
        const remaining = takeFromStocks(material, quantity);
        if (remaining <= 0) return;
        if (mode === "stock") { add(missing, material, remaining); return; }
        quantityToProduce = remaining;
      }

      if (quantityToProduce <= 0) return;
      add(produce, material, quantityToProduce);
      recipe.forEach(component => processMaterial(component.component_material_id, quantityToProduce * Number(component.quantity_required || 0), { direct: false, stack: [...stack, materialId] }));
    };

    items.forEach(item => {
      if (item.type === "product") {
        const product = products.find(productItem => productItem.id === item.id);
        (product?.product_materials || []).forEach(recipe => processMaterial(recipe.material_id, item.quantity * Number(recipe.quantity_required || 0), { direct: false, stack: [] }));
      } else {
        processMaterial(item.id, item.quantity, { direct: true, stack: [] });
      }
    });
    return { separate: mapSorted(separate), produce: mapSorted(produce), missing: mapSorted(missing) };
  }

  function renderList(id, items, empty) {
    document.getElementById(id).innerHTML = items.length
      ? items.map(item => `<div><span>${esc(item.name)}</span><strong>${formatQty(item.quantity)} ${esc(item.unit)}</strong></div>`).join("")
      : `<p class="calculator-empty-list">${empty}</p>`;
  }

  function renderStrategies(dependencies, directMaterials) {
    const section = document.getElementById("calculatorStrategiesSection");
    const container = document.getElementById("calculatorStrategies");
    const directIds = new Set(directMaterials.map(item => item.id));
    const editable = dependencies.filter(item => !directIds.has(item.id) || item.quantity > 0);

    // Mantém apenas estratégias que ainda aparecem no cálculo.
    const activeIds = new Set(editable.map(item => item.id));
    [...strategies.keys()].forEach(id => { if (!activeIds.has(id)) strategies.delete(id); });

    if (!editable.length) {
      section.hidden = true;
      container.innerHTML = "";
      return;
    }

    section.hidden = false;
    container.innerHTML = editable.map(item => {
      const material = materialById(item.id);
      const generalRow = balanceRows.find(balance => balance.material_id === item.id && balance.inventory_stocks?.scope === "geral");
      const managementRow = balanceRows.find(balance => balance.material_id === item.id && balance.inventory_stocks?.scope === "gerencia");
      const generalAvailable = Math.max(0, Number(generalRow?.quantity || 0) - Number(generalRow?.reserved_quantity || 0));
      const managementAvailable = Math.max(0, Number(managementRow?.quantity || 0) - Number(managementRow?.reserved_quantity || 0));
      const available = generalAvailable + managementAvailable;
      const mode = strategies.get(item.id) || "auto";
      return `<div class="calculator-strategy-row">
        <div><strong>${esc(item.name)}</strong><span>${formatQty(item.quantity)} ${esc(item.unit)} como dependência · Geral: ${formatQty(generalAvailable)} · Gerência: ${formatQty(managementAvailable)} · Total: ${formatQty(available)}</span></div>
        <div class="field"><label>Como obter a dependência</label><select class="calculator-strategy" data-material-id="${item.id}">
          <option value="auto" ${mode === "auto" ? "selected" : ""}>Automático</option>
          <option value="stock" ${mode === "stock" ? "selected" : ""}>Usar pronta</option>
          <option value="produce" ${mode === "produce" ? "selected" : ""}>Produzir</option>
        </select></div>
      </div>`;
    }).join("");

    container.querySelectorAll(".calculator-strategy").forEach(select => {
      select.addEventListener("change", event => {
        strategies.set(event.currentTarget.dataset.materialId, event.currentTarget.value);
        calculate(false);
      });
    });
  }

  function getSelectedItems() {
    return [...document.querySelectorAll(".calculator-item")].map(row => {
      const [type, id] = row.querySelector(".calculator-selection").value.split(":");
      return { type, id, quantity: Math.max(1, Number(row.querySelector(".calculator-quantity").value || 1)) };
    }).filter(item => item.id);
  }

  function calculate(renderStrategyControls = true) {
    const items = getSelectedItems();
    const empty = document.getElementById("calculatorEmpty");
    const planBox = document.getElementById("calculatorPlan");
    if (!items.length) { empty.hidden = false; planBox.hidden = true; return; }

    const overview = collectOverview(items);
    if (renderStrategyControls) renderStrategies(overview.dependencies, overview.directMaterials);
    const consider = document.getElementById("considerStock").checked;
    const plan = buildExecutionPlan(items, consider);

    empty.hidden = true;
    planBox.hidden = false;
    document.getElementById("calculatorResultHint").textContent = consider
      ? "Itens escolhidos diretamente são produzidos. Para as dependências, o estoque é usado conforme a estratégia escolhida."
      : "Itens escolhidos diretamente são produzidos. Sem estoque, dependências em automático são produzidas e dependências em “usar pronta” ficam pendentes.";

    renderList("calculatorSelected", overview.selected, "Nenhum item selecionado.");
    renderList("calculatorDirectMaterials", overview.directMaterials, "Nenhum material foi escolhido diretamente.");
    renderList("calculatorDependencies", overview.dependencies, "Os produtos escolhidos não possuem materiais intermediários.");
    renderList("calculatorBasicTotal", overview.basicTotal, "Nenhum material básico encontrado nas receitas.");
    renderList("calculatorSeparate", plan.separate, consider ? "Nada disponível ou marcado para separar." : "Modo sem estoque.");
    renderList("calculatorProduce", plan.produce, "Nenhum material intermediário precisa ser produzido.");
    renderList("calculatorMissing", plan.missing, consider ? "Nada falta obter." : "Materiais necessários do zero.");
  }

  async function load() {
    window.DistrictLoader?.show("Carregando receitas e materiais...");
    const [productsResult, materialsResult, componentsResult, balancesResult] = await Promise.all([
      client.from("products").select("id,name,product_materials(material_id,quantity_required,materials(id,name,unit))").eq("is_active", true).eq("allows_order", true).order("name"),
      client.from("materials").select("id,name,unit,stock_quantity,reserved_quantity").eq("is_active", true).order("name"),
      client.from("material_components").select("material_id,component_material_id,quantity_required"),
      client.from("inventory_balances").select("material_id,quantity,reserved_quantity,inventory_stocks!inner(scope)")
    ]);
    if (productsResult.error) throw productsResult.error;
    if (materialsResult.error) throw materialsResult.error;
    if (componentsResult.error) throw componentsResult.error;
    if (balancesResult.error) throw balancesResult.error;
    products = productsResult.data || [];
    materials = materialsResult.data || [];
    components = componentsResult.data || [];
    balanceRows = balancesResult.data || [];
    selectableItems = [
      ...products.map(item => ({ key: `product:${item.id}` })),
      ...materials.filter(item => isCraftable(item.id)).map(item => ({ key: `material:${item.id}` }))
    ];
    document.getElementById("calculatorItems").innerHTML = "";
    if (selectableItems.length) addItem();
    else document.getElementById("calculatorEmpty").textContent = "Nenhum produto ou material produzível cadastrado.";
  }

  document.getElementById("addCalculatorItem")?.addEventListener("click", () => addItem());
  document.getElementById("considerStock")?.addEventListener("change", () => calculate(false));
  document.getElementById("clearCalculator")?.addEventListener("click", () => {
    strategies.clear();
    document.getElementById("calculatorItems").innerHTML = "";
    addItem();
  });
  document.addEventListener("district-auth-ready", async () => {
    try { await load(); }
    catch (error) {
      console.error(error);
      window.DistrictLoader?.error("Não foi possível carregar a calculadora.");
      toast("Não foi possível iniciar a calculadora.");
      return;
    }
    window.DistrictLoader?.hide();
  }, { once: true });
})();
