(() => {
  const client = window.distritoSupabase;
  const money = value => Number(value || 0).toLocaleString("pt-BR", { style: "currency", currency: "BRL", maximumFractionDigits: 0 });
  const esc = value => String(value ?? "").replace(/[&<>'"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"}[c]));

  async function loadCash() {
    const tbody = document.getElementById("cashTable");
    const balance = document.getElementById("cashBalance");
    tbody.innerHTML = `<tr><td colspan="5" class="loading-row">Carregando movimentações...</td></tr>`;
    const { data, error } = await client.from("cash_movements").select("id,movement_type,description,amount,source,created_at,orders(code)").order("created_at", { ascending: false });
    if (error) { console.error(error); tbody.innerHTML = `<tr><td colspan="5" class="empty">Não foi possível carregar o caixa.</td></tr>`; return; }
    const total = (data || []).reduce((sum, item) => sum + (item.movement_type === "entry" ? Number(item.amount) : -Number(item.amount)), 0);
    balance.textContent = money(total);
    tbody.innerHTML = (data || []).map(item => `<tr><td>${new Date(item.created_at).toLocaleString("pt-BR")}</td><td>${esc(item.description)}${item.orders?.code?`<div class="muted-caption">${esc(item.orders.code)}</div>`:""}</td><td><span class="badge ${item.movement_type === "entry" ? "green" : "red"}">${item.movement_type === "entry" ? "Entrada" : "Saída"}</span></td><td>${esc(item.source || "manual")}</td><td>${money(item.amount)}</td></tr>`).join("") || `<tr><td colspan="5" class="empty">Nenhuma movimentação registrada.</td></tr>`;
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
  }

  document.addEventListener("district-auth-ready", async () => { bindForm(); await loadCash(); }, { once: true });
})();
