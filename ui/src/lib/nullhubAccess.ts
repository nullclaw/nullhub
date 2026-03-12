const PUBLIC_ALIAS_HOST = "nullhub.local";
const CANONICAL_LOCAL_HOST = "nullhub.localhost";
const FALLBACK_LOCAL_HOST = "127.0.0.1";
const LOOPBACK_HOSTS = new Set([
  PUBLIC_ALIAS_HOST,
  CANONICAL_LOCAL_HOST,
  FALLBACK_LOCAL_HOST,
  "localhost",
]);

export function buildNullHubAccessUrls(port: string | number, protocol = "http:") {
  const portValue = `${port || 19800}`;
  const prefix = `${protocol}//`;
  return {
    localAliasChain: true,
    publicAliasUrl: `${prefix}${PUBLIC_ALIAS_HOST}:${portValue}`,
    canonicalUrl: `${prefix}${CANONICAL_LOCAL_HOST}:${portValue}`,
    fallbackUrl: `${prefix}${FALLBACK_LOCAL_HOST}:${portValue}`,
    browserOpenUrl: `${prefix}${CANONICAL_LOCAL_HOST}:${portValue}`,
    directUrl: `${prefix}${FALLBACK_LOCAL_HOST}:${portValue}`,
  };
}

export async function redirectToPreferredOrigin(location: Location): Promise<void> {
  if (!LOOPBACK_HOSTS.has(location.hostname)) return;

  const urls = buildNullHubAccessUrls(resolvePort(location), location.protocol);
  const currentOrigin = location.origin;
  const candidates = [urls.browserOpenUrl, urls.fallbackUrl];

  for (const candidate of candidates) {
    if (candidate === currentOrigin) return;
    if (await probeOrigin(candidate)) {
      location.replace(`${candidate}${location.pathname}${location.search}${location.hash}`);
      return;
    }
  }
}

async function probeOrigin(origin: string): Promise<boolean> {
  const controller = new AbortController();
  const timeout = window.setTimeout(() => controller.abort(), 350);
  try {
    const response = await fetch(`${origin}/health`, {
      method: "GET",
      mode: "cors",
      cache: "no-store",
      signal: controller.signal,
    });
    return response.ok;
  } catch {
    return false;
  } finally {
    window.clearTimeout(timeout);
  }
}

function resolvePort(location: Location): string {
  if (location.port) return location.port;
  return location.protocol === "https:" ? "443" : "80";
}
