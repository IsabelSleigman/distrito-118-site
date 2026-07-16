(() => {
  const ensure = () => {
    let el=document.getElementById("globalPageLoader");
    if(el) return el;
    el=document.createElement("div");
    el.id="globalPageLoader";
    el.className="global-page-loader";
    el.innerHTML=`<div class="global-loader-card"><img src="${location.pathname.startsWith('/admin')?'../':''}assets/images/logo-distrito.png" alt="Distrito"><div class="global-loader-spinner"></div><strong>DISTRITO 118</strong><p id="globalLoaderMessage">Carregando dados operacionais...</p><button id="globalLoaderRetry" class="btn ghost small" type="button" hidden>Tentar novamente</button></div>`;
    document.body.prepend(el);
    el.querySelector("#globalLoaderRetry").addEventListener("click",()=>location.reload());
    return el;
  };
  const api={
    show(message="Carregando dados operacionais..."){const el=ensure();el.classList.remove("is-hidden","is-error");el.querySelector("#globalLoaderMessage").textContent=message;el.querySelector("#globalLoaderRetry").hidden=true;},
    hide(){const el=ensure();el.classList.add("is-hidden");document.documentElement.classList.remove("app-loading");},
    error(message="Não foi possível carregar os dados."){const el=ensure();el.classList.remove("is-hidden");el.classList.add("is-error");el.querySelector("#globalLoaderMessage").textContent=message;el.querySelector("#globalLoaderRetry").hidden=false;}
  };
  window.DistrictLoader=api;
  document.documentElement.classList.add("app-loading");
  if(document.readyState==="loading")document.addEventListener("DOMContentLoaded",()=>api.show());else api.show();
  document.addEventListener("district-page-ready",()=>api.hide(),{once:true});
  document.addEventListener("district-auth-ready",()=>setTimeout(()=>api.hide(),900),{once:true});
  window.addEventListener("load",()=>{if(!location.pathname.startsWith('/admin'))setTimeout(()=>api.hide(),900);},{once:true});
  setTimeout(()=>api.hide(),10000);
})();
