// PlayerData relay: Roblox -> this Worker -> Discord.
// Secrets to add in the dashboard: ACCESS_TOKEN, WEBHOOK_INCIDENTS, WEBHOOK_BANS

const MAX_BODY_CHARS = 20000;

// Compares in constant time so the token can't be guessed by timing.
function sameText(a, b) {
  const encoder = new TextEncoder();
  const left = encoder.encode(a);
  const right = encoder.encode(b);
  if (left.byteLength !== right.byteLength) {
    return false;
  }
  return crypto.subtle.timingSafeEqual(left, right);
}

export default {
  async fetch(request, env) {
    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    // The path is /<ACCESS_TOKEN>/<channel>. 
    const [token, channel] = new URL(request.url).pathname.split("/").filter(Boolean);
    if (!token || !env.ACCESS_TOKEN || !sameText(token, env.ACCESS_TOKEN)) {
      return new Response("Not found", { status: 404 });
    }

    const targets = { incidents: env.WEBHOOK_INCIDENTS, bans: env.WEBHOOK_BANS };
    const target = targets[channel];
    if (!target) {
      return new Response("Not found", { status: 404 });
    }

    const body = await request.text();
    if (body.length === 0 || body.length > MAX_BODY_CHARS) {
      return new Response("Bad body", { status: 400 });
    }

    let discord;
    try {
      discord = await fetch(target, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: body,
      });
    } catch (error) {
      return new Response("Relay could not reach Discord: check the webhook secret", { status: 502 });
    }

    const headers = new Headers();
    const retryAfter = discord.headers.get("retry-after");
    if (retryAfter) {
      headers.set("Retry-After", retryAfter);
    }
    return new Response(discord.body, { status: discord.status, headers: headers });
  },
};