const EMAIL_ENDPOINT = "https://api.resend.com/emails";
const FROM = "LinkLite <updates@send.matthewball.me>";
const SOURCES = new Set(["download", "homepage", "github", "hn", "product-hunt", "reddit", "x", "direct", "other"]);

function signupSource(value) {
  const source = String(value || "").trim().toLowerCase();
  if (!source) return "download";
  return SOURCES.has(source) ? source : "other";
}

function emailHtml({ eyebrow, title, body, detail = "" }) {
  return `<!doctype html>
<html lang="en">
<head>
  <meta name="color-scheme" content="dark">
  <meta name="supported-color-schemes" content="dark">
  <style>
    :root { color-scheme: dark; supported-color-schemes: dark; }
    a { color: inherit !important; text-decoration: none !important; }
  </style>
</head>
<body style="margin:0;background:#050815;color:#F4F7FF;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif">
  <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background:#050815">
    <tr>
      <td align="center" style="padding:40px 16px">
        <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width:600px;border:1px solid rgba(190,215,255,.16);border-radius:24px;background:#111831">
          <tr>
            <td style="padding:36px">
              <p style="margin:0 0 10px;color:#8EC5FF;font-size:12px;font-weight:700;letter-spacing:.2em;text-transform:uppercase">${eyebrow}</p>
              <h1 style="margin:0;color:#F4F7FF;font-family:Georgia,'Times New Roman',serif;font-size:36px;line-height:1.08;letter-spacing:-.03em">${title}</h1>
              <p style="margin:18px 0 0;color:rgba(244,247,255,.72);font-size:17px;line-height:1.65">${body}</p>
              ${detail}
              <p style="margin:32px 0 0;padding-top:20px;border-top:1px solid rgba(190,215,255,.12);color:rgba(244,247,255,.48);font-size:12px;line-height:1.6">LinkLite · The lightweight driver for DisplayLink docks on macOS.<br>Questions? Reply to this email.</p>
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>`;
}

function confirmationEmail(email, replyTo) {
  return {
    to: email,
    from: FROM,
    reply_to: replyTo,
    subject: "Thanks for joining LinkLite",
    html: emailHtml({
      eyebrow: "You’re subscribed",
      title: "Thanks for joining LinkLite.",
      body: "You’ll get occasional product notes. Reply anytime with a question.",
    }),
    text: "Thanks for joining LinkLite.\n\nYou’ll get occasional product notes. Reply anytime with a question.",
  };
}

function signupAlert(email, notificationEmail) {
  const safeEmail = email
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");

  return {
    to: notificationEmail,
    from: FROM,
    subject: "New LinkLite signup",
    html: emailHtml({
      eyebrow: "New subscriber",
      title: "Someone joined the list.",
      body: "A new person signed up for LinkLite updates.",
      detail: `<p style="margin:24px 0 0;padding:16px;border:1px solid rgba(190,215,255,.12);border-radius:14px;background:#0B1024;color:#8EC5FF;font-size:16px"><strong>${safeEmail}</strong></p>`,
    }),
    text: `New LinkLite signup\n\n${email}`,
  };
}

async function sendEmail(token, message) {
  const response = await fetch(EMAIL_ENDPOINT, {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(message),
  });

  if (!response.ok) throw new Error(`Resend returned ${response.status}`);
}

const ALLOWED_ORIGINS = new Set([
  "https://linklite.app",
  "https://www.linklite.app",
  "https://linklite-website-2pz.pages.dev",
  "https://main.linklite-website-2pz.pages.dev",
]);
const TURNSTILE_VERIFY = "https://challenges.cloudflare.com/turnstile/v0/siteverify";
const IP_HOURLY_LIMIT = 5;
const GLOBAL_HOURLY_LIMIT = 30;
const GLOBAL_DAILY_LIMIT = 100;

function limit(env, name, fallback) {
  const value = Number(env?.[name]);
  return Number.isInteger(value) && value > 0 && value <= 1000 ? value : fallback;
}

function json(body, status = 200) {
  return Response.json(body, { status, headers: { "cache-control": "no-store" } });
}

function allowedOrigin(origin) {
  if (!origin) return true;
  if (ALLOWED_ORIGINS.has(origin)) return true;
  try {
    const url = new URL(origin);
    return (url.hostname === "localhost" || url.hostname === "127.0.0.1") && url.protocol === "http:";
  } catch {
    return false;
  }
}

async function addressHash(env, ip) {
  const pepper = String(env?.SIGNUP_IP_PEPPER || "");
  if (pepper.length < 16) return "";
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(pepper),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(ip));
  return [...new Uint8Array(mac)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function claimSignupAttempt(env, request) {
  const ipHash = await addressHash(env, request.headers.get("cf-connecting-ip") || "unknown");
  if (!ipHash) return false;
  await env.SIGNUPS.prepare(
    "DELETE FROM signup_attempts WHERE created_at < datetime('now', '-2 days')"
  ).run();
  // One statement, so overlapping verified signups cannot all pass a prior count check.
  const result = await env.SIGNUPS.prepare(
    `INSERT INTO signup_attempts (ip_hash)
     SELECT ?
     WHERE (SELECT COUNT(*) FROM signup_attempts WHERE ip_hash = ? AND created_at >= datetime('now', '-1 hour')) < ?
       AND (SELECT COUNT(*) FROM signup_attempts WHERE created_at >= datetime('now', '-1 hour')) < ?
       AND (SELECT COUNT(*) FROM signup_attempts WHERE created_at >= datetime('now', '-1 day')) < ?`
  ).bind(
    ipHash,
    ipHash,
    limit(env, "SIGNUP_IP_HOURLY_LIMIT", IP_HOURLY_LIMIT),
    limit(env, "SIGNUP_GLOBAL_HOURLY_LIMIT", GLOBAL_HOURLY_LIMIT),
    limit(env, "SIGNUP_GLOBAL_DAILY_LIMIT", GLOBAL_DAILY_LIMIT),
  ).run();
  return result.meta?.changes === 1;
}

function expectedChallengeHost(request) {
  const origin = request.headers.get("origin");
  if (!origin) return "linklite.app";
  try {
    return allowedOrigin(origin) ? new URL(origin).hostname : "linklite.app";
  } catch { /* Fall through to the production host. */ }
  return "linklite.app";
}

async function challengeAccepted(request, env, token) {
  if (typeof token !== "string" || token.length < 1 || token.length > 2048) return false;
  try {
    const body = new URLSearchParams({ secret: String(env.TURNSTILE_SECRET_KEY), response: token });
    const ip = request.headers.get("cf-connecting-ip");
    if (ip) body.set("remoteip", ip);
    const response = await fetch(TURNSTILE_VERIFY, {
      method: "POST",
      redirect: "manual",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body,
      signal: AbortSignal.timeout(5000),
    });
    if (!response.ok) return false;
    const result = await response.json().catch(() => null);
    return result?.success === true && result.action === "signup" && result.hostname === expectedChallengeHost(request);
  } catch {
    return false;
  }
}

export async function onRequestGet({ env }) {
  const siteKey = String(env?.TURNSTILE_SITE_KEY || "");
  if (!siteKey) return json({ error: "Signup is unavailable." }, 503);
  return json({ siteKey });
}

export async function onRequestPost({ request, env }) {
  if (!request.headers.get("content-type")?.includes("application/json")) {
    return json({ error: "Invalid request." }, 415);
  }
  if (!env?.TURNSTILE_SECRET_KEY || String(env?.SIGNUP_IP_PEPPER || "").length < 16) {
    return json({ error: "Signup is unavailable." }, 503);
  }

  const { email, website, source, turnstileToken } = await request.json().catch(() => ({}));
  if (!allowedOrigin(request.headers.get("origin"))) return json({ error: "Invalid request." }, 403);
  if (website) return json({ ok: true });

  const normalized = String(email || "").trim().toLowerCase();
  if (normalized.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(normalized)) {
    return json({ error: "Enter a valid email address." }, 400);
  }
  if (!(await challengeAccepted(request, env, turnstileToken))) {
    return json({ error: "Could not verify that request." }, 400);
  }
  if (!(await claimSignupAttempt(env, request))) return json({ error: "Try again later." }, 429);

  const result = await env.SIGNUPS.prepare(
    "INSERT OR IGNORE INTO signups (email, source) VALUES (?, ?)"
  ).bind(normalized, signupSource(source)).run();

  const notificationEmail = String(env.SIGNUP_NOTIFICATION_EMAIL || "").trim();
  if (result.meta?.changes && env.RESEND_API_KEY && notificationEmail) {
    const deliveries = await Promise.allSettled([
      sendEmail(env.RESEND_API_KEY, signupAlert(normalized, notificationEmail)),
      sendEmail(env.RESEND_API_KEY, confirmationEmail(normalized, notificationEmail)),
    ]);

    for (const delivery of deliveries) {
      if (delivery.status === "rejected") console.error("Signup email failed:", delivery.reason);
    }
  }

  return json({ ok: true });
}
