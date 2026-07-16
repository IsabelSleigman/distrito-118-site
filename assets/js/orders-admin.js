(() => {
  const client = window.distritoSupabase;
  const tiers = ["cpf", "cnpj", "alianca", "parceria"];
  const statuses = [
    ["pending", "Aguardando análise"], ["under_review", "Em análise"], ["accepted", "Aceita"],
    ["waiting_materials", "Separação de materiais"], ["in_production", "Em produção"], ["ready", "Pronta"],
    ["awaiting_delivery", "Aguardando entrega"], ["delivered", "Entregue"], ["rejected", "Recusada"], ["cancelled", "Cancelada"]
  ];

  let orderProducts = [];
  let materials = [];
  let materialComponents = [];
  let inventoryBalances = [];
  let currentEditingOrder = null;

  const money = value => Number(value || 0).toLocaleString("pt-BR", { style: "currency", currency: "BRL", maximumFractionDigits: 0 });
  const esc = value => String(value ?? "").replace(/[&<>'"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"}[c]));
  const statusLabel = value => statuses.find(([key]) => key === value)?.[1] || value;
  const statusClass = value => `status-${value || "unknown"}`;
  const formatDateTime = value => new Date(value).toLocaleString("pt-BR");
  const priceFor = (product, tier) => product?.product_prices?.find(price => price.customer_type === tier);
  const materialById = id => materials.find(item => item.id === id);
  const componentsFor = id => materialComponents.filter(item => item.material_id === id);

  function uniqueHistory(entries = []) {
    const sorted = [...entries].sort((a, b) => new Date(a.created_at) - new Date(b.created_at));
    return sorted.filter((entry, index) => !index || sorted[index - 1].status !== entry.status);
  }

  function buildProductionPlan(order) {
    const balancesByScope = { geral: new Map(), gerencia: new Map() };
    inventoryBalances.forEach(row => {
      const scope = row.inventory_stocks?.scope;
      if (!balancesByScope[scope]) return;
      balancesByScope[scope].set(row.material_id, Math.max(0, Number(row.quantity || 0) - Number(row.reserved_quantity || 0)));
    });
    const stocks = {
      geral: new Map(materials.map(item => [item.id, balancesByScope.geral.get(item.id) || 0])),
      gerencia: new Map(materials.map(item => [item.id, balancesByScope.gerencia.get(item.id) || 0]))
    };
    const direct = new Map(), separate = new Map(), produce = new Map(), missing = new Map();
    const add = (map, material, amount, keySuffix = "", displayName = null) => {
      if (!material || amount <= 0) return;
      const key = `${material.id}${keySuffix}`;
      const current = map.get(key) || { id: key, name: displayName || material.name, unit: material.unit || "unidade", quantity: 0 };
      current.quantity += amount; map.set(key, current);
    };
    const take = (material, quantity) => {
      let remaining = quantity;
      for (const scope of ["geral", "gerencia"]) {
        if (remaining <= 0) break;
        const available = stocks[scope].get(material.id) || 0;
        const used = Math.min(available, remaining);
        if (used > 0) {
          const label = scope === "geral" ? "Estoque Geral" : "Estoque da Gerência";
          add(separate, material, used, `:${scope}`, `${material.name} · ${label}`);
          stocks[scope].set(material.id, available - used);
          remaining -= used;
        }
      }
      return remaining;
    };
    const consume = (materialId, quantity, stack = []) => {
      const material = materialById(materialId);
      if (!material || quantity <= 0) return;
      if (stack.includes(materialId)) { add(missing, material, quantity); return; }
      const remaining = take(material, quantity);
      if (remaining <= 0) return;
      const recipe = componentsFor(materialId);
      if (!recipe.length) { add(missing, material, remaining); return; }
      add(produce, material, remaining);
      recipe.forEach(component => consume(component.component_material_id, remaining * Number(component.quantity_required || 0), [...stack, materialId]));
    };
    for (const item of order.order_items || []) {
      for (const recipe of item.products?.product_materials || []) {
        const material = materialById(recipe.material_id) || recipe.materials;
        if (!material) continue;
        const quantity = Number(item.quantity || 0) * Number(recipe.quantity_required || 0);
        add(direct, material, quantity); consume(material.id, quantity);
      }
    }
    const sort = map => [...map.values()].sort((a,b) => a.name.localeCompare(b.name,"pt-BR"));
    return { direct: sort(direct), separate: sort(separate), produce: sort(produce), missing: sort(missing) };
  }

  function planList(title, icon, items, emptyText, className = "") {
    return `<section class="production-plan-block ${className}"><div class="production-plan-title"><span>${icon}</span><div><h4>${title}</h4><p>${items.length ? `${items.length} item(ns)` : emptyText}</p></div></div>${items.length ? `<div class="production-plan-list">${items.map(item => `<div><span>${esc(item.name)}</span><strong>${item.quantity} ${esc(item.unit)}</strong></div>`).join("")}</div>` : ""}</section>`;
  }

  async function updateStatus(orderId, status, note) {
    const { data, error } = await client.rpc("update_order_status_v2", { p_order_id: orderId, p_status: status, p_note: String(note || "").trim() || null });
    if (error) throw error;
    return data;
  }

  function openDetails(order) {
    const modal = document.getElementById("orderDetailsModal");
    const content = document.getElementById("orderDetailsContent");
    const history = uniqueHistory(order.order_status_history || []);
    const plan = buildProductionPlan(order);

    content.innerHTML = `
      <div class="section-head order-modal-head"><div><span class="eyebrow">Encomenda</span><div class="order-code-line"><h2>${esc(order.code)}</h2><button class="icon-btn copy-order-code" type="button">Copiar</button></div></div><span class="badge ${statusClass(order.status)}">${esc(statusLabel(order.status))}</span></div>
      <div class="status-manager" data-order-id="${esc(order.id)}"><div><span class="status-manager-label">Atualizar andamento</span><p>A mudança será registrada uma única vez na linha do tempo.</p></div><div class="status-manager-fields"><select id="detailOrderStatus">${statuses.map(([key,label]) => `<option value="${key}" ${key === order.status ? "selected" : ""}>${label}</option>`).join("")}</select><input id="detailStatusNote" placeholder="Observação opcional"><button id="saveOrderStatus" class="btn primary small" type="button">Salvar status</button></div><p id="statusUpdateError" class="status-update-error" hidden></p></div>
      <div class="order-detail-grid"><div class="summary-list">
        <div class="summary-row"><span>Cliente</span><strong>${esc(order.cnpj_name || order.customer_name)}</strong></div>
        <div class="summary-row"><span>Registrado por</span><strong>${esc(order.received_by_profile?.name || "—")}</strong></div>
        <div class="summary-row"><span>Ajudou na produção</span><strong>${esc(order.production_helpers || "Sem colaborador extra")}</strong></div>
        <div class="summary-row"><span>Tabela aplicada</span><strong>${esc(window.DistrictPricing.label(order.pricing_tier || order.customer_type))}</strong></div><div class="summary-row"><span>Origem dos materiais</span><strong>Geral primeiro; Gerência para completar</strong></div>
        <div class="summary-row"><span>Passaporte</span><strong>${esc(order.passport || "—")}</strong></div>
        <div class="summary-row"><span>Telefone</span><strong>${esc(order.phone || "—")}</strong></div>
        ${(order.order_items || []).map(item => `<div class="summary-row"><span>${item.quantity}x ${esc(item.product_name)}</span><strong>${money(item.subtotal)}</strong></div>`).join("")}
        <div class="summary-row"><span>Pagamento</span><strong>${order.payment_type === "dirty" ? "Dinheiro sujo" : "Dinheiro limpo"}</strong></div>
        <div class="summary-row"><span>Valor limpo</span><strong>${money(order.clean_amount ?? order.total_amount)}</strong></div>
        <div class="summary-row"><span>Valor sujo (+30%)</span><strong>${money(order.dirty_amount ?? Number(order.total_amount || 0) * 1.3)}</strong></div>
        <div class="summary-row"><span>Comissão (20%)</span><strong>${money(order.commission_amount)}</strong></div>
        <div class="summary-row"><span>Entrada líquida</span><strong>${money(order.net_amount)}</strong></div>
        <div class="summary-row summary-total"><span>Total da venda</span><strong>${money(order.final_amount ?? order.total_amount)}</strong></div>
        ${order.notes ? `<div class="order-note"><strong>Observação</strong><p>${esc(order.notes)}</p></div>` : ""}
      </div><div><h3 class="timeline-title">Linha do tempo</h3><div class="order-timeline">${history.map((entry,index) => `<div class="timeline-entry ${statusClass(entry.status)} ${index === history.length - 1 ? "current" : ""}"><span class="timeline-dot"></span><div><strong>${esc(statusLabel(entry.status))}</strong><time>${formatDateTime(entry.created_at)}</time>${entry.note ? `<p>${esc(entry.note)}</p>` : ""}</div></div>`).join("") || `<div class="empty">Nenhuma atualização registrada.</div>`}</div></div></div>
      <section class="materials-required-section"><div class="section-head"><div><span class="eyebrow">Plano de produção</span><h3>O que a equipe precisa fazer</h3><p>O cálculo usa o estoque disponível e abre automaticamente as receitas dos materiais intermediários.</p></div></div><div class="production-plan-grid">
        ${planList("Separar do estoque", "✓", plan.separate, "Nada disponível para separar", "plan-separate")}
        ${planList("Produzir", "⚙", plan.produce, "Nenhum material intermediário precisa ser produzido", "plan-produce")}
        ${planList("Ainda falta obter", "!", plan.missing, "Todos os materiais básicos estão disponíveis", "plan-missing")}
      </div></section>`;

    content.querySelector(".copy-order-code")?.addEventListener("click", async () => { await navigator.clipboard.writeText(order.code); toast("Código copiado."); });
    modal.classList.add("open");
  }

  async function loadReferences() {
    const [productsResult, materialsResult, componentsResult, balancesResult] = await Promise.all([
      client.from("products").select(`id,name,is_active,allows_order,product_prices(customer_type,unit_price,wholesale_minimum,wholesale_price)`).eq("is_active", true).eq("allows_order", true).order("name"),
      client.from("materials").select("id,name,unit,stock_quantity,reserved_quantity,is_active").eq("is_active", true).order("name"),
      client.from("material_components").select("material_id,component_material_id,quantity_required"),
      client.from("inventory_balances").select("material_id,quantity,reserved_quantity,inventory_stocks!inner(scope)")
    ]);
    if (productsResult.error) throw productsResult.error;
    orderProducts = productsResult.data || [];
    materials = materialsResult.error ? [] : (materialsResult.data || []);
    materialComponents = componentsResult.error ? [] : (componentsResult.data || []);
    inventoryBalances = balancesResult.error ? [] : (balancesResult.data || []);

  }

  const internalProductOptions = () => orderProducts.map(product => `<option value="${product.id}">${esc(product.name)}</option>`).join("");

  function addInternalItem(productId = orderProducts[0]?.id) {
    if (!productId) return;
    const row = document.createElement("div");
    row.className = "order-item internal-order-item";
    row.innerHTML = `<div class="field"><label>Produto</label><select class="internal-order-product">${internalProductOptions()}</select></div><div class="field quantity-field"><label>Quantidade</label><input class="internal-order-qty" type="number" min="1" value="1"></div><button type="button" class="icon-btn danger remove-internal-item" aria-label="Remover produto">×</button>`;
    row.querySelector("select").value = productId;
    row.querySelectorAll("select,input").forEach(element => element.addEventListener("input", updateInternalTotals));
    row.querySelector(".remove-internal-item").addEventListener("click", () => { row.remove(); updateInternalTotals(); });
    document.getElementById("internalOrderItems").appendChild(row);
    updateInternalTotals();
  }

  function updateInternalTotals() {
    const tier = document.getElementById("internalPricingTier")?.value || "cpf";
    const payment = document.getElementById("internalPaymentType")?.value || "clean";
    let clean = 0;
    document.querySelectorAll("#internalOrderItems .order-item").forEach(row => {
      const product = orderProducts.find(item => item.id === row.querySelector(".internal-order-product").value);
      const quantity = Math.max(1, Number(row.querySelector(".internal-order-qty").value || 1));
      clean += window.DistrictPricing.apply(priceFor(product, tier), quantity).subtotal;
    });
    const dirty = Math.round(clean * 1.3);
    const final = payment === "dirty" ? dirty : clean;
    document.getElementById("internalCleanTotal").textContent = money(clean);
    document.getElementById("internalDirtyTotal").textContent = money(dirty);
    document.getElementById("internalFinalTotal").textContent = money(final);
    document.getElementById("internalCommissionTotal").textContent = money(final * .2);
    document.getElementById("internalNetTotal").textContent = money(final * .8);
  }

  function closeInternalOrder() {
    document.getElementById("internalOrderModal").classList.remove("open");
    currentEditingOrder = null;
  }

  function openInternalOrder(order = null) {
    const form = document.getElementById("internalOrderForm");
    form.reset();
    document.getElementById("internalOrderItems").innerHTML = "";
    document.getElementById("internalOrderError").hidden = true;
    currentEditingOrder = order;
    document.getElementById("internalOrderId").value = order?.id || "";
    document.getElementById("internalOrderModalTitle").textContent = order ? `Editar ${order.code}` : "Nova encomenda";
    document.getElementById("internalOrderEyebrow").textContent = order ? "Alteração interna" : "Registro interno";
    document.getElementById("saveInternalOrder").textContent = order ? "Salvar alterações" : "Registrar encomenda";

    if (order) {
      document.getElementById("internalCustomerType").value = order.customer_type || "cpf";
      document.getElementById("internalPricingTier").value = order.pricing_tier || order.customer_type || "cpf";
      document.getElementById("internalCustomerName").value = order.customer_name || "";
      document.getElementById("internalCnpjName").value = order.cnpj_name || "";
      document.getElementById("internalPassport").value = order.passport || "";
      document.getElementById("internalPhone").value = order.phone || "";
      document.getElementById("internalPaymentType").value = order.payment_type || "clean";
            document.getElementById("internalProductionHelpers").value = order.production_helpers || "";
      document.getElementById("internalNotes").value = order.notes || "";
      const isCnpj = order.customer_type === "cnpj";
      document.getElementById("internalCnpjField").style.display = isCnpj ? "flex" : "none";
      document.getElementById("internalCnpjName").required = isCnpj;
      (order.order_items || []).forEach(item => addInternalItem(item.product_id, item.quantity));
    } else {
      document.getElementById("internalCnpjField").style.display = "none";
      document.getElementById("internalCnpjName").required = false;
      addInternalItem();
    }
    updateInternalTotals();
    document.getElementById("internalOrderModal").classList.add("open");
  }

  async function saveInternalOrder(event) {
    event.preventDefault();
    const rows = [...document.querySelectorAll("#internalOrderItems .order-item")];
    const errorBox = document.getElementById("internalOrderError");
    const button = document.getElementById("saveInternalOrder");
    if (!rows.length) return toast("Adicione pelo menos um produto.");
    button.disabled = true; button.textContent = "Registrando..."; errorBox.hidden = true;
    try {
      const payload = {
        input_customer_type: document.getElementById("internalCustomerType").value,
        input_customer_name: document.getElementById("internalCustomerName").value.trim(),
        input_cnpj_name: document.getElementById("internalCnpjName").value.trim() || null,
        input_passport: document.getElementById("internalPassport").value.trim(),
        input_phone: document.getElementById("internalPhone").value.trim() || null,
        input_notes: document.getElementById("internalNotes").value.trim() || null,
        input_payment_type: document.getElementById("internalPaymentType").value,
        input_pricing_tier: document.getElementById("internalPricingTier").value,
        input_production_helpers: document.getElementById("internalProductionHelpers").value.trim() || null,
        input_items: rows.map(row => ({ product_id: row.querySelector(".internal-order-product").value, quantity: Math.max(1, Number(row.querySelector(".internal-order-qty").value || 1)) }))
      };
      const editing = Boolean(currentEditingOrder);
      const rpcName = editing ? "update_internal_order" : "create_internal_order";
      if (editing) payload.input_order_id = currentEditingOrder.id;
      const { data, error } = await client.rpc(rpcName, payload);
      if (error) throw error;
      const orderId = data.id || currentEditingOrder?.id;
      const code = data.code || currentEditingOrder?.code || "";
      closeInternalOrder();
      toast(editing ? `Encomenda ${code} atualizada.` : `Encomenda ${code} registrada. Código pronto para consulta.`);
      await load();
    } catch (error) { console.error(error); errorBox.textContent = error.message || "Não foi possível registrar a encomenda."; errorBox.hidden = false; }
    finally { button.disabled = false; button.textContent = currentEditingOrder ? "Salvar alterações" : "Registrar encomenda"; }
  }

  async function load() {
    const tbody = document.getElementById("ordersTable");
    tbody.innerHTML = `<tr><td colspan="8" class="loading-row">Carregando encomendas...</td></tr>`;
    const { data, error } = await client.from("orders").select(`
      id,code,customer_type,customer_name,cnpj_name,passport,phone,notes,pricing_tier,total_amount,payment_type,clean_amount,dirty_amount,final_amount,commission_rate,commission_amount,net_amount,status,created_at,deleted_at,production_helpers,stock_scope,
      received_by_profile:profiles!orders_received_by_fkey(name,email),
      order_items(quantity,product_name,unit_price,subtotal,product_id,products(product_materials(material_id,quantity_required,materials(id,name,unit)))),
      order_status_history(status,note,created_at)
    `).is("deleted_at", null).order("created_at", { ascending: false });
    if (error) { console.error(error); tbody.innerHTML = `<tr><td colspan="8" class="empty">Não foi possível carregar as encomendas.</td></tr>`; return; }

    tbody.innerHTML = (data || []).map(order => `<tr><td><strong>${esc(order.code)}</strong></td><td>${esc(order.cnpj_name || order.customer_name)}<div class="muted-caption">${order.customer_type.toUpperCase()}${order.production_helpers ? ` · com ${esc(order.production_helpers)}` : ""}</div></td><td>${(order.order_items || []).reduce((sum,item) => sum + item.quantity, 0)}</td><td>${money(order.final_amount ?? order.total_amount)}<div class="muted-caption">${order.payment_type === "dirty" ? "Sujo" : "Limpo"}</div></td><td><select class="pricing-tier" data-id="${order.id}">${tiers.map(tier => `<option value="${tier}" ${tier === (order.pricing_tier || order.customer_type) ? "selected" : ""}>${window.DistrictPricing.label(tier)}</option>`).join("")}</select></td><td><span class="badge ${statusClass(order.status)}">${esc(statusLabel(order.status))}</span></td><td>${new Date(order.created_at).toLocaleDateString("pt-BR")}</td><td><div class="table-actions"><button class="icon-btn edit-order" data-id="${order.id}">Editar</button><button class="icon-btn view-order" data-id="${order.id}">Detalhes</button><button class="icon-btn danger delete-order" data-id="${order.id}" data-code="${esc(order.code)}">Excluir</button></div></td></tr>`).join("") || `<tr><td colspan="8" class="empty">Nenhuma encomenda registrada.</td></tr>`;

    document.querySelectorAll(".pricing-tier").forEach(element => element.addEventListener("change", async () => {
      element.disabled = true;
      const { error: pricingError } = await client.rpc("recalculate_order_pricing", { input_order_id: element.dataset.id, input_pricing_tier: element.value });
      element.disabled = false;
      if (pricingError) { toast(pricingError.message || "Erro ao recalcular preço."); return load(); }
      toast(`Tabela ${window.DistrictPricing.label(element.value)} aplicada.`); await load();
    }));
    document.querySelectorAll(".edit-order").forEach(element => element.addEventListener("click", () => {
      const order = data.find(item => item.id === element.dataset.id);
      if (["delivered", "cancelled"].includes(order?.status)) return toast("Encomendas entregues ou canceladas não podem ser editadas.");
      openInternalOrder(order);
    }));
    document.querySelectorAll(".view-order").forEach(element => element.addEventListener("click", () => openDetails(data.find(item => item.id === element.dataset.id))));
    document.querySelectorAll(".delete-order").forEach(element => element.addEventListener("click", async () => {
      if (!confirm(`Excluir a encomenda ${element.dataset.code}?`)) return;
      const { error: deleteError } = await client.rpc("soft_delete_order", { input_order_id: element.dataset.id });
      if (deleteError) return toast(deleteError.message || "Não foi possível excluir.");
      toast("Encomenda excluída do painel."); await load();
    }));
  }

  document.getElementById("orderDetailsModal")?.addEventListener("click", async event => {
    const button = event.target.closest("#saveOrderStatus"); if (!button) return;
    const manager = button.closest(".status-manager"); const errorBox = document.getElementById("statusUpdateError");
    button.disabled = true; button.textContent = "Salvando..."; errorBox.hidden = true;
    try { const status = document.getElementById("detailOrderStatus").value; await updateStatus(manager.dataset.orderId, status, document.getElementById("detailStatusNote").value); toast(`Status alterado para ${statusLabel(status)}.`); document.getElementById("orderDetailsModal").classList.remove("open"); await load(); }
    catch (error) { errorBox.textContent = error.message || "Erro ao atualizar status."; errorBox.hidden = false; }
    finally { button.disabled = false; button.textContent = "Salvar status"; }
  });

  document.getElementById("closeOrderDetails")?.addEventListener("click", () => document.getElementById("orderDetailsModal").classList.remove("open"));
  document.getElementById("closeInternalOrder")?.addEventListener("click", closeInternalOrder);
  document.getElementById("cancelInternalOrder")?.addEventListener("click", closeInternalOrder);
  document.getElementById("newInternalOrderButton")?.addEventListener("click", openInternalOrder);
  document.getElementById("addInternalOrderItem")?.addEventListener("click", () => addInternalItem());
  document.getElementById("internalOrderForm")?.addEventListener("submit", saveInternalOrder);
  document.getElementById("internalCustomerType")?.addEventListener("change", event => {
    const cnpj = event.target.value === "cnpj";
    document.getElementById("internalCnpjField").style.display = cnpj ? "flex" : "none";
    document.getElementById("internalCnpjName").required = cnpj;
    if (["cpf","cnpj"].includes(document.getElementById("internalPricingTier").value)) document.getElementById("internalPricingTier").value = event.target.value;
    updateInternalTotals();
  });
  document.getElementById("internalPricingTier")?.addEventListener("change", updateInternalTotals);
  document.getElementById("internalPaymentType")?.addEventListener("change", updateInternalTotals);

  document.addEventListener("district-auth-ready", async () => {
    try { await loadReferences(); await load(); }
    catch (error) { console.error(error); toast("Erro ao iniciar encomendas."); }
  }, { once: true });
})();
