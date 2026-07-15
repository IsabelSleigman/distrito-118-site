(() => {
  const client = window.distritoSupabase;
  let products = [];
  const money = (value) => Number(value || 0).toLocaleString("pt-BR", { style: "currency", currency: "BRL", maximumFractionDigits: 0 });
  const imageSrc = value => !value ? "" : value.startsWith("/assets/") ? value : value;
  const statusLabels={pending:"Aguardando análise",under_review:"Em análise",accepted:"Aceita",waiting_materials:"Aguardando materiais",in_production:"Em produção",ready:"Pronta",awaiting_delivery:"Aguardando entrega",delivered:"Entregue",rejected:"Recusada",cancelled:"Cancelada"};
  const escapeHtml = (value) => String(value ?? "").replace(/[&<>'"]/g, (c) => ({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"}[c]));

  async function loadPublicProducts() {
    const { data, error } = await client.from("products").select(`
      id,name,description,image_url,product_categories(name),
      product_prices(customer_type,unit_price,wholesale_minimum,wholesale_price)
    `).eq("is_active", true).eq("is_public", true).eq("allows_order", true).order("name");
    if (error) throw error;
    products = data || [];
    return products;
  }
  function priceFor(product, tier) { return product.product_prices?.find((p) => p.customer_type === tier); }

  window.renderSupabaseProducts = async function(targetId, limit = null) {
    const el = document.getElementById(targetId); if (!el) return;
    el.innerHTML = `<div class="panel empty">Carregando produtos...</div>`;
    try {
      if (!products.length) await loadPublicProducts();
      const list = limit ? products.slice(0, limit) : products;
      el.innerHTML = list.map((p) => {
        const cpf = priceFor(p, "cpf"); const cnpj = priceFor(p, "cnpj");
        const art = p.image_url ? `<img src="${escapeHtml(imageSrc(p.image_url))}" alt="${escapeHtml(p.name)}">` : escapeHtml(p.name.substring(0,2).toUpperCase());
        return `<article class="product-card"><div class="product-art">${art}</div><div class="product-body"><div class="product-top"><div><span class="badge green">${escapeHtml(p.product_categories?.name || "Geral")}</span><h3 style="margin-top:10px">${escapeHtml(p.name)}</h3></div></div><p>${escapeHtml(p.description || "Disponível para encomenda.")}</p><div class="public-price-grid"><span>CPF <strong>${money(cpf?.unit_price)}</strong></span><span>CNPJ <strong>${money(cnpj?.unit_price)}</strong></span></div><div class="inline-actions"><a class="btn primary small" href="/encomenda?produto=${p.id}">Solicitar</a><span class="badge neutral">Produzido sob encomenda</span></div></div></article>`;
      }).join("") || `<div class="panel empty">Nenhum produto disponível.</div>`;
    } catch (error) { console.error(error); el.innerHTML = `<div class="panel empty">Não foi possível carregar o catálogo.</div>`; }
  };

  window.setupSupabaseOrderForm = async function() {
    const form=document.getElementById("orderForm"); if(!form) return;
    const type=document.getElementById("customerType"), paymentType=document.getElementById("paymentType"), orgField=document.getElementById("organizationField"), items=document.getElementById("orderItems"), addButton=document.getElementById("addOrderItem"), totalEl=document.getElementById("orderTotal"), cleanTotalEl=document.getElementById("orderCleanTotal"), dirtyTotalEl=document.getElementById("orderDirtyTotal"), summaryEl=document.getElementById("orderSummary");
    try { await loadPublicProducts(); } catch(error) { console.error(error); toast("Não foi possível carregar os produtos."); return; }
    function options(){ return products.map(p=>`<option value="${p.id}">${escapeHtml(p.name)}</option>`).join(""); }
    function addItem(productId=products[0]?.id){ if(!productId) return; const row=document.createElement("div"); row.className="order-item"; row.innerHTML=`<div class="field"><label>Produto</label><select class="order-product">${options()}</select></div><div class="field"><label>Quantidade</label><input class="order-qty" type="number" min="1" value="1"></div><button type="button" class="btn ghost remove-item">×</button>`; row.querySelector(".order-product").value=productId; row.querySelectorAll("select,input").forEach(e=>e.addEventListener("input",update)); row.querySelector(".remove-item").addEventListener("click",()=>{row.remove();update();}); items.appendChild(row); update(); }
    function update(){ let cleanTotal=0; const tier=type.value; const lines=[...items.querySelectorAll(".order-item")].map(row=>{ const p=products.find(x=>x.id===row.querySelector(".order-product").value); const qty=Math.max(1,Number(row.querySelector(".order-qty").value||1)); const applied=window.DistrictPricing.apply(priceFor(p,tier),qty); cleanTotal+=applied.subtotal; return `<div class="summary-row"><span>${qty}x ${escapeHtml(p.name)} ${applied.isWholesale?'<small class="badge red">atacado</small>':''}</span><strong>${money(applied.subtotal)}</strong></div>`; }); const dirtyTotal=Math.round(cleanTotal*1.30); const finalTotal=paymentType.value==="dirty"?dirtyTotal:cleanTotal; summaryEl.innerHTML=lines.join("")||`<div class="empty">Nenhum produto selecionado.</div>`; if(cleanTotalEl)cleanTotalEl.textContent=money(cleanTotal); if(dirtyTotalEl)dirtyTotalEl.textContent=money(dirtyTotal); totalEl.textContent=money(finalTotal); }
    type.addEventListener("change",()=>{ const cnpj=type.value==="cnpj"; orgField.style.display=cnpj?"flex":"none"; document.getElementById("organizationName").required=cnpj; update(); }); paymentType.addEventListener("change",update); addButton.addEventListener("click",()=>addItem());
    const initial=new URLSearchParams(location.search).get("produto"); addItem(products.some(p=>p.id===initial)?initial:products[0]?.id);
    form.addEventListener("submit",async e=>{ e.preventDefault(); const rows=[...items.querySelectorAll(".order-item")]; if(!rows.length) return toast("Adicione pelo menos um produto."); const button=form.querySelector('button[type="submit"]'); button.disabled=true; button.textContent="Enviando..."; try { const inputItems=rows.map(row=>({product_id:row.querySelector(".order-product").value,quantity:Math.max(1,Number(row.querySelector(".order-qty").value||1))})); const {data,error}=await client.rpc("create_public_order",{ input_customer_type:type.value,input_customer_name:document.getElementById("customerName").value.trim(),input_cnpj_name:document.getElementById("organizationName").value.trim()||null,input_passport:document.getElementById("passport").value.trim(),input_phone:document.getElementById("phone").value.trim()||null,input_notes:document.getElementById("notes").value.trim()||null,input_payment_type:paymentType.value,input_items:inputItems }); if(error) throw error; toast(`Encomenda ${data.code} criada com sucesso.`); setTimeout(()=>location.href=`/consulta?codigo=${encodeURIComponent(data.code)}`,700); } catch(error){console.error(error);toast(error.message||"Não foi possível criar a encomenda.");} finally {button.disabled=false;button.textContent="Enviar encomenda";} });
  };

  window.setupSupabaseOrderLookup = function(){
    const form=document.getElementById("lookupForm"), result=document.getElementById("lookupResult");
    if(!form||!result)return;
    async function search(code){
      code=code.trim().toUpperCase();
      result.innerHTML=`<div class="panel empty">Consultando...</div>`;
      const [{data,error},{data:timeline,error:timelineError}]=await Promise.all([
        client.rpc("get_public_order_by_code",{input_code:code}),
        client.rpc("get_public_order_timeline_by_code",{input_code:code})
      ]);
      if(error||!data){result.innerHTML=`<div class="panel empty">Encomenda não encontrada. Confira o código e tente novamente.</div>`;return;}
      if(timelineError) console.error(timelineError);
      const history=Array.isArray(timeline)?timeline:[];
      result.innerHTML=`<div class="panel"><div class="section-head"><div><span class="eyebrow">Encomenda</span><h2>${escapeHtml(data.code)}</h2></div><span class="badge ${data.status==="delivered"?"green":["rejected","cancelled"].includes(data.status)?"red":"yellow"}">${escapeHtml(statusLabels[data.status]||data.status)}</span></div><div class="summary-list"><div class="summary-row"><span>Cliente</span><strong>${escapeHtml(data.customer_display)}</strong></div>${(data.items||[]).map(i=>`<div class="summary-row"><span>${i.quantity}x ${escapeHtml(i.product_name)}</span><strong>${money(i.subtotal)}</strong></div>`).join("")}<div class="summary-row"><span>Forma de pagamento</span><strong>${data.payment_type==="dirty"?"Dinheiro sujo":"Dinheiro limpo"}</strong></div><div class="summary-row"><span>Valor limpo</span><strong>${money(data.clean_amount??data.total_amount)}</strong></div><div class="summary-row"><span>Valor sujo</span><strong>${money(data.dirty_amount??Number(data.total_amount||0)*1.3)}</strong></div><div class="summary-row summary-total"><span>Total escolhido</span><strong>${money(data.final_amount??data.total_amount)}</strong></div></div><div class="public-order-timeline"><h3>Linha do tempo</h3><div class="order-timeline">${history.map((entry,index)=>`<div class="timeline-entry ${index===history.length-1?"current":""}"><span class="timeline-dot"></span><div><strong>${escapeHtml(statusLabels[entry.status]||entry.status)}</strong><time>${new Date(entry.created_at).toLocaleString("pt-BR")}</time>${entry.note?`<p>${escapeHtml(entry.note)}</p>`:""}</div></div>`).join("")||`<div class="empty">Nenhuma atualização registrada.</div>`}</div></div></div>`;
    }
    form.addEventListener("submit",e=>{e.preventDefault();search(document.getElementById("lookupCode").value);});
    const code=new URLSearchParams(location.search).get("codigo");
    if(code){document.getElementById("lookupCode").value=code;search(code);}
  };})();
