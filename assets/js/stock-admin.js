(() => {
  const client = window.distritoSupabase;
  const esc = value => String(value ?? "").replace(/[&<>'"]/g, char => ({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"}[char]));
  const number = value => Number(value || 0);
  let items = [];
  let balances = [];
  let stocks = [];

  function selectedScope() {
    return document.getElementById("stockScope")?.value || "geral";
  }

  function renderStock() {
    const tbody = document.getElementById("stockTable");
    if (!tbody) return;
    const scope = selectedScope();
    const onlyWithStock = document.getElementById("onlyWithStock")?.checked ?? true;
    const stock = stocks.find(item => item.scope === scope);
    const balancesByItem = new Map(
      balances.filter(item => item.stock_id === stock?.id).map(item => [`${item.item_type}:${item.item_id}`, item])
    );

    const rows = items.map(item => {
      const balance = balancesByItem.get(`${item.item_type}:${item.item_id}`);
      const total = number(balance?.quantity);
      const reserved = number(balance?.reserved_quantity);
      return { item, total, reserved, available: Math.max(0, total - reserved) };
    }).filter(row => !onlyWithStock || row.total > 0 || row.reserved > 0);

    tbody.innerHTML = rows.map(row => {
      const minimum = number(row.item.minimum_stock);
      const low = row.available <= minimum;
      return `<tr>
        <td><strong>${esc(row.item.name)}</strong><div class="muted-caption">${row.item.item_type === "product" ? "Produto pronto" : "Material"} · ${esc(row.item.unit || "unidade")}</div></td>
        <td>${row.total}</td><td>${row.reserved}</td><td><strong>${row.available}</strong></td><td>${minimum}</td>
        <td><span class="badge ${low ? "yellow" : "green"}">${low ? "Estoque baixo" : "Normal"}</span></td>
      </tr>`;
    }).join("") || `<tr><td colspan="6" class="empty">${onlyWithStock ? "Nenhum item com estoque neste baú." : "Nenhum item ativo cadastrado."}</td></tr>`;
  }

  async function loadStock() {
    const tbody = document.getElementById("stockTable");
    if (!tbody) return;
    tbody.innerHTML = `<tr><td colspan="6" class="loading-row">Carregando estoque...</td></tr>`;

    const [catalogResult, materialsResult, stocksResult, balancesResult] = await Promise.all([
      client.from("inventory_catalog").select("item_type,item_id,name,unit,is_active").eq("is_active", true).order("name"),
      client.from("materials").select("id,minimum_stock"),
      client.from("inventory_stocks").select("id,scope,is_active").in("scope", ["geral", "gerencia"]),
      client.from("inventory_all_balances").select("stock_id,item_type,item_id,quantity,reserved_quantity")
    ]);

    const error = catalogResult.error || materialsResult.error || stocksResult.error || balancesResult.error;
    if (error) {
      console.error(error);
      tbody.innerHTML = `<tr><td colspan="6" class="empty">Não foi possível carregar o estoque.</td></tr>`;
      return;
    }

    const minimumByMaterial = new Map((materialsResult.data || []).map(item => [item.id, item.minimum_stock]));
    items = (catalogResult.data || []).map(item => ({ ...item, minimum_stock: item.item_type === "material" ? minimumByMaterial.get(item.item_id) || 0 : 0 }));
    stocks = stocksResult.data || [];
    balances = balancesResult.data || [];
    renderStock();
  }

  document.getElementById("stockScope")?.addEventListener("change", renderStock);
  document.getElementById("onlyWithStock")?.addEventListener("change", renderStock);
  document.addEventListener("district-auth-ready", loadStock, { once: true });
})();
