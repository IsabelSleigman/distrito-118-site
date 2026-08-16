async function loadCurrentDistrictUser(user) {
  const client = window.distritoSupabase;
  const { data: profile, error: profileError } = await client
    .from("profiles")
    .select("name, email, is_active, must_change_password")
    .eq("id", user.id)
    .maybeSingle();

  if (profileError) console.error("Erro ao carregar perfil:", profileError);

  const { data: member, error: memberError } = await client
    .from("members")
    .select("name,email,access_level,status")
    .eq("profile_id", user.id)
    .maybeSingle();
  if (memberError) console.error("Erro ao carregar cadastro do membro:", memberError);

  if (profile && profile.is_active === false) {
    await client.auth.signOut();
    window.location.replace("/login?error=inactive");
    return null;
  }

  const { data: roleRows, error: roleError } = await client
    .from("profile_roles")
    .select("user_roles(name)")
    .eq("profile_id", user.id);

  if (roleError) console.error("Erro ao carregar permissões:", roleError);

  const roles = (roleRows || [])
    .map((row) => String(row.user_roles?.name || "").toLowerCase())
    .filter(Boolean);

  return {
    id: user.id,
    name: member?.name || profile?.name || user.user_metadata?.name || user.email?.split("@")[0] || "Usuário",
    email: member?.email || profile?.email || user.email || "",
    accessLevel: member?.access_level || null,
    mustChangePassword: profile?.must_change_password === true,
    roles,
  };
}

function isDistrictAdmin(user) {
  return user.roles.some(role => ["admin", "lideranca", "01", "02", "03"].includes(role));
}

function isDistrictManager(user) {
  return user.roles.includes("gerente") || user.roles.includes("gerencia") || user.roles.includes("management") || user.accessLevel === "gerencia";
}

function isDistrictMember(user) { return user.roles.includes("membro") || user.accessLevel === "membro"; }

function currentAdminSection() {
  const page = window.location.pathname.split("/").filter(Boolean).pop() || "admin";
  return page.replace(/\.html$/i, "");
}

function ensureUsersNavigation() {
  const nav = document.querySelector(".sidebar-nav");
  if (!nav) return;
  const add = (href, icon, label, beforeSelector, adminOnly = false) => {
    if (nav.querySelector(`a[href="${href}"]`)) return;
    const link = document.createElement("a");
    link.href = href;
    if (adminOnly) link.dataset.adminOnly = "true";
    link.innerHTML = `<i data-lucide="${icon}"></i><span>${label}</span>`;
    nav.insertBefore(link, nav.querySelector(beforeSelector) || nav.lastElementChild);
  };
  add("/admin/usuarios", "users", "Usuários", 'a[href="/admin/produtos"]', true);
  add("/admin/categorias", "tags", "Categorias", 'a[href="/admin/estoque"]', true);
  add("/admin/caixa", "banknote", "Caixa", 'a[href="/"]');
}

function applyDistrictPermissions(user) {
  ensureUsersNavigation();
  const isAdmin = isDistrictAdmin(user);
  const isManager = isDistrictManager(user);
  const isMember = isDistrictMember(user);
  const allowedForManager = new Set(["admin", "index", "encomendas", "metas", "calculadora", "caixa"]);
  const section = currentAdminSection();

  document.querySelectorAll('[data-admin-only="true"]').forEach((element) => {
    element.hidden = !isAdmin;
  });

  if (!isAdmin && !isManager && !isMember) {
    window.distritoSupabase.auth.signOut().finally(() => window.location.replace("/login?error=access_denied"));
    return false;
  }

  if (isMember && !isAdmin && !isManager && section !== "calculadora") {
    window.location.replace("/admin/calculadora"); return false;
  }

  if (!isAdmin && !allowedForManager.has(section)) {
    window.location.replace("/admin?error=access_denied");
    return false;
  }

  return true;
}

function renderDistrictUser(user) {
  const sidebar = document.querySelector(".sidebar");
  if (!sidebar || document.getElementById("districtUserPanel")) return;

  const roleLabel = user.accessLevel && ["01","02","03"].includes(user.accessLevel)
    ? `Liderança ${user.accessLevel}`
    : isDistrictAdmin(user)
      ? "Administrador"
    : isDistrictManager(user)
      ? "Gerente"
      : "Membro";

  const panel = document.createElement("div");
  panel.id = "districtUserPanel";
  panel.className = "sidebar-user";
  panel.innerHTML = `
    <div class="sidebar-user-avatar">${user.name.slice(0, 1).toUpperCase()}</div>
    <div class="sidebar-user-info">
      <strong>${user.name}</strong>
      <span>${roleLabel}</span>
    </div>
    <button id="districtLogoutButton" type="button" class="sidebar-logout" title="Sair"><i data-lucide="log-out"></i></button>
  `;
  sidebar.appendChild(panel);
  window.lucide?.createIcons();

  document.getElementById("districtLogoutButton").addEventListener("click", async () => {
    const button = document.getElementById("districtLogoutButton");
    button.disabled = true;
    await window.distritoSupabase.auth.signOut();
    window.location.replace("/login");
  });
}

async function protectDistrictAdmin() {
  document.documentElement.classList.add("auth-checking");

  const { data: { session }, error } = await window.distritoSupabase.auth.getSession();
  if (error) console.error("Erro ao verificar sessão:", error);

  if (!session) {
    const page = currentAdminSection();
    const target = page === "admin" ? "index" : page;
    window.location.replace(`/login?redirect=${encodeURIComponent(target)}`);
    return;
  }

  const currentUser = await loadCurrentDistrictUser(session.user);
  if (!currentUser) return;
  if (currentUser.mustChangePassword) { window.location.replace("/alterar-senha"); return; }

  window.currentDistrictUser = currentUser;
  if (!applyDistrictPermissions(currentUser)) return;
  renderDistrictUser(currentUser);
  document.documentElement.classList.remove("auth-checking");
  document.documentElement.classList.add("auth-ready");
  document.dispatchEvent(new CustomEvent("district-auth-ready", { detail: currentUser }));
}

window.distritoSupabase.auth.onAuthStateChange((event, session) => {
  if (event === "SIGNED_OUT" || !session) {
    window.location.replace("/login");
  }
});

protectDistrictAdmin();
