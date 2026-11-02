// Funciones compartidas por la pantalla de marcaje y el panel.
(function () {
  const CFG = window.ASISTENCIA_CONFIG || {};
  const TZ = CFG.zonaHoraria || "America/Guatemala";
  const listo = !!(CFG.supabaseUrl && CFG.supabaseAnonKey && window.supabase);
  const sb = listo
    ? window.supabase.createClient(CFG.supabaseUrl, CFG.supabaseAnonKey, { auth: { persistSession: false } })
    : null;

  const fHora = new Intl.DateTimeFormat("es-GT", { timeZone: TZ, hour: "2-digit", minute: "2-digit", hour12: false });
  const fSeg = new Intl.DateTimeFormat("es-GT", { timeZone: TZ, hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false });
  const fLarga = new Intl.DateTimeFormat("es-GT", { timeZone: TZ, weekday: "long", day: "numeric", month: "long", year: "numeric" });
  const fDia = new Intl.DateTimeFormat("en-CA", { timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit" });

  let offset = 0; // hora del servidor - hora del celular (ms)

  const A = {
    sb, listo, TZ,
    ahora: () => Date.now() + offset,
    async sincronizar() {
      if (!sb) return false;
      try {
        const t0 = Date.now();
        const { data, error } = await sb.rpc("hora_servidor");
        if (error || !data) return false;
        const t1 = Date.now();
        offset = Date.parse(data) - (t0 + t1) / 2;
        return true;
      } catch (e) { return false; }
    },
    hora: (v) => fHora.format(new Date(v)),
    horaSeg: (v) => fSeg.format(new Date(v)),
    fechaLarga: (v) => fLarga.format(new Date(v)),
    diaDe: (v) => fDia.format(new Date(v)), // YYYY-MM-DD en hora de Guatemala
    dur(ms) { const m = Math.max(0, Math.round(ms / 60000)); return Math.floor(m / 60) + " h " + String(m % 60).padStart(2, "0") + " min"; },
    horas: (ms) => Math.round(ms / 36000) / 100,
    limpiar: (s) => s.replace(/\s+/g, " ").trim().replace(/(^|\s|-)(\p{L})/gu, (m, p, c) => p + c.toUpperCase()),
    validoNombre: (s) => /^[\p{L}][\p{L}' .-]{1,49}$/u.test(s),
    validoEmpresa: (s) => /^[\p{L}\p{N}][\p{L}\p{N}' .,&()\/-]{1,79}$/u.test(s),
    norm: (s) => s.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().replace(/\s+/g, " ").trim(),
    esc: (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]),
    mensaje(el, tipo, txt) { el.className = "msg " + tipo; el.textContent = txt; el.hidden = !txt; },
  };
  window.Asistencia = A;
})();
