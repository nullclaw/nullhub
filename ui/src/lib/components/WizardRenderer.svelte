<script lang="ts">
  import WizardStep from './WizardStep.svelte';
  import { api } from '$lib/api/client';

  let { component = '', steps = [], onComplete } = $props<{
    component: string;
    steps: any[];
    onComplete?: () => void;
  }>();

  let answers = $state<Record<string, string>>({});
  let instanceName = $state('');
  let currentStep = $state(0);
  let installing = $state(false);
  let installMessage = $state('');

  // Auto-generate instance name on mount
  $effect(() => {
    if (component && !instanceName) {
      api.getInstances().then((data: any) => {
        const existing = data?.instances?.[component] || {};
        const names = Object.keys(existing);
        let id = 1;
        while (names.includes(`instance-${id}`)) id++;
        instanceName = `instance-${id}`;
      }).catch(() => {
        instanceName = 'instance-1';
      });
    }
  });

  // Apply default values from steps
  $effect(() => {
    for (const step of steps) {
      if (step.default_value && !(step.id in answers)) {
        answers[step.id] = step.default_value;
      } else if (step.options?.length && !(step.id in answers)) {
        // Auto-select recommended option
        const rec = step.options.find((o: any) => o.recommended);
        if (rec) answers[step.id] = rec.value;
      }
    }
  });

  function isStepVisible(step: any): boolean {
    if (!step.condition) return true;
    const ref = answers[step.condition.step] || '';
    if (step.condition.equals) return ref === step.condition.equals;
    if (step.condition.not_equals) return ref !== step.condition.not_equals;
    if (step.condition.contains) return ref.split(',').includes(step.condition.contains);
    if (step.condition.not_in) {
      const excluded = step.condition.not_in.split(',');
      return !excluded.includes(ref);
    }
    return true;
  }

  let visibleSteps = $derived(steps.filter(isStepVisible));

  async function submit() {
    installing = true;
    installMessage = 'Installing...';
    try {
      const payload = {
        instance_name: instanceName,
        version: 'latest',
        ...answers
      };
      const result = await api.postWizard(component, payload);
      installMessage = result.message || 'Installation complete!';
      onComplete?.();
    } catch (e) {
      installMessage = `Error: ${(e as Error).message}`;
    } finally {
      installing = false;
    }
  }
</script>

<div class="wizard">
  <div class="wizard-header">
    <h2>Install {component}</h2>
  </div>

  <div class="wizard-body">
    <div class="name-step">
      <label>Instance Name</label>
      <input type="text" bind:value={instanceName} placeholder="instance-1" />
    </div>

    {#each visibleSteps as step}
      <WizardStep
        {step}
        value={answers[step.id] || ''}
        onchange={(v) => answers[step.id] = v}
      />
    {/each}
  </div>

  {#if installMessage}
    <div class="install-message">{installMessage}</div>
  {/if}

  <div class="wizard-footer">
    <button class="primary-btn" onclick={submit} disabled={installing || !instanceName}>
      {installing ? 'Installing...' : 'Install'}
    </button>
  </div>
</div>

<style>
  .wizard {
    background: var(--bg-secondary);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    overflow: hidden;
  }

  .wizard-header {
    padding: 1.25rem 1.5rem;
    border-bottom: 1px solid var(--border);
  }

  .wizard-header h2 {
    font-size: 1.125rem;
    font-weight: 600;
  }

  .wizard-body {
    padding: 1.5rem;
  }

  .name-step {
    margin-bottom: 1.5rem;
  }

  .name-step label {
    display: block;
    font-size: 0.9rem;
    font-weight: 600;
    color: var(--text-primary);
    margin-bottom: 0.25rem;
  }

  .name-step input {
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

  .name-step input:focus {
    border-color: var(--accent);
  }

  .install-message {
    padding: 0.75rem 1.5rem;
    font-size: 0.875rem;
    color: var(--text-secondary);
    border-top: 1px solid var(--border);
  }

  .wizard-footer {
    padding: 1rem 1.5rem;
    border-top: 1px solid var(--border);
    display: flex;
    justify-content: flex-end;
  }

  .primary-btn {
    background: var(--accent);
    color: #fff;
    border: none;
    border-radius: var(--radius);
    padding: 0.6rem 1.5rem;
    font-size: 0.875rem;
    font-weight: 500;
    cursor: pointer;
    transition: background 0.15s;
  }

  .primary-btn:hover:not(:disabled) {
    background: var(--accent-hover);
  }

  .primary-btn:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }
</style>
