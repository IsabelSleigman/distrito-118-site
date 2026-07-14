(() => {
  const client = window.distritoSupabase;
  const tiers = ["cpf", "cnpj", "alianca", "parceria"];
  const statuses = [
    ["pending", "Aguardando análise"],
    ["under_review", "Em análise"],
    ["accepted", "Aceita"],
    ["waiting_materials", "Aguardando materiais"],
    ["in_production", "Em produção"],
    ["ready", "Pronta"],
    ["awaiting_delivery", "Aguardando entrega"],
    ["delivered", "Entregue"],
    ["rejected", "Recusada"],
    ["cancelled", "Cancelada"]
  ];

  const money = value => Number(value || 0).toLocaleString("pt-BR", {
    style: "currency", currency: "BRL", maximumFractionDigits: 0
  });
  const esc = value => String(value ?? "").replace(/[&<>'"]/g, character => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;"
  }[character]));
  const statusLabel = value => statuses.find(([key]) => key === value)?.[1] || value;
  const statusClass = value => `status-${value || "unknown"}`;
  const formatDateTime = value => new Date(value).toLocaleString("pt-BR");

  async function updateStatus(orderId, status, note) {
    if (!orderId) throw new Error("ID da encomenda não encontrado.");

    const { data, error } = await client.rpc("update_order_status_v2", {
      p_order_id: orderId,
      p_status: status,
      p_note: String(note || "").trim() || null
    });

    if (error) throw error;
    return data;
  }

  function openDetails(order) {
    const modal = document.getElementById("orderDetailsModal");
    const content = document.getElementById("orderDetailsContent");
    if (!modal || !content) return;

    const history = [...(order.order_status_history || [])].sort(
      (a, b) => new Date(a.created_at) - new Date(b.created_at)
    );

    content.innerHTML = `
      <div class="section-head order-modal-head">
        <div>
          <span class="eyebrow">Encomenda</span>
          <div class="order-code-line">
            <h2>${esc(order.code)}</h2>
            <button class="icon-btn copy-order-code" type="button" title="Copiar código">Copiar</button>
          </div>
        </div>
        <span class="badge ${statusClass(order.status)}">${esc(statusLabel(order.status))}</span>
      </div>

      <div class="status-manager" data-order-id="${esc(order.id)}">
        <div>
          <span class="status-manager-label">Atualizar andamento</span>
          <p>Altere o status por aqui. A mudança será registrada na linha do tempo.</p>
        </div>
        <div class="status-manager-fields">
          <select id="detailOrderStatus" class="order-status-detail">
            ${statuses.map(([key, label]) => `<option value="${key}" ${key === order.status ? "selected" : ""}>${label}</option>`).join("")}
          </select>
          <input id="detailStatusNote" type="text" placeholder="Observação opcional">
          <button id="saveOrderStatus" class="btn primary small" type="button">Salvar status</button>
        </div>
        <p id="statusUpdateError" class="status-update-error" hidden></p>
      </div>

      <div class="order-detail-grid">
        <div class="summary-list">
          <div class="summary-row"><span>Cliente</span><strong>${esc(order.cnpj_name || order.customer_name)}</strong></div>
          <div class="summary-row"><span>Tipo</span><strong>${esc(window.DistrictPricing.label(order.pricing_tier || order.customer_type))}</strong></div>
          <div class="summary-row"><span>Passaporte</span><strong>${esc(order.passport || "—")}</strong></div>
          <div class="summary-row"><span>Telefone</span><strong>${esc(order.phone || "—")}</strong></div>
          ${(order.order_items || []).map(item => `
            <div class="summary-row">
              <span>${item.quantity}x ${esc(item.product_name)}</span>
              <strong>${money(item.subtotal)}</strong>
            </div>
          `).join("")}
          <div class="summary-row summary-total"><span>Total</span><strong>${money(order.total_amount)}</strong></div>
          ${order.notes ? `<div class="order-note"><strong>Observação do cliente</strong><p>${esc(order.notes)}</p></div>` : ""}
        </div>
        <div>
          <h3 class="timeline-title">Linha do tempo</h3>
          <div class="order-timeline">
            ${history.map((entry, index) => `
              <div class="timeline-entry ${statusClass(entry.status)} ${index === history.length - 1 ? "current" : ""}">
                <span class="timeline-dot"></span>
                <div>
                  <strong>${esc(statusLabel(entry.status))}</strong>
                  <time>${formatDateTime(entry.created_at)}</time>
                  ${entry.note ? `<p>${esc(entry.note)}</p>` : ""}
                </div>
              </div>
            `).join("") || `<div class="empty">Nenhuma atualização registrada.</div>`}
          </div>
        </div>
      </div>`;

    content.querySelector(".copy-order-code")?.addEventListener("click", async () => {
      await navigator.clipboard.writeText(order.code);
      toast("Código copiado.");
    });



    modal.classList.add("open");
  }

  async function load() {
    const tbody = document.getElementById("ordersTable");
    tbody.innerHTML = `<tr><td colspan="8" class="loading-row">Carregando encomendas...</td></tr>`;

    const { data, error } = await client
      .from("orders")
      .select(`
        id,code,customer_type,customer_name,cnpj_name,passport,phone,notes,
        pricing_tier,total_amount,status,created_at,deleted_at,
        order_items(quantity,product_name,unit_price,subtotal),
        order_status_history(status,note,created_at)
      `)
      .is("deleted_at", null)
      .order("created_at", { ascending: false });

    if (error) {
      console.error(error);
      tbody.innerHTML = `<tr><td colspan="8" class="empty">Não foi possível carregar as encomendas.</td></tr>`;
      return;
    }

    tbody.innerHTML = (data || []).map(order => `<tr>
      <td><strong class="order-code-cell">${esc(order.code)}</strong></td>
      <td>${esc(order.cnpj_name || order.customer_name)}<div class="muted-caption">${order.customer_type.toUpperCase()}</div></td>
      <td>${(order.order_items || []).reduce((sum, item) => sum + item.quantity, 0)}</td>
      <td>${money(order.total_amount)}</td>
      <td>
        <select class="pricing-tier" data-id="${order.id}">
          ${tiers.map(tier => `<option value="${tier}" ${tier === (order.pricing_tier || order.customer_type) ? "selected" : ""}>${window.DistrictPricing.label(tier)}</option>`).join("")}
        </select>
      </td>
      <td><span class="badge ${statusClass(order.status)} order-status-badge">${esc(statusLabel(order.status))}</span></td>
      <td>${new Date(order.created_at).toLocaleDateString("pt-BR")}</td>
      <td>
        <div class="table-actions">
          <button class="icon-btn view-order" data-id="${order.id}">Detalhes</button>
          <button class="icon-btn danger delete-order" data-id="${order.id}" data-code="${esc(order.code)}">Excluir</button>
        </div>
      </td>
    </tr>`).join("") || `<tr><td colspan="8" class="empty">Nenhuma encomenda registrada.</td></tr>`;

    document.querySelectorAll(".pricing-tier").forEach(element => element.addEventListener("change", async () => {
      element.disabled = true;
      const { error: pricingError } = await client.rpc("recalculate_order_pricing", {
        input_order_id: element.dataset.id,
        input_pricing_tier: element.value
      });
      element.disabled = false;
      if (pricingError) {
        console.error(pricingError);
        toast(pricingError.message || "Erro ao recalcular preço.");
        await load();
        return;
      }
      toast(`Tabela ${window.DistrictPricing.label(element.value)} aplicada.`);
      await load();
    }));

    document.querySelectorAll(".view-order").forEach(element => element.addEventListener("click", () => {
      const order = data.find(item => item.id === element.dataset.id);
      if (order) openDetails(order);
    }));

    document.querySelectorAll(".delete-order").forEach(element => element.addEventListener("click", async () => {
      if (!confirm(`Excluir a encomenda ${element.dataset.code}?\n\nEla sairá do painel, mas continuará preservada no histórico.`)) return;
      const { error: deleteError } = await client.rpc("soft_delete_order", { input_order_id: element.dataset.id });
      if (deleteError) {
        console.error(deleteError);
        toast("Não foi possível excluir a encomenda.");
        return;
      }
      toast("Encomenda excluída do painel.");
      await load();
    }));

    window.lucide?.createIcons();
  }

  document.getElementById("orderDetailsModal")?.addEventListener("click", async event => {
    const button = event.target.closest("#saveOrderStatus");
    if (!button) return;

    event.preventDefault();
    event.stopPropagation();

    const content = document.getElementById("orderDetailsContent");
    const manager = button.closest(".status-manager");
    const errorBox = content?.querySelector("#statusUpdateError");
    const orderId = manager?.dataset.orderId;
    const status = content?.querySelector("#detailOrderStatus")?.value;
    const note = content?.querySelector("#detailStatusNote")?.value || "";

    if (!orderId || !status) {
      if (errorBox) {
        errorBox.textContent = "Não foi possível identificar a encomenda ou o status.";
        errorBox.hidden = false;
      }
      return;
    }

    button.disabled = true;
    button.textContent = "Salvando...";
    if (errorBox) errorBox.hidden = true;

    try {
      await updateStatus(orderId, status, note);
      toast(`Status alterado para ${statusLabel(status)}.`);
      document.getElementById("orderDetailsModal")?.classList.remove("open");
      await load();
    } catch (error) {
      console.error("Falha ao atualizar status:", error);
      const message = error?.message || error?.details || "Erro desconhecido ao atualizar status.";
      if (errorBox) {
        errorBox.textContent = message;
        errorBox.hidden = false;
      }
      toast(message);
    } finally {
      button.disabled = false;
      button.textContent = "Salvar status";
    }
  });

  document.getElementById("closeOrderDetails")?.addEventListener("click", () => {
    document.getElementById("orderDetailsModal")?.classList.remove("open");
  });
  document.getElementById("orderDetailsModal")?.addEventListener("click", event => {
    if (event.target.id === "orderDetailsModal") event.currentTarget.classList.remove("open");
  });

  document.addEventListener("district-auth-ready", load, { once: true });
})();
