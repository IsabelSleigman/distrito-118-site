(() => {
  const client = window.distritoSupabase;
  let products = [];
  let materials = [];
  let components = [];
  let selectableItems = [];
  const strategyModes = new Map();

  const esc = value => String(value ?? "").replace(/[&<>'"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"}[c]));
  const materialById = id => materials.find(item => item.id === id);
  const componentsFor = id => components.filter(item => item.material_id === id);
  const formatQty = value => Number(value || 0).toLocaleString("pt-BR", { maximumFractionDigits: 2 });

  function groupedOptions(selected = "") {
    const productOptions = products
      .map(item => `<option value="product:${item.id}" ${`product:${item.id}` === selected ? "selected" : ""}>${esc(item.name)}</option>`)
      .join("");
    const materialOptions = materials
      .filter(item => componentsFor(item.id).length > 0)
      .map(item => `<option value="material:${item.id}" ${`material:${item.id}` === selected ? "selected" : ""}>${esc(item.name)}</option>`)
      .join("");
    return `${productOptions ? `<optgroup label="PRODUTOS">${productOptions}</optgroup>` : ""}${materialOptions ? `<optgroup label="MATERIAIS PRODUZÍVEIS">${materialOptions}</optgroup>` : ""}`;
  }

  function addItem(itemKey = selectableItems[0]?.key, quantity = 1) {
    if (!itemKey) return;
    const row = document.createElement("div");
    row.className = "calculator-item";
    row.innerHTML = `<div class="field"><label>Item para craftar</label><select class="calculator-selection">${groupedOptions(itemKey)}</select></div><div class="field"><label>Quantidade</label><input class="calculator-quantity" type="number" min="1" value="${quantity}"></div><button class="icon-btn danger calculator-remove" type="button" aria-label="Remover">×</button>`;
    row.querySelectorAll("select,input").forEach(el => el.addEventListener("input", calculate));
    row.querySelector(".calculator-remove").addEventListener("click", () => {
      row.remove();
      calculate();
    });
    document.getElementById("calculatorItems").appendChild(row);
    calculate();
  }

  function add(map, item, quantity) {
    if (!item || quantity <= 0) return;
    const current = map.get(item.id) || { id:item.id, name:item.name, unit:item.unit || "unidade", quantity:0 };
    current.quantity += quantity;
    map.set(item.id, current);
  }

  function getSelectedItems() {
    return [...document.querySelectorAll(".calculator-item")]
      .map(row => {
        const [type, id] = row.querySelector(".calculator-selection").value.split(":");
        return { type, id, quantity:Math.max(1, Number(row.querySelector(".calculator-quantity").value || 1)) };
      })
      .filter(item => item.id);
  }

  function collectTotals(items) {
    const selected = new Map();
    const intermediates = new Map();
    const basicTotal = new Map();
    const roots = [];

    const expandTotal = (materialId, quantity, stack = []) => {
      const material = materialById(materialId);
      if (!material || quantity <= 0) return;
      if (stack.includes(materialId)) {
        add(basicTotal, material, quantity);
        return;
      }
      const recipe = componentsFor(materialId);
      if (!recipe.length) {
        add(basicTotal, material, quantity);
        return;
      }
      add(intermediates, material, quantity);
      recipe.forEach(component => {
        expandTotal(
          component.component_material_id,
          quantity * Number(component.quantity_required || 0),
          [...stack, materialId]
        );
      });
    };

    items.forEach(item => {
      const selectedItem = item.type === "product" ? products.find(product => product.id === item.id) : materialById(item.id);
      if (selectedItem) {
        const key = `${item.type}:${item.id}`;
        const current = selected.get(key) || { id:key, name:selectedItem.name, unit:"unidade", quantity:0, type:item.type };
        current.quantity += item.quantity;
        selected.set(key, current);
      }

      if (item.type === "product") {
        const product = products.find(productItem => productItem.id === item.id);
        (product?.product_materials || []).forEach(recipe => {
          const material = materialById(recipe.material_id) || recipe.materials;
          const quantity = item.quantity * Number(recipe.quantity_required || 0);
          if (!material) return;
          roots.push({ materialId:material.id, quantity });
          expandTotal(material.id, quantity);
        });
      } else {
        roots.push({ materialId:item.id, quantity:item.quantity });
        expandTotal(item.id, item.quantity);
      }
    });

    const sort = map => [...map.values()].sort((a,b) => a.name.localeCompare(b.name, "pt-BR"));
    return {
      selected:sort(selected),
      intermediates:sort(intermediates),
      basicTotal:sort(basicTotal),
      roots
    };
  }

  function buildOperationalPlan(roots, considerStock) {
    const stock = new Map(materials.map(material => [
      material.id,
      considerStock ? Math.max(0, Number(material.stock_quantity || 0) - Number(material.reserved_quantity || 0)) : 0
    ]));
    const separate = new Map();
    const produce = new Map();
    const missing = new Map();

    const processRequirement = (materialId, quantity, stack = []) => {
      const material = materialById(materialId);
      if (!material || quantity <= 0) return;
      if (stack.includes(materialId)) {
        add(missing, material, quantity);
        return;
      }

      const recipe = componentsFor(materialId);
      if (!recipe.length) {
        if (!considerStock) {
          add(missing, material, quantity);
          return;
        }
        const available = stock.get(materialId) || 0;
        const fromStock = Math.min(available, quantity);
        if (fromStock > 0) {
          add(separate, material, fromStock);
          stock.set(materialId, available - fromStock);
        }
        const remaining = quantity - fromStock;
        if (remaining > 0) add(missing, material, remaining);
        return;
      }

      const mode = strategyModes.get(materialId) || "auto";
      let toProduce = quantity;

      if (mode === "ready") {
        if (!considerStock) {
          add(separate, material, quantity);
          return;
        }
        const available = stock.get(materialId) || 0;
        const fromStock = Math.min(available, quantity);
        if (fromStock > 0) {
          add(separate, material, fromStock);
          stock.set(materialId, available - fromStock);
        }
        const remaining = quantity - fromStock;
        if (remaining > 0) add(missing, material, remaining);
        return;
      }

      if (mode === "auto" && considerStock) {
        const available = stock.get(materialId) || 0;
        const fromStock = Math.min(available, quantity);
        if (fromStock > 0) {
          add(separate, material, fromStock);
          stock.set(materialId, available - fromStock);
        }
        toProduce = quantity - fromStock;
      }

      if (toProduce <= 0) return;
      add(produce, material, toProduce);
      recipe.forEach(component => {
        processRequirement(
          component.component_material_id,
          toProduce * Number(component.quantity_required || 0),
          [...stack, materialId]
        );
      });
    };

    roots.forEach(root => processRequirement(root.materialId, root.quantity));
    const sort = map => [...map.values()].sort((a,b) => a.name.localeCompare(b.name, "pt-BR"));
    return { separate:sort(separate), produce:sort(produce), missing:sort(missing) };
  }

  function renderList(id, items, empty) {
    document.getElementById(id).innerHTML = items.length
      ? items.map(item => `<div><span>${esc(item.name)}</span><strong>${formatQty(item.quantity)} ${esc(item.unit)}</strong></div>`).join("")
      : `<p class="calculator-empty-list">${empty}</p>`;
  }

  function renderStrategies(intermediates, considerStock) {
    const container = document.getElementById("calculatorStrategies");
    const section = document.getElementById("calculatorStrategySection");
    if (!intermediates.length) {
      section.hidden = true;
      container.innerHTML = "";
      return;
    }

    const activeIds = new Set(intermediates.map(item => item.id));
    [...strategyModes.keys()].forEach(id => {
      if (!activeIds.has(id)) strategyModes.delete(id);
    });

    section.hidden = false;
    container.innerHTML = intermediates.map(item => {
      const mode = strategyModes.get(item.id) || "auto";
      const material = materialById(item.id);
      const available = Math.max(0, Number(material?.stock_quantity || 0) - Number(material?.reserved_quantity || 0));
      return `<div class="calculator-strategy-row">
        <div class="calculator-strategy-info">
          <strong>${esc(item.name)}</strong>
          <span>${formatQty(item.quantity)} ${esc(item.unit)} necessários${considerStock ? ` · ${formatQty(available)} disponíveis` : ""}</span>
        </div>
        <div class="field calculator-strategy-field">
          <label for="strategy-${item.id}">Como obter</label>
          <select id="strategy-${item.id}" class="calculator-strategy" data-material-id="${item.id}">
            <option value="auto" ${mode === "auto" ? "selected" : ""}>Automático</option>
            <option value="ready" ${mode === "ready" ? "selected" : ""}>Usar pronta</option>
            <option value="produce" ${mode === "produce" ? "selected" : ""}>Produzir</option>
          </select>
        </div>
      </div>`;
    }).join("");

    container.querySelectorAll(".calculator-strategy").forEach(select => {
      select.addEventListener("change", event => {
        strategyModes.set(event.target.dataset.materialId, event.target.value);
        calculate();
      });
    });
  }

  function calculate() {
    const items = getSelectedItems();
    const empty = document.getElementById("calculatorEmpty");
    const planBox = document.getElementById("calculatorPlan");
    if (!items.length) {
      empty.hidden = false;
      planBox.hidden = true;
      return;
    }

    const considerStock = document.getElementById("considerStock").checked;
    const totals = collectTotals(items);
    renderStrategies(totals.intermediates, considerStock);
    const operational = buildOperationalPlan(totals.roots, considerStock);

    empty.hidden = true;
    planBox.hidden = false;
    document.getElementById("calculatorResultHint").textContent = considerStock
      ? "O sistema soma os itens, aplica a estratégia escolhida e desconta o estoque apenas uma vez."
      : "O sistema soma os itens e aplica a estratégia escolhida sem validar as quantidades em estoque.";

    renderList("calculatorSelected", totals.selected, "Nenhum item selecionado.");
    renderList("calculatorIntermediates", totals.intermediates, "Nenhum material intermediário faz parte deste cálculo.");
    renderList("calculatorBasicTotal", totals.basicTotal, "Nenhum material básico encontrado nas receitas.");
    renderList("calculatorSeparate", operational.separate, considerStock ? "Nada disponível ou marcado para separar." : "Nenhum intermediário marcado como usar pronto.");
    renderList("calculatorProduce", operational.produce, "Nenhum material intermediário precisa ser produzido.");
    renderList("calculatorMissing", operational.missing, considerStock ? "Nada falta obter." : "Materiais básicos necessários do zero.");
  }

  async function load() {
    window.DistrictLoader?.show("Carregando receitas e materiais...");
    const [productResponse, materialResponse, componentResponse] = await Promise.all([
      client.from("products").select("id,name,product_materials(material_id,quantity_required,materials(id,name,unit))").eq("is_active",true).eq("allows_order",true).order("name"),
      client.from("materials").select("id,name,unit,stock_quantity,reserved_quantity").eq("is_active",true).order("name"),
      client.from("material_components").select("material_id,component_material_id,quantity_required")
    ]);
    if (productResponse.error) throw productResponse.error;
    if (materialResponse.error) throw materialResponse.error;
    if (componentResponse.error) throw componentResponse.error;

    products = productResponse.data || [];
    materials = materialResponse.data || [];
    components = componentResponse.data || [];
    selectableItems = [
      ...products.map(item => ({ key:`product:${item.id}` })),
      ...materials.filter(item => componentsFor(item.id).length).map(item => ({ key:`material:${item.id}` }))
    ];

    document.getElementById("calculatorItems").innerHTML = "";
    if (selectableItems.length) addItem();
    else document.getElementById("calculatorEmpty").textContent = "Nenhum produto ou material produzível cadastrado.";
  }

  document.getElementById("addCalculatorItem")?.addEventListener("click", () => addItem());
  document.getElementById("considerStock")?.addEventListener("change", calculate);
  document.getElementById("clearCalculator")?.addEventListener("click", () => {
    strategyModes.clear();
    document.getElementById("calculatorItems").innerHTML = "";
    addItem();
  });

  document.addEventListener("district-auth-ready", async () => {
    try {
      await load();
    } catch (error) {
      console.error(error);
      window.DistrictLoader?.error("Não foi possível carregar a calculadora.");
      toast("Não foi possível iniciar a calculadora.");
      return;
    }
    window.DistrictLoader?.hide();
  }, { once:true });
})();
