(() => {
  const client = window.distritoSupabase;
  const money = value => Number(value || 0).toLocaleString("pt-BR", { style: "currency", currency: "BRL", maximumFractionDigits: 0 });
  const esc = value => String(value ?? "").replace(/[&<>'"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"}[c]));
  const paymentLabel = type => type === "dirty" ? "Sujo" : type === "clean" ? "Limpo" : "—";
  const selectedPendingIds = () => [...document.querySelectorAll(".vault-order-check:checked")].map(input => input.value);

  async function loadCash() {
    const tbody = document.getElementById("cashTable");
    const pendingBody = document.getElementById("vaultPendingTable");
    tbody.innerHTML = `<tr><td colspan="6" class="loading-row">Carregando movimentações...</td></tr>`;
    pendingBody.innerHTML = `<tr><td colspan="6" class="loading-row">Carregando pendências...</td></tr>`;

    const [{ data: movements, error: movementError }, { data: deliveredOrders, error: orderError }] = await Promise.all([
      client.from("cash_movements").select("id,movement_type,description,amount,source,payment_type,created_at,orders(code)").order("created_at", { ascending: false }),
      client.from("orders").select("id,code,customer_name,cnpj_name,payment_type,net_amount,final_amount,vault_deposited_at,vault_deposited_by,cash_posted_at,status,created_at").eq("status", "delivered").is("deleted_at", null).not("cash_posted_at", "is", null).order("created_at", { ascending: false })
    ]);

    if (movementError || orderError) {
      console.error(movementError || orderError);
      tbody.innerHTML = `<tr><td colspan="6" class="empty">Não foi possível carregar o caixa.</td></tr>`;
      pendingBody.innerHTML = `<tr><td colspan="6" class="empty">Não foi possível carregar os repasses.</td></tr>`;
      return;
    }

    const totalFamily = (movements || [])
      .filter(item => item.source !== "vault")
      .reduce((sum, item) => sum + (item.movement_type === "entry" ? Number(item.amount) : -Number(item.amount)), 0);
    const pending = (deliveredOrders || []).filter(order => !order.vault_deposited_at);
    const deposited = (deliveredOrders || []).filter(order => order.vault_deposited_at);
    const pendingTotal = pending.reduce((sum, order) => sum + Number(order.net_amount || 0), 0);
    const depositedTotal = deposited.reduce((sum, order) => sum + Number(order.net_amount || 0), 0);
    const dirtyPending = pending.filter(order => order.payment_type === "dirty").reduce((sum, order) => sum + Number(order.net_amount || 0), 0);
    const cleanPending = pending.filter(order => order.payment_type === "clean").reduce((sum, order) => sum + Number(order.net_amount || 0), 0);

    document.getElementById("cashBalance").textContent = money(totalFamily);
    document.getElementById("vaultPendingTotal").textContent = money(pendingTotal);
    document.getElementById("vaultDepositedTotal").textContent = money(depositedTotal);
    document.getElementById("vaultPendingBreakdown").textContent = `${money(cleanPending)} limpo · ${money(dirtyPending)} sujo`;
    document.getElementById("vaultPendingCount").textContent = `${pending.length} pedido${pending.length === 1 ? "" : "s"} aguardando repasse`;

    pendingBody.innerHTML = pending.map(order => `<tr>
      <td><input class="vault-order-check" type="checkbox" value="${esc(order.id)}" aria-label="Selecionar ${esc(order.code)}"></td>
      <td><strong>${esc(order.code)}</strong><div class="muted-caption">${esc(order.cnpj_name || order.customer_name || "Cliente")}</div></td>
      <td><span class="badge ${order.payment_type === "dirty" ? "warning" : "green"}">${paymentLabel(order.payment_type)}</span></td>
      <td>${money(order.net_amount)}</td>
      <td>${new Date(order.created_at).toLocaleDateString("pt-BR")}</td>
      <td><button class="icon-btn deposit-one" type="button" data-id="${esc(order.id)}">Depositar</button></td>
    </tr>`).join("") || `<tr><td colspan="6" class="empty success-empty">Tudo certo: não há valores pendentes de depósito no baú.</td></tr>`;

    tbody.innerHTML = (movements || []).map(item => `<tr>
      <td>${new Date(item.created_at).toLocaleString("pt-BR")}</td>
      <td>${esc(item.description)}${item.orders?.code ? `<div class="muted-caption">${esc(item.orders.code)}</div>` : ""}</td>
      <td><span class="badge ${item.source === "vault" ? "neutral" : item.movement_type === "entry" ? "green" : "red"}">${item.source === "vault" ? "Transferência" : item.movement_type === "entry" ? "Entrada" : "Saída"}</span></td>
      <td>${item.payment_type ? `<span class="badge neutral">${paymentLabel(item.payment_type)}</span>` : "—"}</td>
      <td>${item.source === "vault" ? "Baú" : item.source === "order" ? "Pedido" : "Manual"}</td>
      <td>${money(item.amount)}</td>
    </tr>`).join("") || `<tr><td colspan="6" class="empty">Nenhuma movimentação registrada.</td></tr>`;

    updateSelectionSummary();
  }

  function updateSelectionSummary() {
    const selected = selectedPendingIds();
    const button = document.getElementById("depositSelectedButton");
    const label = document.getElementById("selectedVaultCount");
    button.disabled = !selected.length;
    label.textContent = selected.length ? `${selected.length} selecionado${selected.length === 1 ? "" : "s"}` : "Selecione os pedidos que já foram colocados no baú";
  }

  async function deposit(ids) {
    if (!ids.length) return;
    const button = document.getElementById("depositSelectedButton");
    if (!confirm(`Confirmar que ${ids.length === 1 ? "este valor foi sacado e colocado" : "estes valores foram sacados e colocados"} no baú da família?`)) return;
    button.disabled = true;
    const oldText = button.textContent;
    button.textContent = "Confirmando...";
    try {
      const { data, error } = await client.rpc("mark_orders_vault_deposited", { p_order_ids: ids });
      if (error) throw error;
      toast(`${data?.orders_count || ids.length} repasse(s) confirmado(s) no baú.`);
      await loadCash();
    } catch (error) {
      console.error(error);
      toast(error.message || "Não foi possível confirmar o depósito.");
    } finally {
      button.disabled = false;
      button.textContent = oldText;
    }
  }

  function bindForm() {
    const form = document.getElementById("cashForm");
    form?.addEventListener("submit", async event => {
      event.preventDefault();
      const button = form.querySelector('button[type="submit"]');
      button.disabled = true; button.textContent = "Registrando...";
      const { error } = await client.from("cash_movements").insert({
        movement_type: document.getElementById("cashType").value,
        description: document.getElementById("cashDescription").value.trim(),
        amount: Number(document.getElementById("cashAmount").value),
        registered_by: window.currentDistrictUser?.id || null,
        source: "manual"
      });
      button.disabled = false; button.textContent = "Registrar";
      if (error) { console.error(error); toast(error.message || "Não foi possível registrar a movimentação."); return; }
      form.reset(); toast("Movimentação registrada."); await loadCash();
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
