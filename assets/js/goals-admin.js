(() => {
  const client = window.distritoSupabase;
  const money = value => Number(value || 0).toLocaleString("pt-BR", { style: "currency", currency: "BRL", maximumFractionDigits: 0 });
  const esc = value => String(value ?? "").replace(/[&<>'"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"}[c]));
  let goals = [];
  let members = [];
  let currentGoal = null;
  let inventoryItems = [];
  let progressRows = [];

  function addRequirementRow() {
    const row = document.createElement("div");
    row.className = "goal-requirement-row";
    row.innerHTML = `<select class="goal-requirement-item" required><option value="">Selecione...</option>${inventoryItems.map(i => `<option value="${esc(i.item_id)}">${esc(i.name)}</option>`).join("")}</select><input class="goal-requirement-quantity" type="number" min="0.01" step="0.01" required placeholder="Quantidade"><button class="icon-btn danger" type="button">×</button>`;
    row.querySelector("button").addEventListener("click", () => row.remove());
    document.getElementById("goalRequirementRows").appendChild(row);
  }

  function isoDate(date) {
    const y = date.getFullYear();
    const m = String(date.getMonth() + 1).padStart(2, "0");
    const d = String(date.getDate()).padStart(2, "0");
    return `${y}-${m}-${d}`;
  }

  function defaultWednesdayPeriod() {
    const now = new Date();
    now.setHours(12, 0, 0, 0);
    const day = now.getDay();
    const daysSinceWednesday = (day - 3 + 7) % 7;
    const start = new Date(now);
    start.setDate(now.getDate() - daysSinceWednesday);
    const end = new Date(start);
    end.setDate(start.getDate() + 7);
    return [isoDate(start), isoDate(end)];
  }

  function formatDate(value) {
    if (!value) return "—";
    const [y, m, d] = value.split("-").map(Number);
    return new Date(y, m - 1, d).toLocaleDateString("pt-BR");
  }

  function statusFor(member) {
    const paid = Number(member.amount_paid || 0);
    const target = Number(currentGoal?.target_amount || 0);
    if (paid >= target && target > 0) return { key: "paid", label: "Pago", className: "green" };
    if (paid > 0) return { key: "partial", label: "Parcial", className: "warning" };
    return { key: "pending", label: "Pendente", className: "red" };
  }

  function openGoalModal() {
    const [start, end] = defaultWednesdayPeriod();
    document.getElementById("goalForm").reset();
    document.getElementById("goalFormTitle").value = "Meta semanal";
    document.getElementById("goalStartDate").value = start;
    document.getElementById("goalEndDate").value = end;
    document.getElementById("goalRequirementRows").innerHTML = "";
    addRequirementRow();
    document.getElementById("goalModal").classList.add("open");
  }

  function closeGoalModal() {
    document.getElementById("goalModal").classList.remove("open");
  }

  async function loadGoals(preferredId = null) {
    const { data, error } = await client.from("weekly_goals").select("id,title,start_date,end_date,target_amount,status,created_at").order("start_date", { ascending: false });
    if (error) {
      console.error(error);
      toast(error.message || "Não foi possível carregar as metas.");
      return;
    }
    goals = data || [];
    if (!goals.length) {
      document.getElementById("goalEmpty").hidden = false;
      document.getElementById("goalWorkspace").hidden = true;
      return;
    }

    document.getElementById("goalEmpty").hidden = true;
    document.getElementById("goalWorkspace").hidden = false;
    const active = goals.find(goal => goal.status === "active");
    const selected = goals.find(goal => goal.id === preferredId) || active || goals[0];
    currentGoal = selected;

    const selector = document.getElementById("goalSelector");
    selector.innerHTML = goals.map(goal => `<option value="${esc(goal.id)}" ${goal.id === selected.id ? "selected" : ""}>${formatDate(goal.start_date)} → ${formatDate(goal.end_date)}${goal.status === "active" ? " · atual" : ""}</option>`).join("");
    await loadMembers();
  }

  async function loadMembers() {
    if (!currentGoal) return;
    const tbody = document.getElementById("goalMembersTable");
    tbody.innerHTML = `<tr><td colspan="6" class="loading-row">Carregando membros...</td></tr>`;
    const { data, error } = await client.from("weekly_goal_members").select("id,goal_id,profile_id,member_name,discord_user_id,amount_paid,paid_at,notes,status,updated_at").eq("goal_id", currentGoal.id).order("member_name");
    if (error) {
      console.error(error);
      tbody.innerHTML = `<tr><td colspan="6" class="empty">Não foi possível carregar os membros.</td></tr>`;
      return;
    }
    members = data || [];
    const { data: progress } = await client.from("weekly_goal_member_progress").select("member_id,item_name,required_quantity,credited_quantity,remaining_quantity,extra_quantity").eq("goal_id", currentGoal.id).order("item_name");
    progressRows = progress || [];
    render();
  }

  function render() {
    document.getElementById("goalTitle").textContent = currentGoal.title || "Meta semanal";
    document.getElementById("goalPeriod").textContent = `${formatDate(currentGoal.start_date)} → ${formatDate(currentGoal.end_date)} · ${currentGoal.status === "active" ? "Semana atual" : "Histórico"}`;
    document.getElementById("goalTarget").textContent = money(currentGoal.target_amount);
    document.getElementById("goalMembersTotal").textContent = `${members.length} membro${members.length === 1 ? "" : "s"}`;

    const participating = members.filter(member => !["absent","excused"].includes(member.status));
    const memberComplete = member => { const rows=progressRows.filter(p=>p.member_id===member.id); return rows.length ? rows.every(p=>Number(p.remaining_quantity)===0) : statusFor(member).key==="paid"; };
    const paidCount = participating.filter(memberComplete).length;
    const partialCount = participating.filter(member => !memberComplete(member) && progressRows.some(p=>p.member_id===member.id && Number(p.credited_quantity)>0)).length;
    const pendingCount = participating.length-paidCount-partialCount;
    document.getElementById("goalPaidCount").textContent = paidCount;
    document.getElementById("goalPartialCount").textContent = partialCount;
    document.getElementById("goalPendingCount").textContent = pendingCount;
    document.getElementById("goalPaidPercent").textContent = `${members.length ? Math.round((paidCount / members.length) * 100) : 0}% da equipe`;

    const tbody = document.getElementById("goalMembersTable");
    tbody.innerHTML = members.map(member => {
      const state = member.status === "absent" ? {label:"Ausência",className:"warning"} : member.status === "debt" ? {label:"Em débito",className:"red"} : statusFor(member);
      const paid = Number(member.amount_paid || 0);
      const target = Number(currentGoal.target_amount || 0);
      const progress = target ? Math.min(100, Math.round((paid / target) * 100)) : 0;
      const itemProgress = progressRows.filter(p=>p.member_id===member.id);
      const progressHtml = itemProgress.length ? itemProgress.map(p=>`<div class="muted-caption"><strong>${esc(p.item_name)}</strong>: ${Number(p.credited_quantity)}/${Number(p.required_quantity)}${Number(p.extra_quantity)>0?` · +${Number(p.extra_quantity)} extra`:Number(p.remaining_quantity)>0?` · faltam ${Number(p.remaining_quantity)}`:" · ✓"}</div>`).join("") : `<div class="goal-progress"><div class="goal-progress-track"><span style="width:${progress}%"></span></div><small>${progress}%</small></div>`;
      return `<tr data-member-id="${esc(member.id)}">
        <td><strong>${esc(member.member_name)}</strong>${member.discord_user_id ? `<div class="muted-caption">Discord: ${esc(member.discord_user_id)}</div>` : ""}</td>
        <td><input class="goal-payment-input" type="number" min="0" step="1" value="${paid}" aria-label="Valor pago por ${esc(member.member_name)}"></td>
        <td>${money(target)}</td>
        <td>${progressHtml}</td>
        <td><select class="goal-member-status"><option value="in_progress" ${member.status === "in_progress" ? "selected" : ""}>Em andamento</option><option value="absent" ${member.status === "absent" ? "selected" : ""}>Ausência</option><option value="excused" ${member.status === "excused" ? "selected" : ""}>Dispensado</option><option value="debt" ${member.status === "debt" ? "selected" : ""}>Em débito</option><option value="completed" ${member.status === "completed" ? "selected" : ""}>Concluída</option><option value="completed_with_extra" ${member.status === "completed_with_extra" ? "selected" : ""}>Com excedente</option></select><div><span class="badge ${state.className}">${state.label}</span></div></td>
        <td><div class="table-actions"><button class="icon-btn save-goal-payment" type="button">Salvar</button><button class="icon-btn danger remove-goal-member" type="button">Remover</button></div></td>
      </tr>`;
    }).join("") || `<tr><td colspan="6" class="empty">Nenhum membro nesta semana.</td></tr>`;
  }

  async function savePayment(row) {
    const memberId = row.dataset.memberId;
    const amount = Number(row.querySelector(".goal-payment-input").value || 0);
    const button = row.querySelector(".save-goal-payment");
    button.disabled = true; button.textContent = "Salvando...";
    try {
      const { error } = await client.rpc("set_weekly_goal_payment", { p_member_id: memberId, p_amount: amount, p_note: null });
      if (error) throw error;
      toast("Pagamento da meta atualizado.");
      await loadMembers();
    } catch (error) {
      console.error(error);
      toast(error.message || "Não foi possível atualizar a meta.");
    } finally {
      button.disabled = false; button.textContent = "Salvar";
    }
  }

  function bindEvents() {
    document.getElementById("newGoalButton")?.addEventListener("click", openGoalModal);
    document.getElementById("emptyNewGoalButton")?.addEventListener("click", openGoalModal);
    document.getElementById("closeGoalModal")?.addEventListener("click", closeGoalModal);
    document.getElementById("cancelGoalModal")?.addEventListener("click", closeGoalModal);
    document.getElementById("addGoalRequirement")?.addEventListener("click", addRequirementRow);
    document.getElementById("goalSelector")?.addEventListener("change", async event => {
      currentGoal = goals.find(goal => goal.id === event.target.value) || currentGoal;
      await loadMembers();
    });

    document.getElementById("goalStartDate")?.addEventListener("change", event => {
      if (!event.target.value) return;
      const [y, m, d] = event.target.value.split("-").map(Number);
      const end = new Date(y, m - 1, d);
      end.setDate(end.getDate() + 7);
      document.getElementById("goalEndDate").value = isoDate(end);
    });

    document.getElementById("goalForm")?.addEventListener("submit", async event => {
      event.preventDefault();
      const button = event.currentTarget.querySelector('button[type="submit"]');
      button.disabled = true; button.textContent = "Criando...";
      try {
        const requirements = [...document.querySelectorAll(".goal-requirement-row")].map(row => ({ item_id: row.querySelector(".goal-requirement-item").value, quantity: Number(row.querySelector(".goal-requirement-quantity").value) })).filter(x => x.item_id && x.quantity > 0);
        const { data, error } = await client.rpc("create_weekly_goal_v2", {
          p_start_date: document.getElementById("goalStartDate").value,
          p_end_date: document.getElementById("goalEndDate").value,
          p_target_amount: Number(document.getElementById("goalTargetAmount").value || 0), p_reward_name: document.getElementById("goalRewardName").value.trim() || null,
          p_requirements: requirements, p_title: document.getElementById("goalFormTitle").value.trim() || "Meta semanal"
        });
        if (error) throw error;
        closeGoalModal();
        toast(`Nova meta criada com ${data?.members_added || 0} membro(s).`);
        await loadGoals(data?.id);
      } catch (error) {
        console.error(error);
        toast(error.message || "Não foi possível criar a meta.");
      } finally {
        button.disabled = false; button.textContent = "Criar semana";
      }
    });

    document.getElementById("syncGoalMembers")?.addEventListener("click", async event => {
      if (!currentGoal) return;
      const button = event.currentTarget;
      button.disabled = true;
      try {
        const { data, error } = await client.rpc("sync_weekly_goal_members", { p_goal_id: currentGoal.id });
        if (error) throw error;
        toast(data?.members_added ? `${data.members_added} novo(s) membro(s) adicionado(s).` : "A lista já está sincronizada.");
        await loadMembers();
      } catch (error) { console.error(error); toast(error.message || "Não foi possível sincronizar."); }
      finally { button.disabled = false; }
    });

    document.getElementById("addGoalMemberForm")?.addEventListener("submit", async event => {
      event.preventDefault();
      if (!currentGoal) return;
      const name = document.getElementById("goalMemberName").value.trim();
      const discord = document.getElementById("goalMemberDiscord").value.trim();
      const button = event.currentTarget.querySelector("button");
      button.disabled = true;
      try {
        const { error } = await client.rpc("add_weekly_goal_member", { p_goal_id: currentGoal.id, p_member_name: name, p_discord_user_id: discord || null });
        if (error) throw error;
        event.currentTarget.reset();
        toast("Membro adicionado à semana.");
        await loadMembers();
      } catch (error) { console.error(error); toast(error.message || "Não foi possível adicionar o membro."); }
      finally { button.disabled = false; }
    });

    document.getElementById("goalMembersTable")?.addEventListener("click", async event => {
      const row = event.target.closest("tr[data-member-id]");
      if (!row) return;
      if (event.target.closest(".save-goal-payment")) return savePayment(row);
      if (event.target.closest(".remove-goal-member")) {
        const member = members.find(item => item.id === row.dataset.memberId);
        if (!confirm(`Remover ${member?.member_name || "este membro"} desta meta?`)) return;
        const { error } = await client.rpc("remove_weekly_goal_member", { p_member_id: row.dataset.memberId });
        if (error) return toast(error.message || "Não foi possível remover.");
        toast("Membro removido da semana.");
        await loadMembers();
      }
    });
    document.getElementById("goalMembersTable")?.addEventListener("change", async event => {
      if (!event.target.matches(".goal-member-status")) return;
      const row = event.target.closest("tr[data-member-id]");
      const { error } = await client.rpc("set_weekly_goal_member_status", { p_member_id: row.dataset.memberId, p_status: event.target.value, p_reason: null });
      if (error) toast(error.message || "Não foi possível alterar a situação."); else { toast("Situação atualizada."); await loadMembers(); }
    });
  }

  document.addEventListener("district-auth-ready", async () => {
    if (window.currentDistrictUser?.accessLevel === "membro") {
      const { data, error } = await client.rpc("get_my_member_dashboard");
      const main=document.querySelector(".admin-main"),g=data?.goal;
      if(error){main.innerHTML=`<section class="panel"><h2>Minha Meta</h2><p>${esc(error.message)}</p></section>`;return}
      main.innerHTML=`<div class="admin-top"><div><span class="eyebrow">Acompanhamento pessoal</span><h1>Minha Meta</h1><p class="page-subtitle">Somente você e a gestão podem consultar estes dados.</p></div></div><section class="panel member-goal-card">${g?`<div class="section-head"><div><span class="eyebrow">Semana atual</span><h2>${esc(g.title)}</h2><p>${formatDate(g.start_date)} → ${formatDate(g.end_date)}</p></div><span class="badge neutral">${esc(g.member_status||"Em andamento")}</span></div><div class="member-requirements">${(g.requirements||[]).map(r=>`<div><span>${esc(r.item_name)}</span><strong>${Number(r.credited)}/${Number(r.required)}</strong><small>${Number(r.remaining)>0?`Faltam ${Number(r.remaining)}`:Number(r.extra)>0?`+${Number(r.extra)} para a próxima`:"Concluído ✓"}</small></div>`).join("")||"<p>Nenhum item obrigatório.</p>"}</div>${g.reward_name?`<p class="member-reward">Premiação: <strong>${esc(g.reward_name)}</strong></p>`:""}<h3>Últimas entregas</h3><div class="member-submissions">${(g.submissions||[]).map(s=>`<div><span>${new Date(s.submitted_at).toLocaleString("pt-BR")}</span><strong>${esc(s.status)}</strong></div>`).join("")||"<p>Nenhuma entrega registrada.</p>"}</div>`:`<h2>Nenhuma meta ativa</h2><p>Quando uma nova semana for criada, ela aparecerá aqui.</p>`}</section>`;
      return;
    }
    bindEvents();
    const { data } = await client.from("inventory_catalog").select("item_id,name").order("name");
    inventoryItems = data || [];
    await loadGoals();
    window.lucide?.createIcons();
  }, { once: true });
})();
