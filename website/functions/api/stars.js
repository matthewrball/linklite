const REPO_API = "https://api.github.com/repos/matthewrball/linklite";

function json(body, status, cacheControl) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "cache-control": cacheControl,
      "content-type": "application/json; charset=utf-8",
    },
  });
}

// Visitors read the count from this origin, so their browsers never contact GitHub.
export async function onRequestGet() {
  try {
    const response = await fetch(REPO_API, {
      headers: {
        accept: "application/vnd.github+json",
        "user-agent": "linklite-site-stars",
      },
      cf: { cacheEverything: true, cacheTtlByStatus: { "200-299": 900, "400-599": 0 } },
    });
    if (!response.ok) throw new Error(`GitHub returned ${response.status}`);
    const stars = (await response.json())?.stargazers_count;
    if (!Number.isSafeInteger(stars) || stars < 0) throw new Error("Unexpected star count");
    return json({ stars }, 200, "public, max-age=900");
  } catch {
    return json({ error: "Star count unavailable." }, 503, "no-store");
  }
}
