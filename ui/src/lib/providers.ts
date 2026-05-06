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
