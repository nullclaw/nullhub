<script lang="ts">
  import {
    getComponentConfigSchema,
    type GenericFieldDef,
  } from "./componentConfigSchemas";

  let {
    component = "",
    config = $bindable({}),
    onchange = () => {},
  }: {
    component: string;
    config: any;
    onchange: () => void;
  } = $props();

  let openSections = $state<Record<string, boolean>>({});
  let drafts = $state<Record<string, string>>({});
  let errors = $state<Record<string, string>>({});

  let sections = $derived(getComponentConfigSchema(component));

  function getPath(obj: any, path: string): any {
    return path.split(".").reduce((o, k) => o?.[k], obj);
  }

  function setPath(obj: any, path: string, value: any): any {
    const clone = JSON.parse(JSON.stringify(obj ?? {}));
    const keys = path.split(".");
    let cur = clone;
    for (let i = 0; i < keys.length - 1; i++) {
      if (cur[keys[i]] === undefined || cur[keys[i]] === null) cur[keys[i]] = {};
      cur = cur[keys[i]];
    }
    cur[keys[keys.length - 1]] = value;
    return clone;
  }

  function removePath(obj: any, path: string): any {
    const clone = JSON.parse(JSON.stringify(obj ?? {}));
    const keys = path.split(".");
    let cur = clone;
    for (let i = 0; i < keys.length - 1; i++) {
      if (cur[keys[i]] === undefined || cur[keys[i]] === null) return clone;
      cur = cur[keys[i]];
    }
    delete cur[keys[keys.length - 1]];
    return clone;
  }

  function updateField(path: string, value: any) {
    config = setPath(config, path, value);
    onchange();
  }

  function clearField(path: string) {
    config = removePath(config, path);
    onchange();
  }

  function toggleSection(key: string) {
    openSections[key] = !openSections[key];
  }

  function fieldId(sectionKey: string, fieldKey: string): string {
    return `${component}-${sectionKey}-${fieldKey.replaceAll(".", "-")}`;
  }

  function displayJson(field: GenericFieldDef): string {
    if (drafts[field.key] !== undefined) return drafts[field.key];
    const value = getPath(config, field.key);
    if (value === undefined) {
      return JSON.stringify(field.default ?? {}, null, 2);
    }
    return JSON.stringify(value, null, 2);
  }

  function displayList(field: GenericFieldDef): string {
    const value = getPath(config, field.key);
    if (Array.isArray(value)) return value.join("\n");
    if (value === undefined && Array.isArray(field.default)) return field.default.join("\n");
    return "";
  }

  function updateJson(field: GenericFieldDef, raw: string) {
    drafts[field.key] = raw;
    if (!raw.trim()) {
      delete errors[field.key];
      clearField(field.key);
      return;
    }
    try {
      const parsed = JSON.parse(raw);
      delete errors[field.key];
      updateField(field.key, parsed);
    } catch {
      errors[field.key] = "Invalid JSON";
    }
  }

  function updateList(field: GenericFieldDef, raw: string) {
    const items = raw
      .split("\n")
      .map((item) => item.trim())
      .filter(Boolean);
    updateField(field.key, items);
  }

  function updateNumber(field: GenericFieldDef, raw: string) {
    if (!raw.trim()) {
      clearField(field.key);
      return;
    }
    const value = Number(raw);
    if (!Number.isNaN(value)) updateField(field.key, value);
  }
</script>

<div class="structured-editor">
  {#each sections as section}
    <div class="section">
      <button class="section-header" onclick={() => toggleSection(section.key)}>
        <span class="section-arrow" class:open={openSections[section.key]}>▶</span>
        <span>{section.label}</span>
      </button>

      {#if openSections[section.key] !== false}
        <div class="section-body">
          {#if section.description}
            <p class="section-description">{section.description}</p>
          {/if}

          {#each section.fields as field}
            {@const id = fieldId(section.key, field.key)}
            <div class="field">
              <label for={id}>{field.label}</label>

              {#if field.type === "toggle"}
                <label class="toggle-field" for={id}>
                  <input
                    id={id}
                    type="checkbox"
                    checked={!!getPath(config, field.key)}
                    onchange={(e) => updateField(field.key, e.currentTarget.checked)}
                  />
                  <span>{getPath(config, field.key) ? "Enabled" : "Disabled"}</span>
                </label>
              {:else if field.type === "select"}
                <select
                  id={id}
                  value={getPath(config, field.key) ?? field.default ?? ""}
                  onchange={(e) => updateField(field.key, e.currentTarget.value)}
                >
                  {#each field.options ?? [] as option}
                    <option value={option}>{option}</option>
                  {/each}
                </select>
              {:else if field.type === "number"}
                <input
                  id={id}
                  type="number"
                  value={getPath(config, field.key) ?? field.default ?? ""}
                  min={field.min}
                  max={field.max}
                  step={field.step}
                  oninput={(e) => updateNumber(field, e.currentTarget.value)}
                />
              {:else if field.type === "password"}
                <input
                  id={id}
                  type="password"
                  value={getPath(config, field.key) ?? ""}
                  oninput={(e) => updateField(field.key, e.currentTarget.value)}
                />
              {:else if field.type === "textarea"}
                <textarea
                  id={id}
                  rows={field.rows ?? 4}
                  oninput={(e) => updateField(field.key, e.currentTarget.value)}
                >{getPath(config, field.key) ?? field.default ?? ""}</textarea>
              {:else if field.type === "list"}
                <textarea
                  id={id}
                  rows={field.rows ?? 4}
                  value={displayList(field)}
                  oninput={(e) => updateList(field, e.currentTarget.value)}
                ></textarea>
              {:else if field.type === "json"}
                <textarea
                  id={id}
                  rows={field.rows ?? 6}
                  value={displayJson(field)}
                  oninput={(e) => updateJson(field, e.currentTarget.value)}
                ></textarea>
              {:else}
                <input
                  id={id}
                  type="text"
                  value={getPath(config, field.key) ?? field.default ?? ""}
                  oninput={(e) => updateField(field.key, e.currentTarget.value)}
                />
              {/if}

              {#if field.hint}
                <p class="hint">{field.hint}</p>
              {/if}
              {#if errors[field.key]}
                <p class="error">{errors[field.key]}</p>
              {/if}
            </div>
          {/each}
        </div>
      {/if}
    </div>
  {/each}
</div>

<style>
  .structured-editor {
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
  }

  .section {
    border: 1px solid var(--border);
    border-radius: 2px;
    background: color-mix(in srgb, var(--bg-surface) 75%, transparent);
  }

  .section-header {
    width: 100%;
    background: none;
    border: none;
    color: var(--fg);
    display: flex;
    align-items: center;
    gap: 0.5rem;
    padding: 0.9rem 1rem;
    cursor: pointer;
    font-size: 0.85rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1px;
  }

  .section-arrow {
    font-size: 0.7rem;
    transition: transform 0.2s ease;
    color: var(--accent);
  }

  .section-arrow.open {
    transform: rotate(90deg);
  }

  .section-body {
    padding: 0 1rem 1rem;
  }

  .section-description {
    margin: 0 0 1rem;
    color: var(--fg-dim);
    font-size: 0.8rem;
    line-height: 1.5;
  }

  .field {
    display: flex;
    flex-direction: column;
    gap: 0.35rem;
    margin-bottom: 1rem;
  }

  .field label {
    font-size: 0.75rem;
    font-weight: 700;
    color: var(--fg-dim);
    text-transform: uppercase;
    letter-spacing: 1px;
  }

  .field input,
  .field select,
  .field textarea {
    width: 100%;
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 2px;
    padding: 0.625rem 0.75rem;
    color: var(--fg);
    font-size: 0.875rem;
    font-family: var(--font-mono);
    outline: none;
    transition: all 0.2s ease;
  }

  .field input:focus,
  .field select:focus,
  .field textarea:focus {
    border-color: var(--accent);
    box-shadow: 0 0 8px var(--border-glow);
  }

  .field textarea {
    resize: vertical;
    line-height: 1.5;
  }

  .toggle-field {
    display: flex;
    align-items: center;
    gap: 0.6rem;
    text-transform: none;
    letter-spacing: 0;
    color: var(--fg);
    font-size: 0.875rem;
  }

  .toggle-field input {
    width: auto;
    margin: 0;
  }

  .hint {
    margin: 0;
    color: var(--fg-dim);
    font-size: 0.75rem;
    line-height: 1.4;
  }

  .error {
    margin: 0;
    color: var(--error);
    font-size: 0.75rem;
    font-weight: 700;
  }
</style>
