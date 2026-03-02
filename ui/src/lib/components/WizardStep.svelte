<script lang="ts">
  let { step, value = '', onchange } = $props<{
    step: { id: string; title: string; description?: string; type: string; options?: Array<{value: string; label: string; description?: string; recommended?: boolean}>; required?: boolean; default_value?: string };
    value: string;
    onchange: (value: string) => void;
  }>();

  // Searchable dropdown state (for select with many options)
  const SEARCHABLE_THRESHOLD = 10;
  let searchQuery = $state('');
  let dropdownOpen = $state(false);

  let isSearchable = $derived(step.type === 'select' && (step.options?.length || 0) > SEARCHABLE_THRESHOLD);

  let filteredOptions = $derived(
    isSearchable && searchQuery
      ? (step.options || []).filter(o =>
          o.label.toLowerCase().includes(searchQuery.toLowerCase()) ||
          o.value.toLowerCase().includes(searchQuery.toLowerCase()) ||
          (o.description || '').toLowerCase().includes(searchQuery.toLowerCase())
        )
      : (step.options || [])
  );

  let selectedOption = $derived(
    (step.options || []).find(o => o.value === value)
  );
  let selectedLabel = $derived(
    selectedOption ? (selectedOption.recommended ? `${selectedOption.label} (recommended)` : selectedOption.label) : ''
  );

  function selectOption(optValue: string) {
    onchange(optValue);
    dropdownOpen = false;
    searchQuery = '';
  }

  function handleSearchInput(e: Event) {
    searchQuery = (e.target as HTMLInputElement).value;
    dropdownOpen = true;
  }

  function handleSearchFocus() {
    dropdownOpen = true;
  }

  function handleSearchBlur() {
    // Delay to allow click on option
    setTimeout(() => { dropdownOpen = false; }, 200);
  }
</script>

<div class="wizard-step">
  <label class="step-title">{step.title}</label>
  {#if step.description}
    <p class="step-description">{step.description}</p>
  {/if}

  {#if step.type === 'select' && isSearchable}
    <!-- Searchable dropdown for select with many options -->
    <div class="searchable-select">
      <input
        type="text"
        class="search-input"
        placeholder={selectedLabel || 'Search...'}
        value={dropdownOpen ? searchQuery : selectedLabel}
        oninput={handleSearchInput}
        onfocus={handleSearchFocus}
        onblur={handleSearchBlur}
      />
      {#if dropdownOpen}
        <div class="dropdown">
          {#each filteredOptions as option}
            <button
              class="dropdown-item"
              class:selected={value === option.value}
              onmousedown={() => selectOption(option.value)}
            >
              <div class="dropdown-item-header">
                <strong>{option.label}</strong>
                {#if option.recommended}
                  <span class="rec-badge">recommended</span>
                {/if}
              </div>
              {#if option.description}
                <span class="dropdown-item-desc">{option.description}</span>
              {/if}
            </button>
          {:else}
            <div class="dropdown-empty">No matches</div>
          {/each}
        </div>
      {/if}
    </div>
  {:else if step.type === 'select'}
    <div class="options">
      {#each step.options || [] as option}
        <button
          class="option-btn"
          class:selected={value === option.value}
          onclick={() => onchange(option.value)}
        >
          <div class="option-header">
            <strong>{option.label}</strong>
            {#if option.recommended}
              <span class="rec-badge">recommended</span>
            {/if}
          </div>
          {#if option.description}<span>{option.description}</span>{/if}
        </button>
      {/each}
    </div>
  {:else if step.type === 'multi_select'}
    <div class="options multi">
      {#each step.options || [] as option}
        {@const selected = value.split(',').includes(option.value)}
        <button
          class="option-btn chip"
          class:selected
          onclick={() => {
            const vals = value ? value.split(',').filter(Boolean) : [];
            if (selected) onchange(vals.filter(v => v !== option.value).join(','));
            else onchange([...vals, option.value].join(','));
          }}
        >
          <strong>{option.label}</strong>
        </button>
      {/each}
    </div>
  {:else if step.type === 'secret'}
    <input type="password" {value} oninput={(e) => onchange(e.currentTarget.value)} placeholder="Enter secret..." />
  {:else if step.type === 'number'}
    <input type="number" {value} oninput={(e) => onchange(e.currentTarget.value)} />
  {:else if step.type === 'toggle'}
    <label class="toggle">
      <input type="checkbox" checked={value === 'true'} onchange={(e) => onchange(String(e.currentTarget.checked))} />
      <span class="toggle-slider"></span>
    </label>
  {:else}
    <input type="text" {value} oninput={(e) => onchange(e.currentTarget.value)} placeholder="Enter value..." />
  {/if}
</div>

<style>
  .wizard-step {
    margin-bottom: 1.5rem;
  }

  .step-title {
    display: block;
    font-size: 0.9rem;
    font-weight: 600;
    color: var(--text-primary);
    margin-bottom: 0.25rem;
  }

  .step-description {
    font-size: 0.8rem;
    color: var(--text-secondary);
    margin-bottom: 0.75rem;
  }

  /* Regular options (radio-style buttons) */
  .options {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
  }

  .options.multi {
    flex-direction: row;
    flex-wrap: wrap;
  }

  .option-btn {
    display: flex;
    flex-direction: column;
    gap: 0.2rem;
    text-align: left;
    background: var(--bg-tertiary);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 0.75rem 1rem;
    color: var(--text-primary);
    cursor: pointer;
    transition: border-color 0.15s, background 0.15s;
  }

  .option-btn:hover {
    background: var(--bg-hover);
  }

  .option-btn.selected {
    border-color: var(--accent);
    background: var(--bg-hover);
  }

  .option-btn strong {
    font-size: 0.875rem;
  }

  .option-btn span {
    font-size: 0.75rem;
    color: var(--text-secondary);
  }

  .option-btn.chip {
    flex-direction: row;
    padding: 0.5rem 0.75rem;
  }

  .option-header {
    display: flex;
    align-items: center;
    gap: 0.5rem;
  }

  /* Recommended badge */
  .rec-badge {
    font-size: 0.65rem;
    font-weight: 500;
    background: var(--accent);
    color: #fff;
    padding: 0.1rem 0.4rem;
    border-radius: var(--radius-sm);
    text-transform: uppercase;
    letter-spacing: 0.03em;
  }

  /* Searchable dropdown */
  .searchable-select {
    position: relative;
  }

  .search-input {
    width: 100%;
    background: var(--bg-tertiary);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 0.6rem 0.75rem;
    color: var(--text-primary);
    font-size: 0.875rem;
    font-family: var(--font-sans);
    outline: none;
    transition: border-color 0.15s;
  }

  .search-input:focus {
    border-color: var(--accent);
  }

  .dropdown {
    position: absolute;
    top: 100%;
    left: 0;
    right: 0;
    max-height: 320px;
    overflow-y: auto;
    background: var(--bg-secondary);
    border: 1px solid var(--border);
    border-top: none;
    border-radius: 0 0 var(--radius) var(--radius);
    z-index: 100;
    box-shadow: 0 4px 12px rgba(0,0,0,0.3);
  }

  .dropdown-item {
    display: flex;
    flex-direction: column;
    gap: 0.15rem;
    width: 100%;
    text-align: left;
    background: none;
    border: none;
    border-bottom: 1px solid var(--border);
    padding: 0.6rem 0.75rem;
    color: var(--text-primary);
    cursor: pointer;
    transition: background 0.1s;
  }

  .dropdown-item:last-child {
    border-bottom: none;
  }

  .dropdown-item:hover {
    background: var(--bg-hover);
  }

  .dropdown-item.selected {
    background: var(--bg-hover);
    border-left: 2px solid var(--accent);
  }

  .dropdown-item-header {
    display: flex;
    align-items: center;
    gap: 0.5rem;
  }

  .dropdown-item strong {
    font-size: 0.85rem;
  }

  .dropdown-item-desc {
    font-size: 0.75rem;
    color: var(--text-secondary);
  }

  .dropdown-empty {
    padding: 0.75rem;
    color: var(--text-secondary);
    font-size: 0.85rem;
    text-align: center;
  }

  /* Inputs */
  input[type='text'],
  input[type='password'],
  input[type='number'] {
    width: 100%;
    background: var(--bg-tertiary);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 0.6rem 0.75rem;
    color: var(--text-primary);
    font-size: 0.875rem;
    font-family: var(--font-sans);
    outline: none;
    transition: border-color 0.15s;
  }

  input[type='text']:focus,
  input[type='password']:focus,
  input[type='number']:focus {
    border-color: var(--accent);
  }

  /* Toggle */
  .toggle {
    position: relative;
    display: inline-block;
    width: 44px;
    height: 24px;
    cursor: pointer;
  }

  .toggle input {
    opacity: 0;
    width: 0;
    height: 0;
  }

  .toggle-slider {
    position: absolute;
    inset: 0;
    background: var(--bg-tertiary);
    border: 1px solid var(--border);
    border-radius: 12px;
    transition: background 0.2s;
  }

  .toggle-slider::before {
    content: '';
    position: absolute;
    width: 18px;
    height: 18px;
    left: 2px;
    top: 2px;
    background: var(--text-secondary);
    border-radius: 50%;
    transition: transform 0.2s, background 0.2s;
  }

  .toggle input:checked + .toggle-slider {
    background: var(--accent);
    border-color: var(--accent);
  }

  .toggle input:checked + .toggle-slider::before {
    transform: translateX(20px);
    background: #fff;
  }
</style>
