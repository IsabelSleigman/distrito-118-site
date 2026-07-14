async function redirectAuthenticatedUser() {
  const { data: { session } } = await window.distritoSupabase.auth.getSession();
  if (session) {
    const params = new URLSearchParams(window.location.search);
    const redirect = (params.get("redirect") || "").replace(/\.html$/i, "");
    const target = redirect && redirect !== "index" ? `/admin/${encodeURIComponent(redirect)}` : "/admin";
    window.location.replace(target);
  }
}

function loginMessage(text, type = "error") {
  const box = document.getElementById("loginMessage");
  box.textContent = text;
  box.className = `login-message ${type}`;
  box.hidden = false;
}

async function setupDistrictLogin() {
  await redirectAuthenticatedUser();

  const params = new URLSearchParams(window.location.search);
  if (params.get("error") === "inactive") {
    loginMessage("Seu acesso está desativado. Procure a administração.");
  }

  const form = document.getElementById("loginForm");
  const button = document.getElementById("loginButton");

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    button.disabled = true;
    button.textContent = "Entrando...";
    document.getElementById("loginMessage").hidden = true;

    const email = document.getElementById("loginEmail").value.trim();
    const password = document.getElementById("loginPassword").value;

    const { error } = await window.distritoSupabase.auth.signInWithPassword({ email, password });

    if (error) {
      console.error(error);
      loginMessage("E-mail ou senha incorretos.");
      button.disabled = false;
      button.textContent = "Entrar no painel";
      return;
    }

    loginMessage("Acesso autorizado. Abrindo o painel...", "success");
    const redirect = (params.get("redirect") || "").replace(/\.html$/i, "");
    const target = redirect && redirect !== "index" ? `/admin/${encodeURIComponent(redirect)}` : "/admin";
    window.location.replace(target);
  });
}

setupDistrictLogin();
