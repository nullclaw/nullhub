export type ProviderOption = {
  value: string;
  label: string;
  recommended?: boolean;
};

/**
 * Canonical list of providers known to NullHub.
 * Both the Providers management page and the wizard's ProviderList component
 * must derive their dropdowns from this single source of truth.
 */
export const PROVIDER_OPTIONS: ProviderOption[] = [
  { value: "openrouter", label: "OpenRouter (multi-provider, recommended)", recommended: true },
  { value: "minimax", label: "MiniMax" },
  { value: "anthropic", label: "Anthropic" },
  { value: "openai", label: "OpenAI" },
  { value: "google", label: "Google AI" },
  { value: "mistral", label: "Mistral" },
  { value: "groq", label: "Groq" },
  { value: "deepseek", label: "DeepSeek" },
  { value: "cohere", label: "Cohere" },
  { value: "together", label: "Together AI" },
  { value: "fireworks", label: "Fireworks AI" },
  { value: "perplexity", label: "Perplexity" },
  { value: "xai", label: "xAI" },
  { value: "ollama", label: "Ollama (local)" },
  { value: "lm-studio", label: "LM Studio (local)" },
  { value: "claude-cli", label: "Claude CLI (local)" },
  { value: "codex-cli", label: "Codex CLI (local CLI)" },
  { value: "openai-codex", label: "OpenAI Codex (ChatGPT login)" },
  { value: "openai-compatible", label: "OpenAI Compatible (custom endpoint)" },
];

export const OPENAI_COMPATIBLE_VALUE = "openai-compatible";

export const LOCAL_PROVIDERS = ["ollama", "lm-studio", "claude-cli", "codex-cli", "openai-codex"];

export type ProviderBaseUrlOption = {
  value: string;
  label: string;
};

export const PROVIDER_BASE_URL_OPTIONS: Record<string, ProviderBaseUrlOption[]> = {
  minimax: [
    { value: "https://api.minimax.io/v1", label: "Global" },
    { value: "https://api.minimaxi.com/v1", label: "China" },
  ],
};

export const PROVIDER_MODEL_OPTIONS: Record<string, string[]> = {
  minimax: ["MiniMax-M3", "MiniMax-M2.7"],
};

export const PROVIDER_DEFAULT_BASE_URLS: Record<string, string> = {
  minimax: PROVIDER_BASE_URL_OPTIONS.minimax[0].value,
};

export const PROVIDER_DEFAULT_MODELS: Record<string, string> = {
  minimax: PROVIDER_MODEL_OPTIONS.minimax[0],
};

export function providerUsesOpenAiCompatibleEndpoint(provider: string) {
  return provider === OPENAI_COMPATIBLE_VALUE || provider in PROVIDER_DEFAULT_BASE_URLS;
}

export function mergeProviderModelOptions(provider: string, models: unknown[] = []): string[] {
  const candidates = [...(PROVIDER_MODEL_OPTIONS[provider] || []), ...models];
  return [...new Set(candidates.filter((model): model is string => typeof model === "string" && model.length > 0))];
}

/**
 * Set of all provider values that are NOT the openai-compatible catch-all.
 * Used to determine whether a saved provider entry is a named standard provider
 * or a custom/self-hosted endpoint.
 */
export const KNOWN_PROVIDER_VALUES = new Set(
  PROVIDER_OPTIONS.filter((o) => o.value !== OPENAI_COMPATIBLE_VALUE).map((o) => o.value),
);

/**
 * Merge the canonical provider list with manifest-provided options.
 * The manifest may mark a specific provider as `recommended`; that flag wins
 * over the default. All canonical options (including openai-compatible) are
 * always present regardless of what the manifest returns.
 */
export function mergeWithManifestOptions(manifestOptions: ProviderOption[]): ProviderOption[] {
  return PROVIDER_OPTIONS.map((opt) => {
    const fromManifest = manifestOptions.find((m) => m.value === opt.value);
    return fromManifest ? { ...opt, recommended: fromManifest.recommended ?? opt.recommended } : opt;
  });
}
