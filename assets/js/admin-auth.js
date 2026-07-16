async function loadCurrentDistrictUser(user) {
  const client = window.distritoSupabase;
  const { data: profile, error: profileError } = await client
    .from("profiles")
    .select("name, email, is_active")
    .eq("id", user.id)
    .maybeSingle();

  if (profileError) console.error("Erro ao carregar perfil:", profileError);

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
    name: profile?.name || user.user_metadata?.name || user.email?.split("@")[0] || "Usuário",
    email: profile?.email || user.email || "",
    roles,
  };
}

function isDistrictAdmin(user) {
  return user.roles.includes("admin");
}

function isDistrictManager(user) {
  return user.roles.includes("gerente") || user.roles.includes("management");
}

function currentAdminSection() {
  const page = window.location.pathname.split("/").filter(Boolean).pop() || "admin";
  return page.replace(/\.html$/i, "");
}

function applyDistrictPermissions(user) {
  const isAdmin = isDistrictAdmin(user);
  const isManager = isDistrictManager(user);
  const allowedForManager = new Set(["admin", "index", "encomendas", "calculadora", "caixa"]);
  const section = currentAdminSection();

  document.querySelectorAll('[data-admin-only="true"]').forEach((element) => {
    element.hidden = !isAdmin;
  });

  if (!isAdmin && !isManager) {
    window.location.replace("/?error=access_denied");
    return false;
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

  const roleLabel = isDistrictAdmin(user)
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
