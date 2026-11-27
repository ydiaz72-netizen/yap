// PonteTalk · send-nudge
// Sends the branded "add your languages" email through Resend.
// Only admins can use it: the admin check happens in the database (pt_admin_incomplete / pt_admin_nudge).
// Secret needed in Supabase → Edge Functions → Secrets:  RESEND_API_KEY = re_...
// Body: { kind?: "langs"|"times", lang: "en"|"es"|"de", ids?: string[], preview?: true, test?: true }

const APP = "https://pontetalk.setzio.com";
const LINKS: Record<string, string> = { langs: APP + "/?go=languages", times: APP + "/?go=times" };
const FROM = "PonteTalk <noreply@setzio.com>";
const REPLY = "yvette@setzio.com";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const esc = (s: string) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

const T: Record<string, any> = {
  en: {
    subject: "One step left: which languages do you speak? 🌉",
    pre: "Add your languages in 30 seconds and we'll match you with people to practise with.",
    hi: (n: string) => n ? `Hi ${n},` : "Hi there,",
    p1: "Welcome to PonteTalk, we're so glad you're here! 🎉",
    p2: "There's just one thing missing: <b>your languages</b>. Without them we can't show you people to practise with.",
    btn: "Add my languages",
    time: "Takes about 30 seconds",
    after: "Once that's done, you'll get:",
    b: [["🤝", "Partners", "people who speak what you're learning, and want to learn what you speak"],
        ["☕", "Sessions & lounges", "relaxed practice rooms for your language pair"],
        ["🎮", "Games", "flashcards, Split or Stick, Hangman and more, at your level"]],
    sign: "See you on the bridge,",
    team: "Yvette & the PonteTalk team",
    beta: "PonteTalk is a free beta. Ideas or problems? Just reply to this email, I read every one.",
    why: "You're getting this email because you created a PonteTalk account.",
    stop: "Don't want emails like this? Reply \"stop\" and we won't send them again.",
    link: "Button not working? Copy this link:",
  },
  es: {
    subject: "Te falta un paso: ¿qué idiomas hablas? 🌉",
    pre: "Añade tus idiomas en 30 segundos y te mostraremos personas con quienes practicar.",
    hi: (n: string) => n ? `Hola ${n}:` : "¡Hola!",
    p1: "¡Bienvenido/a a PonteTalk, qué alegría tenerte aquí! 🎉",
    p2: "Solo falta una cosa: <b>tus idiomas</b>. Sin ellos no podemos mostrarte personas con quienes practicar.",
    btn: "Añadir mis idiomas",
    time: "Tardas unos 30 segundos",
    after: "Cuando lo hagas, tendrás:",
    b: [["🤝", "Compañeros", "personas que hablan lo que aprendes y quieren aprender lo que tú hablas"],
        ["☕", "Sesiones y salas", "espacios tranquilos para practicar tu par de idiomas"],
        ["🎮", "Juegos", "tarjetas, Split or Stick, Ahorcado y más, a tu nivel"]],
    sign: "¡Nos vemos en el puente!",
    team: "Yvette y el equipo de PonteTalk",
    beta: "PonteTalk es una beta gratuita. ¿Ideas o problemas? Responde a este email, leo todos.",
    why: "Recibes este email porque creaste una cuenta en PonteTalk.",
    stop: "¿No quieres más emails así? Responde \"stop\" y no te los volveremos a enviar.",
    link: "¿El botón no funciona? Copia este enlace:",
  },
  de: {
    subject: "Nur noch ein Schritt: Welche Sprachen sprichst du? 🌉",
    pre: "Trag deine Sprachen in 30 Sekunden ein und wir zeigen dir Leute zum Üben.",
    hi: (n: string) => n ? `Hallo ${n},` : "Hallo,",
    p1: "Willkommen bei PonteTalk, schön, dass du da bist! 🎉",
    p2: "Eine Sache fehlt noch: <b>deine Sprachen</b>. Ohne sie können wir dir niemanden zum Üben zeigen.",
    btn: "Meine Sprachen eintragen",
    time: "Dauert etwa 30 Sekunden",
    after: "Danach bekommst du:",
    b: [["🤝", "Partner", "Leute, die sprechen, was du lernst, und lernen wollen, was du sprichst"],
        ["☕", "Sessions & Lounges", "entspannte Übungsräume für dein Sprachpaar"],
        ["🎮", "Spiele", "Karteikarten, Split or Stick, Galgenmännchen und mehr, auf deinem Niveau"]],
    sign: "Bis bald auf der Brücke,",
    team: "Yvette & das PonteTalk-Team",
    beta: "PonteTalk ist eine kostenlose Beta. Ideen oder Probleme? Antworte einfach auf diese E-Mail, ich lese alles.",
    why: "Du bekommst diese E-Mail, weil du ein PonteTalk-Konto erstellt hast.",
    stop: "Keine solchen E-Mails mehr? Antworte mit \"stop\", dann schicken wir keine mehr.",
    link: "Der Button geht nicht? Kopiere diesen Link:",
  },
};

// 🕒 second email: has languages, but no free times yet
const TIMES: Record<string, any> = {
  en: { subject: "When are you free to practise? 🕒", pre: "Tap the times that suit you, and partners can find a time that works for both of you.",
        p1: "Thanks for adding your languages! 🙌",
        p2: "One more tiny step: <b>when are you usually free?</b> Partners only see people whose times match theirs, so right now nobody can find a time with you.",
        btn: "Add my free times", time: "Just tap a few times, about 20 seconds", emoji: "🕒" },
  es: { subject: "¿Cuándo puedes practicar? 🕒", pre: "Marca las horas que te van bien y tus compañeros encontrarán un momento para los dos.",
        p1: "¡Gracias por añadir tus idiomas! 🙌",
        p2: "Un pasito más: <b>¿cuándo sueles tener tiempo?</b> Los compañeros solo ven a personas con horarios que coinciden, así que ahora nadie puede encontrar un momento contigo.",
        btn: "Añadir mis horas libres", time: "Solo marca algunas horas, unos 20 segundos", emoji: "🕒" },
  de: { subject: "Wann hast du Zeit zum Üben? 🕒", pre: "Tipp die Zeiten an, die dir passen, und Partner finden einen Termin, der für euch beide klappt.",
        p1: "Danke, dass du deine Sprachen eingetragen hast! 🙌",
        p2: "Noch ein kleiner Schritt: <b>Wann hast du meistens Zeit?</b> Partner sehen nur Leute, deren Zeiten passen, also kann gerade niemand einen Termin mit dir finden.",
        btn: "Meine freien Zeiten eintragen", time: "Einfach ein paar Zeiten antippen, etwa 20 Sekunden", emoji: "🕒" },
};
const tpl = (kind: string, lang: string) => ({ ...(T[lang] || T.en), emoji: "🗣️", ...(kind === "times" ? TIMES[lang] || TIMES.en : {}) });

export function emailHtml(lang: string, name: string, kind = "langs"): string {
  const t = tpl(kind, lang), LINK = LINKS[kind] || LINKS.langs;
  const F = "'Plus Jakarta Sans',Helvetica,Arial,sans-serif";
  const ben = t.b.map(([e, h, d]: string[]) => `
      <tr><td style="padding:0 0 12px" valign="top">
        <table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>
          <td width="44" valign="top" style="font-size:22px;line-height:40px;width:44px"><div style="width:40px;height:40px;border-radius:12px;background:#FCE6DF;text-align:center;line-height:40px">${e}</div></td>
          <td style="padding-left:12px;font-family:${F};font-size:15px;line-height:22px;color:#5B6474"><b style="color:#1B2A41">${h}</b><br>${d}</td>
        </tr></table></td></tr>`).join("");
  return `<!DOCTYPE html><html lang="${lang}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light only"><title>${esc(t.subject)}</title></head>
<body style="margin:0;padding:0;background:#FAF7F2">
<div style="display:none;max-height:0;overflow:hidden;opacity:0">${esc(t.pre)}</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#FAF7F2"><tr><td align="center" style="padding:28px 14px">
 <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:560px">
  <tr><td align="center" style="padding:0 0 18px">
    <a href="${APP}" style="text-decoration:none"><img src="${APP}/icon-192.png" width="52" height="52" alt="" style="display:inline-block;border-radius:14px;vertical-align:middle;border:0">
    <span style="font-family:${F};font-size:26px;font-weight:800;color:#1B2A41;vertical-align:middle;padding-left:10px">Ponte<span style="color:#F25C3B">Talk</span></span></a>
  </td></tr>
  <tr><td style="background:#FFFFFF;border-radius:24px;border:1px solid #E6E0D7;overflow:hidden">
    <div style="height:6px;background:#F25C3B;background:linear-gradient(90deg,#F25C3B,#F2B544,#2A8C82);border-radius:24px 24px 0 0"></div>
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr><td style="padding:30px 30px 8px;font-family:${F};color:#1B2A41">
      <p style="margin:0 0 14px;font-size:17px;font-weight:700">${esc(t.hi(name))}</p>
      <p style="margin:0 0 12px;font-size:16px;line-height:25px">${t.p1}</p>
      <p style="margin:0 0 24px;font-size:16px;line-height:25px">${t.p2}</p>
      <table role="presentation" cellpadding="0" cellspacing="0" border="0" align="center"><tr><td align="center" bgcolor="#F25C3B" style="border-radius:999px">
        <a href="${LINK}" style="display:inline-block;padding:15px 34px;font-family:${F};font-size:17px;font-weight:800;color:#FFFFFF;text-decoration:none;border-radius:999px">${t.emoji} ${t.btn} →</a>
      </td></tr></table>
      <p style="margin:10px 0 26px;text-align:center;font-size:13px;color:#5B6474">⏱️ ${t.time}</p>
      <div style="border-top:1px solid #E6E0D7;margin:0 0 20px"></div>
      <p style="margin:0 0 14px;font-size:15px;font-weight:700">${t.after}</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">${ben}</table>
      <p style="margin:12px 0 4px;font-size:16px;line-height:24px">${t.sign}</p>
      <p style="margin:0 0 26px;font-size:16px;font-weight:700">${t.team} 🌉</p>
    </td></tr>
    <tr><td style="background:#FDF2D8;padding:14px 30px;font-family:${F};font-size:14px;line-height:21px;color:#1B2A41;border-radius:0 0 24px 24px">🧪 ${t.beta}</td></tr></table>
  </td></tr>
  <tr><td style="padding:18px 12px 0;font-family:${F};font-size:12px;line-height:18px;color:#8A919E;text-align:center">
    ${t.link}<br><a href="${LINK}" style="color:#2F4B7C">${LINK}</a><br><br>
    ${t.why}<br>${t.stop}<br><br>
    PonteTalk · <a href="${APP}/?impressum" style="color:#8A919E">Impressum</a> · <a href="${APP}/?datenschutz" style="color:#8A919E">Datenschutz</a>
  </td></tr>
 </table>
</td></tr></table></body></html>`;
}

function emailText(lang: string, name: string, kind = "langs"): string {
  const t = tpl(kind, lang), LINK = LINKS[kind] || LINKS.langs;
  const strip = (s: string) => s.replace(/<[^>]+>/g, "");
  return [t.hi(name), "", strip(t.p1), strip(t.p2), "", `${t.btn}: ${LINK}`, `(${t.time})`, "", t.after,
    ...t.b.map((x: string[]) => `• ${x[1]}: ${x[2]}`), "", t.sign, t.team, "", t.beta, "", t.why, t.stop].join("\n");
}

const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const body = await req.json().catch(() => ({}));
    const lang = ["en", "es", "de"].includes(body.lang) ? body.lang : "en";
    const kind = body.kind === "times" ? "times" : "langs";
    const auth = req.headers.get("Authorization") || "";
    const apikey = req.headers.get("apikey") || Deno.env.get("SUPABASE_ANON_KEY") || "";
    const base = Deno.env.get("SUPABASE_URL")!;
    // Call the database as the signed-in person, so the admin check applies.
    const rpc = async (fn: string, args: unknown = {}) => {
      const r = await fetch(`${base}/rest/v1/rpc/${fn}`, { method: "POST", headers: { apikey, Authorization: auth, "Content-Type": "application/json" }, body: JSON.stringify(args) });
      const d = await r.json().catch(() => null);
      if (!r.ok) throw new Error((d && (d.message || d.hint)) || `${fn} failed`);
      return d;
    };
    const list: any[] = await rpc("pt_admin_incomplete", { p_kind: kind }); // throws admins_only for everyone else
    if (body.preview) return json({ subject: tpl(kind, lang).subject, html: emailHtml(lang, "Lena", kind) });

    const key = Deno.env.get("RESEND_API_KEY");
    if (!key) return json({ error: "RESEND_API_KEY is missing in Supabase → Edge Functions → Secrets" }, 500);
    const send = async (emails: any[]) => {
      const r = await fetch("https://api.resend.com/emails/batch", { method: "POST", headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" }, body: JSON.stringify(emails) });
      const d = await r.json().catch(() => null);
      if (!r.ok) throw new Error((d && (d.message || d.name)) || "Resend failed");
      return d;
    };
    const mail = (to: string, name: string) => ({
      from: FROM, to: [to], reply_to: REPLY, subject: tpl(kind, lang).subject,
      html: emailHtml(lang, name, kind), text: emailText(lang, name, kind),
      headers: { "List-Unsubscribe": `<mailto:${REPLY}?subject=stop>` },
    });

    if (body.test) {
      const me = await fetch(`${base}/auth/v1/user`, { headers: { apikey, Authorization: auth } }).then((r) => r.json());
      if (!me?.email) return json({ error: "no email" }, 400);
      await send([mail(me.email, "Yvette")]);
      return json({ sent: 1, to: me.email });
    }

    const want = new Set<string>(Array.isArray(body.ids) ? body.ids : []);
    const people = list.filter((p) => p.email && want.has(p.user_id));
    if (!people.length) return json({ sent: 0 });
    let sent = 0; const done: string[] = [];
    for (let i = 0; i < people.length; i += 100) {
      const chunk = people.slice(i, i + 100);
      await send(chunk.map((p) => mail(p.email, (p.name || "").split(" ")[0])));
      sent += chunk.length; done.push(...chunk.map((p) => p.user_id));
    }
    await rpc("pt_admin_nudge", { p_ids: done, p_kind: kind }); // remembers the date + sends the 🔔
    return json({ sent });
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 400);
  }
});
