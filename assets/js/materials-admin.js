(() => {
  const client = window.distritoSupabase;
  let materials = [];
  const $ = id => document.getElementById(id);
  const num = value => Number(value || 0);
  const esc = value => String(value ?? "").replace(/[&<>'"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"}[c]));

  function showError(message) { $("materialFormError").textContent = message; $("materialFormError").classList.add("show"); }
  function clearError() { $("materialFormError").textContent = ""; $("materialFormError").classList.remove("show"); }
  function componentOptions(selected = "", editingId = "") {
    return `<option value="">Selecione...</option>${materials.filter(m => m.id !== editingId && m.is_active).map(m => `<option value="${m.id}" ${m.id === selected ? "selected" : ""}>${esc(m.name)}</option>`).join("")}`;
  }
  function addComponentRow(component = null) {
    const row = document.createElement("div");
    row.className = "recipe-row material-component-row";
    row.innerHTML = `<div class="field"><label>Componente</label><select class="component-material">${componentOptions(component?.component_material_id || "", $("materialId").value)}</select></div><div class="field"><label>Quantidade por unidade</label><input class="component-quantity" type="number" min="0.01" step="0.01" value="${component?.quantity_required ?? 1}"></div><button type="button" class="icon-btn danger remove-component">Remover</button>`;
    row.querySelector(".remove-component").onclick = () => row.remove();
    $("materialComponentRows").appendChild(row);
  }
  function toggleRecipe() {
    const enabled = $("materialIsProducible").checked;
    $("materialRecipeSection").hidden = !enabled;
    if (enabled && !$("materialComponentRows").children.length) addComponentRow();
  }
  function openModal(material = null) {
    $("materialForm").reset(); clearError(); $("materialComponentRows").innerHTML = "";
    $("materialId").value = material?.id || "";
    $("materialModalTitle").textContent = material ? "Editar material" : "Novo material";
    $("materialName").value = material?.name || ""; $("materialUnit").value = material?.unit || "unidade";
    $("materialDescription").value = material?.description || ""; $("materialStock").value = material?.stock_quantity ?? 0;
    $("materialMinimum").value = material?.minimum_stock ?? 0; $("materialIsActive").checked = material?.is_active ?? true;
    const recipe = material?.material_components || [];
    $("materialIsProducible").checked = recipe.length > 0;
    recipe.forEach(addComponentRow); toggleRecipe();
    $("materialModal").classList.add("open");
  }
  function closeModal() { $("materialModal").classList.remove("open"); }
  function recipePayload() {
    if (!$("materialIsProducible").checked) return [];
    const rows = [...document.querySelectorAll(".material-component-row")];
    const list = rows.map(row => ({ component_material_id: row.querySelector(".component-material").value, quantity_required: Number(row.querySelector(".component-quantity").value) })).filter(x => x.component_material_id && x.quantity_required > 0);
    if (!list.length) throw new Error("Adicione pelo menos um componente à receita.");
    if (new Set(list.map(x => x.component_material_id)).size !== list.length) throw new Error("O mesmo componente não pode aparecer duas vezes.");
    if (list.some(x => x.component_material_id === $("materialId").value)) throw new Error("Um material não pode usar ele mesmo na receita.");
    return list;
  }
  async function load() {
    const [{ data, error }, { data: components, error: componentsError }] = await Promise.all([
      client.from("materials").select("*").order("name"),
      client.from("material_components").select("id,material_id,component_material_id,quantity_required")
    ]);
    if (error || componentsError) { console.error(error || componentsError); toast("Erro ao carregar materiais."); return; }
    const rawMaterials = data || [];
    const byId = new Map(rawMaterials.map(item => [item.id, item]));
    materials = rawMaterials.map(item => ({ ...item, material_components: (components || []).filter(component => component.material_id === item.id).map(component => ({ ...component, component: byId.get(component.component_material_id) })) }));
    $("materialsTable").innerHTML = materials.map(m => {
      const available = num(m.stock_quantity) - num(m.reserved_quantity);
      const recipe = m.material_components || [];
      return `<tr><td><strong>${esc(m.name)}</strong><div class="muted-caption">${esc(m.description || "")}</div></td><td>${esc(m.unit)}</td><td>${m.stock_quantity}</td><td>${m.reserved_quantity}</td><td>${available}</td><td>${m.minimum_stock}</td><td>${recipe.length ? `<span class="badge status-in_production">Produzível · ${recipe.length}</span><div class="muted-caption">${recipe.map(r => esc(r.component?.name)).join(", ")}</div>` : `<span class="badge neutral">Básico</span>`}</td><td><span class="badge ${!m.is_active ? "red" : available <= num(m.minimum_stock) ? "yellow" : "green"}">${!m.is_active ? "Inativo" : available <= num(m.minimum_stock) ? "Estoque baixo" : "Normal"}</span></td><td><div class="table-actions"><button class="icon-btn edit" data-id="${m.id}">Editar</button><button class="icon-btn danger remove" data-id="${m.id}">Excluir</button></div></td></tr>`;
    }).join("") || `<tr><td colspan="9" class="empty">Nenhum material cadastrado.</td></tr>`;
    document.querySelectorAll(".edit").forEach(button => button.onclick = () => openModal(materials.find(m => m.id === button.dataset.id)));
    document.querySelectorAll(".remove").forEach(button => button.onclick = () => removeMaterial(button.dataset.id));
  }
  async function save(event) {
    event.preventDefault(); clearError();
    try {
      const id = $("materialId").value;
      const payload = { name: $("materialName").value.trim(), unit: $("materialUnit").value.trim(), description: $("materialDescription").value.trim() || null, stock_quantity: num($("materialStock").value), minimum_stock: num($("materialMinimum").value), is_active: $("materialIsActive").checked };
      const query = id ? client.from("materials").update(payload).eq("id", id) : client.from("materials").insert({ ...payload, created_by: window.currentDistrictUser?.id || null });
      const { data, error } = await query.select("id").single();
      if (error) throw error;
      const materialId = data.id;
      const recipe = recipePayload();
      const { error: deleteError } = await client.from("material_components").delete().eq("material_id", materialId);
      if (deleteError) throw deleteError;
      if (recipe.length) {
        const { error: recipeError } = await client.from("material_components").insert(recipe.map(item => ({ ...item, material_id: materialId })));
        if (recipeError) throw recipeError;
      }
      closeModal(); toast(id ? "Material e receita atualizados." : "Material cadastrado."); await load();
    } catch (error) { console.error(error); showError(error.message || "Não foi possível salvar o material."); }
  }
  async function removeMaterial(id) {
    const material = materials.find(item => item.id === id);
    if (!confirm(`Excluir o material ${material.name}? Se estiver em uma receita, a exclusão será bloqueada.`)) return;
    const { error } = await client.from("materials").delete().eq("id", id);
    if (error) return toast("O material está sendo usado em uma receita. Desative-o em vez de excluir.");
    toast("Material excluído."); await load();
  }
  function bind() {
    $("newMaterialButton").onclick = () => openModal(); $("closeMaterialModal").onclick = closeModal; $("cancelMaterialButton").onclick = closeModal;
    $("materialForm").onsubmit = save; $("materialIsProducible").onchange = toggleRecipe; $("addMaterialComponent").onclick = () => addComponentRow();
  }
  document.addEventListener("district-auth-ready", () => { bind(); load(); }, { once: true });
})();
