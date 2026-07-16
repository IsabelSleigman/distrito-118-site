(() => {
  const client = window.distritoSupabase;
  const esc = value => String(value ?? "").replace(/[&<>'"]/g, char => ({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"}[char]));
  const number = value => Number(value || 0);

  async function loadStock() {
    const tbody = document.getElementById("stockTable");
    const scope = document.getElementById("stockScope")?.value || "gerencia";
    if (!tbody) return;
    tbody.innerHTML = `<tr><td colspan="6" class="loading-row">Carregando ${scope === "gerencia" ? "estoque da gerência" : "estoque geral"}...</td></tr>`;

    const { data, error } = await client.from("inventory_balances").select(`
      quantity,reserved_quantity,
      inventory_stocks!inner(scope),
      materials!inner(id,name,unit,minimum_stock,is_active)
    `).eq("inventory_stocks.scope", scope).eq("materials.is_active", true).order("material_id");

    if (error) {
      console.error(error);
      tbody.innerHTML = `<tr><td colspan="6" class="empty">Não foi possível carregar o estoque.</td></tr>`;
      return;
    }

    const rows = (data || []).sort((a,b) => a.materials.name.localeCompare(b.materials.name,"pt-BR"));
    tbody.innerHTML = rows.map(row => {
      const material = row.materials;
      const total = number(row.quantity);
      const reserved = number(row.reserved_quantity);
      const available = Math.max(0, total - reserved);
      const minimum = number(material.minimum_stock);
      const low = available <= minimum;
      return `<tr>
        <td><strong>${esc(material.name)}</strong><div class="muted-caption">${esc(material.unit || "unidade")}</div></td>
        <td>${total}</td><td>${reserved}</td><td><strong>${available}</strong></td><td>${minimum}</td>
        <td><span class="badge ${low ? "yellow" : "green"}">${low ? "Estoque baixo" : "Normal"}</span></td>
      </tr>`;
    }).join("") || `<tr><td colspan="6" class="empty">Nenhum material cadastrado neste estoque.</td></tr>`;
  }
  document.getElementById("stockScope")?.addEventListener("change", loadStock);
  document.addEventListener("district-auth-ready", loadStock, { once: true });
})();
