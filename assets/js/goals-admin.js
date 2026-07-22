(() => {
  const client = window.distritoSupabase;
  const money = value => Number(value || 0).toLocaleString("pt-BR", { style: "currency", currency: "BRL", maximumFractionDigits: 0 });
  const esc = value => String(value ?? "").replace(/[&<>'"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"}[c]));
  let goals = [];
  let members = [];
  let currentGoal = null;

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
    const { data, error } = await client.from("weekly_goal_members").select("id,goal_id,profile_id,member_name,discord_user_id,amount_paid,paid_at,notes,updated_at").eq("goal_id", currentGoal.id).order("member_name");
    if (error) {
      console.error(error);
      tbody.innerHTML = `<tr><td colspan="6" class="empty">Não foi possível carregar os membros.</td></tr>`;
      return;
    }
    members = data || [];
    render();
  }

  function render() {
    document.getElementById("goalTitle").textContent = currentGoal.title || "Meta semanal";
    document.getElementById("goalPeriod").textContent = `${formatDate(currentGoal.start_date)} → ${formatDate(currentGoal.end_date)} · ${currentGoal.status === "active" ? "Semana atual" : "Histórico"}`;
    document.getElementById("goalTarget").textContent = money(currentGoal.target_amount);
    document.getElementById("goalMembersTotal").textContent = `${members.length} membro${members.length === 1 ? "" : "s"}`;

    const paidCount = members.filter(member => statusFor(member).key === "paid").length;
    const partialCount = members.filter(member => statusFor(member).key === "partial").length;
    const pendingCount = members.filter(member => statusFor(member).key === "pending").length;
    document.getElementById("goalPaidCount").textContent = paidCount;
    document.getElementById("goalPartialCount").textContent = partialCount;
    document.getElementById("goalPendingCount").textContent = pendingCount;
    document.getElementById("goalPaidPercent").textContent = `${members.length ? Math.round((paidCount / members.length) * 100) : 0}% da equipe`;

    const tbody = document.getElementById("goalMembersTable");
    tbody.innerHTML = members.map(member => {
      const state = statusFor(member);
      const paid = Number(member.amount_paid || 0);
      const target = Number(currentGoal.target_amount || 0);
      const progress = target ? Math.min(100, Math.round((paid / target) * 100)) : 0;
      return `<tr data-member-id="${esc(member.id)}">
        <td><strong>${esc(member.member_name)}</strong>${member.discord_user_id ? `<div class="muted-caption">Discord: ${esc(member.discord_user_id)}</div>` : ""}</td>
        <td><input class="goal-payment-input" type="number" min="0" step="1" value="${paid}" aria-label="Valor pago por ${esc(member.member_name)}"></td>
        <td>${money(target)}</td>
        <td><div class="goal-progress"><div class="goal-progress-track"><span style="width:${progress}%"></span></div><small>${progress}%</small></div></td>
        <td><span class="badge ${state.className}">${state.label}</span>${member.paid_at ? `<div class="muted-caption">${new Date(member.paid_at).toLocaleString("pt-BR")}</div>` : ""}</td>
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
        const { data, error } = await client.rpc("create_weekly_goal", {
          p_start_date: document.getElementById("goalStartDate").value,
          p_end_date: document.getElementById("goalEndDate").value,
          p_target_amount: Number(document.getElementById("goalTargetAmount").value),
          p_title: document.getElementById("goalFormTitle").value.trim() || "Meta semanal"
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
  }

  document.addEventListener("district-auth-ready", async () => {
    bindEvents();
    await loadGoals();
    window.lucide?.createIcons();
  }, { once: true });
})();
