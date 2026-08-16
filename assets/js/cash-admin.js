(() => {
  const client = window.distritoSupabase;
  const money = value => Number(value || 0).toLocaleString("pt-BR", { style: "currency", currency: "BRL", maximumFractionDigits: 0 });
  const esc = value => String(value ?? "").replace(/[&<>'"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"}[c]));
  const paymentLabel = type => type === "dirty" ? "Dinheiro Sujo" : type === "clean" ? "Dinheiro" : "—";
  const selectedPendingIds = () => [...document.querySelectorAll(".vault-order-check:checked")].map(input => input.value);
  const normalize = value => String(value || "").normalize("NFD").replace(/[\u0300-\u036f]/g, "").trim().toLowerCase();
  let pendingOrdersById = new Map();

  function classifyMoneyMaterial(name) {
    const value = normalize(name);
    if (!value.includes("dinheiro")) return null;
    if (value.includes("sujo")) return "dirty";
    // O cadastro atual é exatamente "Dinheiro", sem a palavra "limpo".
    return "clean";
  }

  async function loadCash() {
    const tbody = document.getElementById("cashTable");
    const pendingBody = document.getElementById("vaultPendingTable");
    tbody.innerHTML = `<tr><td colspan="6" class="loading-row">Carregando movimentações...</td></tr>`;
    pendingBody.innerHTML = `<tr><td colspan="6" class="loading-row">Carregando pendências...</td></tr>`;

    const [movementResult, orderResult, itemResult, stockResult, balanceResult] = await Promise.all([
      client.from("cash_movements").select("id,movement_type,description,amount,source,payment_type,created_at,orders(code)").order("created_at", { ascending: false }),
      client.from("orders").select("id,code,customer_name,cnpj_name,payment_type,net_amount,final_amount,vault_deposited_at,vault_deposited_by,cash_posted_at,status,created_at").eq("status", "delivered").is("deleted_at", null).not("cash_posted_at", "is", null).order("created_at", { ascending: false }),
      client.from("inventory_catalog").select("item_id,name").eq("is_active", true),
      client.from("inventory_stocks").select("id,scope,name").in("scope", ["geral", "gerencia"]),
      client.from("inventory_all_balances").select("stock_id,item_id,quantity")
    ]);

    const error = movementResult.error || orderResult.error || itemResult.error || stockResult.error || balanceResult.error;
    if (error) {
      console.error(error);
      tbody.innerHTML = `<tr><td colspan="6" class="empty">Não foi possível carregar o caixa.</td></tr>`;
      pendingBody.innerHTML = `<tr><td colspan="6" class="empty">Não foi possível carregar os repasses.</td></tr>`;
      return;
    }

    const movements = movementResult.data || [];
    const orders = orderResult.data || [];
    const items = itemResult.data || [];
    const stocks = stockResult.data || [];
    const balances = balanceResult.data || [];
    const itemTypeById = new Map(items.map(item => [item.item_id, classifyMoneyMaterial(item.name)]));
    const stockById = new Map(stocks.map(stock => [stock.id, stock]));
    const totals = {
      geral: { clean: 0, dirty: 0 },
      gerencia: { clean: 0, dirty: 0 }
    };

    balances.forEach(balance => {
      const type = itemTypeById.get(balance.item_id);
      const scope = stockById.get(balance.stock_id)?.scope;
      if (type && totals[scope]) totals[scope][type] += Number(balance.quantity || 0);
    });

    const vaultClean = totals.geral.clean + totals.gerencia.clean;
    const vaultDirty = totals.geral.dirty + totals.gerencia.dirty;
    const vaultTotal = vaultClean + vaultDirty;
    const pending = orders.filter(order => !order.vault_deposited_at);
    pendingOrdersById = new Map(pending.map(order => [order.id, order]));
    const pendingTotal = pending.reduce((sum, order) => sum + Number(order.net_amount || 0), 0);
    const dirtyPending = pending.filter(order => order.payment_type === "dirty").reduce((sum, order) => sum + Number(order.net_amount || 0), 0);
    const cleanPending = pending.filter(order => order.payment_type === "clean").reduce((sum, order) => sum + Number(order.net_amount || 0), 0);
    const totalFamily = vaultTotal + pendingTotal;

    document.getElementById("cashBalance").textContent = money(totalFamily);
    document.getElementById("vaultPendingTotal").textContent = money(pendingTotal);
    document.getElementById("vaultDepositedTotal").textContent = money(vaultTotal);
    document.getElementById("vaultPendingBreakdown").textContent = `${money(cleanPending)} Dinheiro · ${money(dirtyPending)} Dinheiro Sujo`;
    document.getElementById("vaultPendingCount").textContent = `${pending.length} pedido${pending.length === 1 ? "" : "s"} aguardando repasse`;
    document.getElementById("vaultAllBreakdown").textContent = `${money(vaultClean)} Dinheiro · ${money(vaultDirty)} Dinheiro Sujo`;
    document.getElementById("vaultGeneralBreakdown").textContent = `${money(totals.geral.clean)} Dinheiro · ${money(totals.geral.dirty)} Dinheiro Sujo`;
    document.getElementById("vaultManagementBreakdown").textContent = `${money(totals.gerencia.clean)} Dinheiro · ${money(totals.gerencia.dirty)} Dinheiro Sujo`;

    pendingBody.innerHTML = pending.map(order => `<tr>
      <td><input class="vault-order-check" type="checkbox" value="${esc(order.id)}" aria-label="Selecionar ${esc(order.code)}"></td>
      <td><strong>${esc(order.code)}</strong><div class="muted-caption">${esc(order.cnpj_name || order.customer_name || "Cliente")}</div></td>
      <td><span class="badge ${order.payment_type === "dirty" ? "warning" : "green"}">${paymentLabel(order.payment_type)}</span></td>
      <td>${money(order.net_amount)}</td>
      <td>${new Date(order.created_at).toLocaleDateString("pt-BR")}</td>
      <td><button class="icon-btn deposit-one" type="button" data-id="${esc(order.id)}">Depositar</button></td>
    </tr>`).join("") || `<tr><td colspan="6" class="empty">Nenhum valor aguardando depósito.</td></tr>`;

    tbody.innerHTML = movements.map(movement => `<tr>
      <td>${new Date(movement.created_at).toLocaleString("pt-BR")}</td>
      <td>${esc(movement.description)}${movement.orders?.code ? `<div class="muted-caption">${esc(movement.orders.code)}</div>` : ""}</td>
      <td><span class="badge ${movement.movement_type === "entry" ? "green" : "danger"}">${movement.movement_type === "entry" ? "Entrada" : "Saída"}</span></td>
      <td>${paymentLabel(movement.payment_type)}</td>
      <td>${esc(movement.source || "manual")}</td>
      <td><strong>${movement.movement_type === "exit" ? "− " : "+ "}${money(movement.amount)}</strong></td>
    </tr>`).join("") || `<tr><td colspan="6" class="empty">Nenhuma movimentação registrada.</td></tr>`;

    updateSelectionSummary();
  }

  function selectedSummary(ids = selectedPendingIds()) {
    return ids.reduce((summary, id) => {
      const order = pendingOrdersById.get(id);
      if (!order) return summary;
      const amount = Number(order.net_amount || 0);
      summary.count += 1;
      summary.total += amount;
      if (order.payment_type === "dirty") summary.dirty += amount;
      else summary.clean += amount;
      return summary;
    }, { count: 0, clean: 0, dirty: 0, total: 0 });
  }

  function updateSelectionSummary() {
    const summary = selectedSummary();
    const label = document.getElementById("selectedVaultCount");
    const breakdown = document.getElementById("selectedVaultBreakdown");
    const button = document.getElementById("depositSelectedButton");

    if (label) {
      label.textContent = summary.count
        ? `${summary.count} pedido${summary.count === 1 ? "" : "s"} selecionado${summary.count === 1 ? "" : "s"}`
        : "Selecione os pedidos que já foram colocados no baú";
    }
    if (breakdown) {
      breakdown.innerHTML = summary.count
        ? `<span>${money(summary.clean)} Dinheiro</span><span>${money(summary.dirty)} Dinheiro Sujo</span><strong>Total: ${money(summary.total)}</strong>`
        : "";
      breakdown.hidden = summary.count === 0;
    }
    if (button) button.disabled = summary.count === 0;
  }

  function confirmDeposit(ids) {
    const summary = selectedSummary(ids);
    if (!summary.count) return false;
    return window.confirm([
      `Confirmar depósito de ${summary.count} pedido${summary.count === 1 ? "" : "s"}?`,
      "",
      `Dinheiro: ${money(summary.clean)}`,
      `Dinheiro Sujo: ${money(summary.dirty)}`,
      `Total: ${money(summary.total)}`
    ].join("\n"));
  }

  async function deposit(ids) {
    if (!ids.length || !confirmDeposit(ids)) return;
    const button = document.getElementById("depositSelectedButton");
    const oldText = button?.textContent || "Confirmar depósito selecionado";
    if (button) {
      button.disabled = true;
      button.textContent = "Confirmando...";
    }
    try {
      const { data, error } = await client.rpc("mark_orders_vault_deposited", { p_order_ids: ids });
      if (error) throw error;
      toast(`${data?.orders_count || ids.length} repasse(s) confirmado(s) no baú.`);
      await loadCash();
    } catch (error) {
      console.error(error);
      toast(error.message || "Não foi possível confirmar o depósito.");
    } finally {
      if (button) {
        button.disabled = false;
        button.textContent = oldText;
      }
    }
  }

  function bindForm() {
    const form = document.getElementById("cashForm");
    form?.addEventListener("submit", async event => {
      event.preventDefault();
      const button = form.querySelector('button[type="submit"]');
      button.disabled = true;
      button.textContent = "Registrando...";
      try {
        const { error } = await client.rpc("register_cash_inventory_movement", {
          p_stock_scope: document.getElementById("cashStockScope").value,
          p_payment_type: document.getElementById("cashPaymentType").value,
          p_movement_type: document.getElementById("cashType").value,
          p_amount: Number(document.getElementById("cashAmount").value),
          p_description: document.getElementById("cashDescription").value.trim()
        });
        if (error) throw error;
        form.reset();
        toast("Caixa e baú atualizados juntos.");
        await loadCash();
      } catch (error) {
        console.error(error);
        toast(error.message || "Não foi possível registrar a movimentação.");
      } finally {
        button.disabled = false;
        button.textContent = "Registrar";
      }
    });

    document.getElementById("vaultPendingTable")?.addEventListener("change", event => {
      if (event.target.matches(".vault-order-check")) updateSelectionSummary();
    });
    document.getElementById("vaultPendingTable")?.addEventListener("click", event => {
      const button = event.target.closest(".deposit-one");
      if (button) deposit([button.dataset.id]);
    });
    document.getElementById("selectAllVault")?.addEventListener("change", event => {
      document.querySelectorAll(".vault-order-check").forEach(input => { input.checked = event.target.checked; });
      updateSelectionSummary();
    });
    document.getElementById("depositSelectedButton")?.addEventListener("click", () => deposit(selectedPendingIds()));
  }

  document.addEventListener("district-auth-ready", async () => { bindForm(); await loadCash(); }, { once: true });
})();
