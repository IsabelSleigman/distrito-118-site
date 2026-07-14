(() => {
  const client = window.distritoSupabase;
  const esc = value => String(value ?? "").replace(/[&<>'"]/g, char => ({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"}[char]));
  const number = value => Number(value || 0);

  async function loadStock() {
    const tbody = document.getElementById("stockTable");
    if (!tbody) return;

    tbody.innerHTML = `<tr><td colspan="6" class="loading-row">Carregando estoque real...</td></tr>`;

    const { data, error } = await client
      .from("materials")
      .select("id,name,unit,stock_quantity,reserved_quantity,minimum_stock,is_active")
      .eq("is_active", true)
      .order("name");

    if (error) {
      console.error(error);
      tbody.innerHTML = `<tr><td colspan="6" class="empty">Não foi possível carregar o estoque.</td></tr>`;
      return;
    }

    const materials = data || [];
    tbody.innerHTML = materials.map(material => {
      const total = number(material.stock_quantity);
      const reserved = number(material.reserved_quantity);
      const available = Math.max(0, total - reserved);
      const minimum = number(material.minimum_stock);
      const low = available <= minimum;

      return `<tr>
        <td><strong>${esc(material.name)}</strong><div class="muted-caption">${esc(material.unit || "unidade")}</div></td>
        <td>${total}</td>
        <td>${reserved}</td>
        <td><strong>${available}</strong></td>
        <td>${minimum}</td>
        <td><span class="badge ${low ? "yellow" : "green"}">${low ? "Estoque baixo" : "Normal"}</span></td>
      </tr>`;
    }).join("") || `<tr><td colspan="6" class="empty">Nenhum material ativo cadastrado.</td></tr>`;
  }

  document.addEventListener("district-auth-ready", loadStock, { once: true });
})();
