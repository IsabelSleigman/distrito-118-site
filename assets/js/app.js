const PRODUCTS = [
  { id: 1, name: "Colete", category: "Proteção", price: 10000, stock: 12, description: "Proteção reforçada para operações e entregas." },
  { id: 2, name: "Pente estendido", category: "Acessórios", price: 6500, stock: 30, description: "Maior capacidade para equipamentos compatíveis." },
  { id: 3, name: "Silenciador", category: "Acessórios", price: 8000, stock: 8, description: "Acessório disponível sob encomenda." },
  { id: 4, name: "Empunhadura", category: "Acessórios", price: 5500, stock: 16, description: "Melhor estabilidade e controle." },
  { id: 5, name: "Mira holográfica", category: "Acessórios", price: 9000, stock: 6, description: "Aquisição rápida de alvo." },
  { id: 6, name: "Kit especial", category: "Kits", price: 32000, stock: 4, description: "Conjunto completo para clientes da Distrito." }
];

function money(value) {
  return Number(value || 0).toLocaleString("pt-BR", { style: "currency", currency: "BRL", maximumFractionDigits: 0 });
}
function getOrders() { return JSON.parse(localStorage.getItem("distrito_orders") || "[]"); }
function saveOrders(items) { localStorage.setItem("distrito_orders", JSON.stringify(items)); }
function getCash() { return JSON.parse(localStorage.getItem("distrito_cash") || "[]"); }
function saveCash(items) { localStorage.setItem("distrito_cash", JSON.stringify(items)); }

function toast(message) {
  let el = document.querySelector(".toast");
  if (!el) {
    el = document.createElement("div");
    el.className = "toast";
    document.body.appendChild(el);
  }
  el.textContent = message;
  el.classList.add("show");
  setTimeout(() => el.classList.remove("show"), 2800);
}

function renderProducts(targetId, limit = null) {
  const el = document.getElementById(targetId);
  if (!el) return;
  const list = limit ? PRODUCTS.slice(0, limit) : PRODUCTS;
  el.innerHTML = list.map(p => `
    <article class="product-card">
      <div class="product-art">${p.name.substring(0,2).toUpperCase()}</div>
      <div class="product-body">
        <div class="product-top">
          <div>
            <span class="badge green">${p.category}</span>
            <h3 style="margin-top:10px">${p.name}</h3>
          </div>
          <span class="price">${money(p.price)}</span>
        </div>
        <p>${p.description}</p>
        <div class="inline-actions">
          <a class="btn primary small" href="/encomenda?produto=${p.id}">Solicitar</a>
          <span class="badge ${p.stock > 5 ? "green" : "yellow"}">${p.stock} em estoque</span>
        </div>
      </div>
    </article>
  `).join("");
}

function setupOrderForm() {
  const form = document.getElementById("orderForm");
  if (!form) return;

  const type = document.getElementById("customerType");
  const orgField = document.getElementById("organizationField");
  const items = document.getElementById("orderItems");
  const addButton = document.getElementById("addOrderItem");
  const totalEl = document.getElementById("orderTotal");
  const summaryEl = document.getElementById("orderSummary");

  function productOptions() {
    return PRODUCTS.map(p => `<option value="${p.id}">${p.name} — ${money(p.price)}</option>`).join("");
  }

  function addItem(productId = PRODUCTS[0].id) {
    const row = document.createElement("div");
    row.className = "order-item";
    row.innerHTML = `
      <div class="field">
        <label>Produto</label>
        <select class="order-product">${productOptions()}</select>
      </div>
      <div class="field">
        <label>Quantidade</label>
        <input class="order-qty" type="number" min="1" value="1">
      </div>
      <button type="button" class="btn ghost remove-item">×</button>
    `;
    row.querySelector(".order-product").value = String(productId);
    row.querySelectorAll("select,input").forEach(e => e.addEventListener("input", updateSummary));
    row.querySelector(".remove-item").addEventListener("click", () => { row.remove(); updateSummary(); });
    items.appendChild(row);
    updateSummary();
  }

  function updateSummary() {
    const rows = [...items.querySelectorAll(".order-item")];
    let total = 0;
    const lines = rows.map(row => {
      const product = PRODUCTS.find(p => p.id === Number(row.querySelector(".order-product").value));
      const qty = Math.max(1, Number(row.querySelector(".order-qty").value || 1));
      total += product.price * qty;
      return `<div class="summary-row"><span>${qty}x ${product.name}</span><strong>${money(product.price * qty)}</strong></div>`;
    });
    summaryEl.innerHTML = lines.length ? lines.join("") : `<div class="empty">Nenhum produto selecionado.</div>`;
    totalEl.textContent = money(total);
  }

  type.addEventListener("change", () => {
    const isOrg = type.value === "organization";
    orgField.style.display = isOrg ? "flex" : "none";
    document.getElementById("organizationName").required = isOrg;
  });

  addButton.addEventListener("click", () => addItem());

  const initialId = Number(new URLSearchParams(location.search).get("produto"));
  addItem(PRODUCTS.some(p => p.id === initialId) ? initialId : PRODUCTS[0].id);

  form.addEventListener("submit", e => {
    e.preventDefault();
    const rows = [...items.querySelectorAll(".order-item")];
    if (!rows.length) return toast("Adicione pelo menos um produto.");

    const orderItems = rows.map(row => {
      const product = PRODUCTS.find(p => p.id === Number(row.querySelector(".order-product").value));
      const quantity = Math.max(1, Number(row.querySelector(".order-qty").value || 1));
      return { productId: product.id, name: product.name, price: product.price, quantity, subtotal: product.price * quantity };
    });

    const orders = getOrders();
    const code = `DT-${String(orders.length + 1).padStart(4, "0")}`;
    const total = orderItems.reduce((sum, item) => sum + item.subtotal, 0);

    orders.unshift({
      id: crypto.randomUUID ? crypto.randomUUID() : String(Date.now()),
      code,
      customerType: type.value,
      customerName: document.getElementById("customerName").value.trim(),
      organizationName: document.getElementById("organizationName").value.trim(),
      passport: document.getElementById("passport").value.trim(),
      phone: document.getElementById("phone").value.trim(),
      notes: document.getElementById("notes").value.trim(),
      items: orderItems,
      total,
      status: "Pendente",
      createdAt: new Date().toISOString()
    });
    saveOrders(orders);
    form.reset();
    items.innerHTML = "";
    addItem();
    type.dispatchEvent(new Event("change"));
    toast(`Encomenda ${code} criada com sucesso.`);
    setTimeout(() => location.href = `/consulta?codigo=${code}`, 800);
  });
}

function setupOrderLookup() {
  const form = document.getElementById("lookupForm");
  const result = document.getElementById("lookupResult");
  if (!form || !result) return;

  function search(code) {
    const order = getOrders().find(o => o.code.toLowerCase() === code.trim().toLowerCase());
    if (!order) {
      result.innerHTML = `<div class="panel empty">Encomenda não encontrada.</div>`;
      return;
    }
    result.innerHTML = `
      <div class="panel">
        <div class="section-head">
          <div><span class="eyebrow">Encomenda</span><h2>${order.code}</h2></div>
          <span class="badge ${order.status === "Entregue" ? "green" : "yellow"}">${order.status}</span>
        </div>
        <div class="summary-list">
          <div class="summary-row"><span>Cliente</span><strong>${order.organizationName || order.customerName}</strong></div>
          <div class="summary-row"><span>Passaporte</span><strong>${order.passport}</strong></div>
          ${order.items.map(i => `<div class="summary-row"><span>${i.quantity}x ${i.name}</span><strong>${money(i.subtotal)}</strong></div>`).join("")}
          <div class="summary-row summary-total"><span>Total</span><strong>${money(order.total)}</strong></div>
        </div>
      </div>`;
  }

  form.addEventListener("submit", e => { e.preventDefault(); search(document.getElementById("lookupCode").value); });
  const code = new URLSearchParams(location.search).get("codigo");
  if (code) { document.getElementById("lookupCode").value = code; search(code); }
}

function renderAdminDashboard() {
  const orders = getOrders();
  const cash = getCash();
  const paid = cash.filter(c => c.type === "entrada").reduce((s,c) => s + Number(c.amount), 0);
  const spent = cash.filter(c => c.type === "saida").reduce((s,c) => s + Number(c.amount), 0);
  const byId = id => document.getElementById(id);
  if (byId("statPending")) byId("statPending").textContent = orders.filter(o => o.status === "Pendente").length;
  if (byId("statProduction")) byId("statProduction").textContent = orders.filter(o => o.status === "Em produção").length;
  if (byId("statDelivered")) byId("statDelivered").textContent = orders.filter(o => o.status === "Entregue").length;
  if (byId("statCash")) byId("statCash").textContent = money(paid - spent);

  const tbody = byId("latestOrders");
  if (tbody) {
    tbody.innerHTML = orders.slice(0,6).map(o => `
      <tr><td>${o.code}</td><td>${o.organizationName || o.customerName}</td><td>${money(o.total)}</td><td><span class="badge yellow">${o.status}</span></td></tr>
    `).join("") || `<tr><td colspan="4" class="empty">Nenhuma encomenda registrada.</td></tr>`;
  }
}

function renderAdminOrders() {
  const tbody = document.getElementById("ordersTable");
  if (!tbody) return;
  const orders = getOrders();

  tbody.innerHTML = orders.map(o => `
    <tr>
      <td>${o.code}</td>
      <td>${o.organizationName || o.customerName}</td>
      <td>${o.items.reduce((s,i)=>s+i.quantity,0)}</td>
      <td>${money(o.total)}</td>
      <td>
        <select data-id="${o.id}" class="order-status">
          ${["Pendente","Aceita","Em produção","Pronta","Entregue","Recusada"].map(s => `<option ${s===o.status?"selected":""}>${s}</option>`).join("")}
        </select>
      </td>
    </tr>
  `).join("") || `<tr><td colspan="5" class="empty">Nenhuma encomenda registrada.</td></tr>`;

  document.querySelectorAll(".order-status").forEach(select => {
    select.addEventListener("change", () => {
      const list = getOrders();
      const order = list.find(o => o.id === select.dataset.id);
      if (!order) return;
      const previous = order.status;
      order.status = select.value;
      if (select.value === "Entregue" && previous !== "Entregue") {
        const cash = getCash();
        cash.unshift({ id: String(Date.now()), type:"entrada", description:`Encomenda ${order.code}`, amount:order.total, createdAt:new Date().toISOString() });
        saveCash(cash);
        toast(`Encomenda ${order.code} entregue e lançada no caixa.`);
      } else {
        toast(`Status atualizado para ${select.value}.`);
      }
      saveOrders(list);
    });
  });
}

function renderAdminProducts() {
  const tbody = document.getElementById("productsTable");
  if (!tbody) return;
  tbody.innerHTML = PRODUCTS.map(p => `
    <tr><td>${p.name}</td><td>${p.category}</td><td>${money(p.price)}</td><td>${p.stock}</td><td><span class="badge green">Ativo</span></td></tr>
  `).join("");
}

function renderAdminStock() {
  const tbody = document.getElementById("stockTable");
  if (!tbody) return;
  const materials = [
    ["Alumínio", 420, 100], ["Plástico", 680, 200], ["Cobre", 350, 120],
    ["Vidro", 210, 80], ["Placa blindada", 75, 40], ["Lona", 160, 60]
  ];
  tbody.innerHTML = materials.map(([n,q,m]) => `
    <tr><td>${n}</td><td>${q}</td><td>${m}</td><td><span class="badge ${q<=m?"red":"green"}">${q<=m?"Baixo":"Normal"}</span></td></tr>
  `).join("");
}

function renderAdminCash() {
  const form = document.getElementById("cashForm");
  const tbody = document.getElementById("cashTable");
  const balance = document.getElementById("cashBalance");
  if (!tbody) return;

  function render() {
    const list = getCash();
    const total = list.reduce((s,c) => s + (c.type === "entrada" ? Number(c.amount) : -Number(c.amount)), 0);
    if (balance) balance.textContent = money(total);
    tbody.innerHTML = list.map(c => `
      <tr><td>${new Date(c.createdAt).toLocaleDateString("pt-BR")}</td><td>${c.description}</td><td><span class="badge ${c.type==="entrada"?"green":"red"}">${c.type}</span></td><td>${money(c.amount)}</td></tr>
    `).join("") || `<tr><td colspan="4" class="empty">Nenhuma movimentação.</td></tr>`;
  }

  if (form) {
    form.addEventListener("submit", e => {
      e.preventDefault();
      const list = getCash();
      list.unshift({
        id: String(Date.now()),
        type: document.getElementById("cashType").value,
        description: document.getElementById("cashDescription").value.trim(),
        amount: Number(document.getElementById("cashAmount").value),
        createdAt: new Date().toISOString()
      });
      saveCash(list); form.reset(); render(); toast("Movimentação registrada.");
    });
  }
  render();
}
