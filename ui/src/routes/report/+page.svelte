<script lang="ts">
  import { api, type ReportOption } from "$lib/api/client";
  import { onMount } from "svelte";

  type Step = "form" | "preview" | "result";

  let step = $state<Step>("form");
  let repoOptions = $state<ReportOption[]>([]);
  let typeOptions = $state<ReportOption[]>([]);
  let repo = $state("");
  let type = $state("");
  let message = $state("");
  let loading = $state(false);
  let metaLoading = $state(true);
  let error = $state("");

  // Preview state
  let previewTitle = $state("");
  let previewMarkdown = $state("");
  let previewLabels = $state<string[]>([]);
  let previewRepo = $state("");

  // Result state
  let resultUrl = $state("");
  let resultTitle = $state("");
  let resultLabels = $state<string[]>([]);
  let resultRepo = $state("");
  let resultManualUrl = $state("");
  let resultError = $state("");
  let resultHint = $state("");
  let resultMarkdown = $state("");
  let copied = $state(false);

  onMount(() => {
    void loadMeta();
  });

  async function loadMeta() {
    metaLoading = true;
    error = "";
    try {
      const meta = await api.getReportMeta();
      repoOptions = meta.repos.map(({ value, label }) => ({ value, label }));
      typeOptions = meta.types.map(({ value, label }) => ({ value, label }));

      if (!repoOptions.some((option) => option.value === repo)) {
        repo = repoOptions[0]?.value || "";
      }
      if (!typeOptions.some((option) => option.value === type)) {
        type = typeOptions[0]?.value || "";
      }
    } catch (e) {
      error = (e as Error).message;
    } finally {
      metaLoading = false;
    }
  }

  async function goToPreview() {
    if (!repo || !type) {
      error = metaLoading ? "Loading report metadata..." : "Report metadata is unavailable";
      return;
    }
    if (!message.trim()) {
      error = "Summary is required";
      return;
    }
    loading = true;
    error = "";
    try {
      const res = await api.reportPreview({ repo, type, message: message.trim() });
      previewTitle = res.title;
      previewMarkdown = res.markdown;
      previewLabels = res.labels;
      previewRepo = res.repo;
      step = "preview";
    } catch (e) {
      error = (e as Error).message;
    } finally {
      loading = false;
    }
  }

  async function submit() {
    loading = true;
    error = "";
    try {
      const res = await api.submitReport({
        repo,
        type,
        message: message.trim(),
        markdown: previewMarkdown,
      });
      if (res.status === "created" && res.url) {
        resultUrl = res.url;
        resultTitle = previewTitle;
        resultLabels = [...previewLabels];
        resultRepo = previewRepo;
        resultManualUrl = "";
        resultError = "";
        resultHint = "";
        resultMarkdown = "";
      } else {
        resultUrl = "";
        resultTitle = res.title || previewTitle;
        resultLabels = res.labels || [...previewLabels];
        resultRepo = res.repo || previewRepo;
        resultManualUrl = res.manual_url || "";
        resultError = res.error || "Automatic submission failed.";
        resultHint = res.hint || "";
        resultMarkdown = res.markdown || previewMarkdown;
      }
      step = "result";
    } catch (e) {
      error = (e as Error).message;
    } finally {
      loading = false;
    }
  }

  function reset() {
    step = "form";
    message = "";
    error = "";
    resultUrl = "";
    resultTitle = "";
    resultLabels = [];
    resultRepo = "";
    resultManualUrl = "";
    resultError = "";
    resultHint = "";
    resultMarkdown = "";
    copied = false;
  }

  async function copyMarkdown() {
    try {
      await navigator.clipboard.writeText(resultMarkdown);
      copied = true;
      setTimeout(() => (copied = false), 2000);
    } catch {
      try {
        const ta = document.createElement("textarea");
        ta.value = resultMarkdown;
        ta.style.position = "fixed";
        ta.style.opacity = "0";
        document.body.appendChild(ta);
        ta.select();
        document.execCommand("copy");
        document.body.removeChild(ta);
        copied = true;
        setTimeout(() => (copied = false), 2000);
      } catch {
        error = "Copy failed. Please select and copy the text manually.";
      }
    }
  }
</script>

<div class="report-page">
  <h1>Report Issue</h1>

  {#if step === "form"}
    <div class="form-section">
      <div class="field">
        <label for="report-repo">Repository</label>
        <select id="report-repo" bind:value={repo} disabled={metaLoading || repoOptions.length === 0}>
          {#each repoOptions as r}
            <option value={r.value}>{r.label}</option>
          {/each}
        </select>
      </div>

      <div class="field">
        <label for="report-type">Report Type</label>
        <select id="report-type" bind:value={type} disabled={metaLoading || typeOptions.length === 0}>
          {#each typeOptions as t}
            <option value={t.value}>{t.label}</option>
          {/each}
        </select>
      </div>

      <div class="field">
        <label for="report-message">Summary</label>
        <textarea
          id="report-message"
          bind:value={message}
          rows="4"
          placeholder="One-line summary of the bug or feature. You'll be able to fill repro steps, impact, and the rest in the preview."
        ></textarea>
      </div>

      {#if error}
        <div class="message message-error">{error}</div>
      {/if}

      <div class="actions">
        <button class="primary-btn" onclick={goToPreview} disabled={loading || metaLoading || !repo || !type}>
          {metaLoading ? "Loading..." : loading ? "Loading..." : "Next"}
        </button>
      </div>
    </div>

  {:else if step === "preview"}
    <div class="preview-section">
      <div class="preview-header">
        <span class="preview-label">Title</span>
        <code>{previewTitle}</code>
      </div>
      <div class="preview-header">
        <span class="preview-label">Labels</span>
        <span class="label-list">
          {#each previewLabels as label}
            <span class="label-pill">{label}</span>
          {/each}
        </span>
      </div>
      <div class="preview-header">
        <span class="preview-label">Repository</span>
        <code>{previewRepo}</code>
      </div>

      <div class="field">
        <label for="report-preview">Issue Body</label>
        <textarea id="report-preview" bind:value={previewMarkdown} rows="16"></textarea>
      </div>

      <p class="hint">
        Fill in the placeholders before submitting. The preview is the exact issue body that will be sent to GitHub.
      </p>

      {#if error}
        <div class="message message-error">{error}</div>
      {/if}

      <div class="actions actions-split">
        <button class="btn" onclick={() => (step = "form")}>Back</button>
        <button class="primary-btn" onclick={submit} disabled={loading}>
          {loading ? "Submitting..." : "Submit"}
        </button>
      </div>
    </div>

  {:else if step === "result"}
    <div class="result-section">
      {#if resultUrl}
        <div class="message message-success">
          Issue created successfully!
        </div>
        <div class="result-link">
          <a href={resultUrl} target="_blank" rel="noopener noreferrer">{resultUrl}</a>
        </div>
      {:else}
        <div class="message message-error">
          Could not submit automatically.
        </div>
        {#if resultError}
          <p class="hint"><strong>Error:</strong> {resultError}</p>
        {/if}
        {#if resultHint}
          <p class="hint">{resultHint}</p>
        {/if}
        <div class="manual-meta">
          <div class="preview-header">
            <span class="preview-label">Repository</span>
            <code>{resultRepo}</code>
          </div>
          <div class="preview-header">
            <span class="preview-label">Title</span>
            <code>{resultTitle}</code>
          </div>
          <div class="preview-header">
            <span class="preview-label">Labels</span>
            <span class="label-list">
              {#each resultLabels as label}
                <span class="label-pill">{label}</span>
              {/each}
            </span>
          </div>
          {#if resultManualUrl}
            <div class="result-link">
              <a href={resultManualUrl} target="_blank" rel="noopener noreferrer">Open prefilled GitHub issue</a>
            </div>
          {/if}
        </div>
        <div class="fallback-block">
          <div class="fallback-header">
            <span>Copy this content and create the issue manually:</span>
            <button class="btn copy-btn" onclick={copyMarkdown}>
              {copied ? "Copied!" : "Copy"}
            </button>
          </div>
          <pre>{resultMarkdown}</pre>
        </div>
      {/if}

      <div class="actions">
        <button class="btn" onclick={reset}>New Report</button>
      </div>
    </div>
  {/if}
</div>

<style>
  .report-page {
    max-width: 700px;
    margin: 0 auto;
    padding: 2rem;
  }

  h1 {
    font-size: 1.75rem;
    font-weight: 700;
    margin-bottom: 2rem;
    text-transform: uppercase;
    letter-spacing: 2px;
    color: var(--accent);
    text-shadow: var(--text-glow);
  }

  .field {
    margin-bottom: 1.25rem;
  }

  .field label {
    display: block;
    font-size: 0.8125rem;
    font-weight: 700;
    color: var(--fg-dim);
    margin-bottom: 0.5rem;
    text-transform: uppercase;
    letter-spacing: 1px;
  }

  .field select,
  .field textarea {
    width: 100%;
    padding: 0.625rem 0.875rem;
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 2px;
    color: var(--fg);
    font-size: 0.875rem;
    font-family: var(--font-mono);
    outline: none;
    transition: all 0.2s ease;
    box-shadow: inset 0 2px 4px rgba(0, 0, 0, 0.2);
  }

  .field select:focus,
  .field textarea:focus {
    border-color: var(--accent);
    box-shadow: 0 0 8px var(--border-glow);
  }

  .field textarea::placeholder {
    color: color-mix(in srgb, var(--fg-dim) 50%, transparent);
  }

  .field textarea {
    resize: vertical;
    min-height: 200px;
    line-height: 1.5;
  }

  .field select {
    cursor: pointer;
  }

  .preview-header {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    margin-bottom: 0.75rem;
  }

  .preview-label {
    font-size: 0.75rem;
    font-weight: 700;
    color: var(--fg-dim);
    text-transform: uppercase;
    letter-spacing: 1px;
    min-width: 6rem;
  }

  .preview-header code {
    font-family: var(--font-mono);
    font-size: 0.875rem;
    color: var(--fg);
  }

  .label-list {
    display: flex;
    gap: 0.5rem;
    flex-wrap: wrap;
  }

  .label-pill {
    padding: 0.125rem 0.5rem;
    border: 1px solid var(--accent-dim);
    border-radius: var(--radius-sm);
    font-size: 0.75rem;
    color: var(--accent);
    text-transform: uppercase;
    letter-spacing: 0.5px;
  }

  .actions {
    padding-top: 1rem;
    display: flex;
    justify-content: flex-end;
  }

  .actions-split {
    justify-content: space-between;
  }

  .primary-btn {
    padding: 0.75rem 2rem;
    background: color-mix(in srgb, var(--accent) 20%, transparent);
    color: var(--accent);
    border: 1px solid var(--accent);
    border-radius: 2px;
    font-size: 0.875rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 2px;
    cursor: pointer;
    transition: all 0.2s ease;
    text-shadow: var(--text-glow);
    box-shadow: inset 0 0 10px color-mix(in srgb, var(--accent) 30%, transparent);
  }

  .primary-btn:hover:not(:disabled) {
    background: var(--bg-hover);
    box-shadow: 0 0 15px var(--border-glow), inset 0 0 15px color-mix(in srgb, var(--accent) 40%, transparent);
    text-shadow: 0 0 10px var(--accent);
  }

  .primary-btn:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .btn {
    padding: 0.5rem 1.25rem;
    background: var(--bg-surface);
    color: var(--fg-dim);
    border: 1px solid color-mix(in srgb, var(--border) 80%, transparent);
    border-radius: 2px;
    font-size: 0.875rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1px;
    cursor: pointer;
    transition: all 0.2s ease;
  }

  .btn:hover {
    background: var(--bg-hover);
    color: var(--fg);
    border-color: var(--accent-dim);
  }

  .message {
    padding: 0.875rem 1.25rem;
    border-radius: 2px;
    font-size: 0.875rem;
    font-weight: bold;
    margin-bottom: 1rem;
  }

  .message-success {
    background: color-mix(in srgb, var(--success) 10%, transparent);
    border: 1px solid var(--success);
    color: var(--success);
    box-shadow: 0 0 10px color-mix(in srgb, var(--success) 30%, transparent);
  }

  .message-error {
    background: color-mix(in srgb, var(--error) 10%, transparent);
    border: 1px solid var(--error);
    color: var(--error);
    box-shadow: 0 0 10px color-mix(in srgb, var(--error) 30%, transparent);
  }

  .result-link {
    margin-bottom: 1.5rem;
  }

  .result-link a {
    color: var(--accent);
    font-family: var(--font-mono);
    font-size: 0.875rem;
    word-break: break-all;
  }

  .hint {
    font-size: 0.8125rem;
    color: var(--fg-dim);
    margin-bottom: 1rem;
    font-family: var(--font-mono);
    line-height: 1.5;
  }

  .manual-meta {
    margin-bottom: 1rem;
  }

  .fallback-block {
    border: 1px solid var(--border);
    border-radius: 2px;
    margin-bottom: 1.5rem;
    overflow: hidden;
  }

  .fallback-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 0.75rem 1rem;
    background: var(--bg-surface);
    border-bottom: 1px solid var(--border);
    font-size: 0.8125rem;
    color: var(--fg-dim);
  }

  .copy-btn {
    padding: 0.25rem 0.75rem;
    font-size: 0.75rem;
    margin-top: 0;
  }

  .fallback-header {
    gap: 1rem;
  }

  .fallback-block pre {
    padding: 1rem;
    margin: 0;
    font-family: var(--font-mono);
    font-size: 0.8125rem;
    color: var(--fg);
    white-space: pre-wrap;
    word-break: break-word;
    line-height: 1.5;
    max-height: 400px;
    overflow-y: auto;
  }

  @media (max-width: 700px) {
    .report-page {
      padding: 1.25rem;
    }

    .preview-header,
    .fallback-header {
      align-items: flex-start;
      flex-direction: column;
    }

    .actions-split {
      gap: 0.75rem;
      flex-direction: column;
      align-items: stretch;
    }
  }
</style>
