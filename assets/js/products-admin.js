(() => {
  const client = window.distritoSupabase;
  const TIERS = ["cpf", "cnpj", "alianca", "parceria"];
  let products = [], categories = [], materials = [];

  const $ = id => document.getElementById(id);
  const nnull = value => value === "" ? null : Number(value);
  const money = value => Number(value || 0).toLocaleString("pt-BR",{style:"currency",currency:"BRL",maximumFractionDigits:0});
  const esc = value => String(value ?? "").replace(/[&<>'"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"}[c]));
  const imageSrc = value => !value ? "" : value.startsWith("/assets/") ? `..${value}` : value;
  const priceFor = (p,t) => p?.product_prices?.find(x=>x.customer_type===t);

  function showError(message){$("productFormError").textContent=message;$("productFormError").classList.add("show")}
  function clearError(){$("productFormError").textContent="";$("productFormError").classList.remove("show")}
  function setSaving(s){$("saveProductButton").disabled=s;$("saveProductButton").textContent=s?"Salvando...":"Salvar produto"}

  function fillTier(product,tier){
    const price=priceFor(product,tier);
    $(`${tier}UnitPrice`).value=price?.unit_price??0;
    $(`${tier}WholesaleMinimum`).value=price?.wholesale_minimum??"";
    $(`${tier}WholesalePrice`).value=price?.wholesale_price??"";
  }
  function materialOptions(selected=""){
    return `<option value="">Selecione...</option>`+materials.map(m=>`<option value="${m.id}" ${m.id===selected?"selected":""}>${esc(m.name)}</option>`).join("");
  }
  function addRecipeRow(recipe=null){
    const row=document.createElement("div"); row.className="recipe-row";
    row.innerHTML=`<div class="field"><label>Material</label><select class="recipe-material">${materialOptions(recipe?.material_id||"")}</select></div><div class="field"><label>Quantidade</label><input class="recipe-quantity" type="number" min="0.01" step="0.01" value="${recipe?.quantity_required??1}"></div><button class="icon-btn danger remove-recipe" type="button">Remover</button>`;
    row.querySelector(".remove-recipe").onclick=()=>row.remove();
    $("recipeRows").appendChild(row);
  }
  function openModal(product=null){
    clearError();$("productForm").reset();$("recipeRows").innerHTML="";
    $("productId").value=product?.id||"";$("productModalTitle").textContent=product?"Editar produto":"Novo produto";
    $("productName").value=product?.name||"";$("productCategory").value=product?.product_categories?.name||"";
    $("productDescription").value=product?.description||"";$("productImageUrl").value=product?.image_url||"";
    $("productIsActive").checked=product?.is_active??true;$("productIsPublic").checked=product?.is_public??true;$("productAllowsOrder").checked=product?.allows_order??true;
    TIERS.forEach(t=>fillTier(product,t));
    (product?.product_materials||[]).forEach(r=>addRecipeRow(r));
    if(!(product?.product_materials||[]).length) addRecipeRow();
    $("productModal").classList.add("open");$("productModal").setAttribute("aria-hidden","false");
  }
  function closeModal(){$("productModal").classList.remove("open");clearError()}

  async function loadReferences(){
    const [{data:c,error:ce},{data:m,error:me}]=await Promise.all([
      client.from("product_categories").select("id,name").order("name"),
      client.from("materials").select("id,name,is_active").eq("is_active",true).order("name")
    ]);
    if(ce)throw ce;if(me)throw me;categories=c||[];materials=m||[];
    $("categoryOptions").innerHTML=categories.map(x=>`<option value="${esc(x.name)}"></option>`).join("");
  }
  async function loadProducts(){
    const tbody=$("productsTable");tbody.innerHTML=`<tr><td colspan="8" class="loading-row">Carregando produtos...</td></tr>`;
    const {data,error}=await client.from("products").select(`
      id,name,description,image_url,is_active,is_public,allows_order,category_id,
      product_categories(name),
      product_prices(id,customer_type,unit_price,wholesale_minimum,wholesale_price),
      product_materials(id,material_id,quantity_required,materials(name))
    `).order("name");
    if(error){console.error(error);tbody.innerHTML=`<tr><td colspan="8" class="empty">Não foi possível carregar os produtos.</td></tr>`;return}
    products=data||[];render();
  }
  function displayPrice(product,tier){
    const p=priceFor(product,tier);if(!p)return"—";
    return `${money(p.unit_price)}${p.wholesale_minimum&&p.wholesale_price?`<div class="price-sub">${p.wholesale_minimum}+ ${money(p.wholesale_price)}</div>`:""}`;
  }
  function render(){
    const tbody=$("productsTable");
    tbody.innerHTML=products.map(p=>{
      const src=imageSrc(p.image_url);
      const image=src?`<img class="product-thumb" src="${esc(src)}" alt="${esc(p.name)}">`:`<div class="product-thumb-placeholder">${esc(p.name[0])}</div>`;
      return `<tr><td><div class="product-name-cell">${image}<div><strong>${esc(p.name)}</strong><div class="muted-caption">${p.product_materials?.length||0} material(is) na receita</div></div></div></td><td>${esc(p.product_categories?.name||"Sem categoria")}</td><td>${displayPrice(p,"cpf")}</td><td>${displayPrice(p,"cnpj")}</td><td>${displayPrice(p,"alianca")}</td><td>${displayPrice(p,"parceria")}</td><td><span class="badge ${p.is_active?"green":"red"}">${p.is_active?"Ativo":"Inativo"}</span></td><td><div class="table-actions"><button class="icon-btn edit" data-id="${p.id}">Editar</button><button class="icon-btn danger delete" data-id="${p.id}">Excluir</button></div></td></tr>`;
    }).join("")||`<tr><td colspan="8" class="empty">Nenhum produto cadastrado.</td></tr>`;
    document.querySelectorAll(".edit").forEach(b=>b.onclick=()=>openModal(products.find(p=>p.id===b.dataset.id)));
    document.querySelectorAll(".delete").forEach(b=>b.onclick=()=>softDelete(b.dataset.id));
  }
  async function categoryId(name){
    const normalized=name.trim();const found=categories.find(c=>c.name.toLowerCase()===normalized.toLowerCase());if(found)return found.id;
    const {data,error}=await client.from("product_categories").insert({name:normalized,is_active:true}).select("id,name").single();if(error)throw error;categories.push(data);return data.id;
  }
  function validateWholesale(min,price,label){if((min!=="")!==(price!==""))throw new Error(`Preencha mínimo e preço de atacado para ${label}, ou deixe ambos vazios.`)}
  function recipePayload(){
    const rows=[...document.querySelectorAll(".recipe-row")];const list=rows.map(r=>({material_id:r.querySelector(".recipe-material").value,quantity_required:Number(r.querySelector(".recipe-quantity").value)})).filter(x=>x.material_id&&x.quantity_required>0);
    const unique=new Set(list.map(x=>x.material_id));if(unique.size!==list.length)throw new Error("O mesmo material não pode aparecer duas vezes na receita.");return list;
  }
  async function save(event){
    event.preventDefault();clearError();setSaving(true);
    try{
      const id=$("productId").value||null;TIERS.forEach(t=>validateWholesale($(`${t}WholesaleMinimum`).value,$(`${t}WholesalePrice`).value,window.DistrictPricing.label(t)));
      const payload={category_id:await categoryId($("productCategory").value),name:$("productName").value.trim(),description:$("productDescription").value.trim()||null,image_url:$("productImageUrl").value.trim()||null,is_active:$("productIsActive").checked,is_public:$("productIsPublic").checked,allows_order:$("productAllowsOrder").checked};
      if(!id)payload.created_by=window.currentDistrictUser?.id||null;
      const {data,error}=await (id?client.from("products").update(payload).eq("id",id):client.from("products").insert(payload)).select("id").single();if(error)throw error;
      const prices=TIERS.map(t=>({product_id:data.id,customer_type:t,unit_price:Number($(`${t}UnitPrice`).value||0),wholesale_minimum:nnull($(`${t}WholesaleMinimum`).value),wholesale_price:nnull($(`${t}WholesalePrice`).value)}));
      const {error:pe}=await client.from("product_prices").upsert(prices,{onConflict:"product_id,customer_type"});if(pe)throw pe;
      const recipe=recipePayload();const {error:de}=await client.from("product_materials").delete().eq("product_id",data.id);if(de)throw de;
      if(recipe.length){const {error:re}=await client.from("product_materials").insert(recipe.map(x=>({...x,product_id:data.id})));if(re)throw re}
      closeModal();toast(id?"Produto e receita atualizados.":"Produto cadastrado.");await Promise.all([loadReferences(),loadProducts()]);
    }catch(e){console.error(e);showError(e.message||"Não foi possível salvar o produto.")}finally{setSaving(false)}
  }
  async function softDelete(id){
    const p=products.find(x=>x.id===id);if(!p)return;
    if(!confirm(`Remover ${p.name} do sistema?\n\nO histórico de encomendas será preservado e o produto poderá ser reativado editando o registro no banco.`))return;
    const {error}=await client.from("products").update({is_active:false,is_public:false,allows_order:false}).eq("id",id);
    if(error){toast("Não foi possível excluir o produto.");return}toast("Produto removido do catálogo.");loadProducts();
  }
  function bind(){
    $("newProductButton").onclick=()=>openModal();$("closeProductModal").onclick=closeModal;$("cancelProductButton").onclick=closeModal;
    $("addRecipeRow").onclick=()=>addRecipeRow();$("productForm").onsubmit=save;
  }
  document.addEventListener("district-auth-ready",async()=>{bind();try{await loadReferences();await loadProducts()}catch(e){console.error(e);toast("Erro ao iniciar produtos.")}},{once:true});
})();