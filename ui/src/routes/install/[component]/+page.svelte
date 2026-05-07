<script lang="ts">
  import { page } from '$app/stores';
  import { goto } from '$app/navigation';
  import WizardRenderer from '$lib/components/WizardRenderer.svelte';
  import { api } from '$lib/api/client';

  let componentName = $derived($page.params.component);
  let wizardData = $state<any>(null);
  let wizardError = $state('');

  $effect(() => {
    const comp = componentName;
    wizardData = null;
    wizardError = '';
    api.getWizard(comp).then((data) => {
      if (data?.error) {
        wizardError = data.error;
      } else {
        wizardData = data;
      }
    }).catch((e) => {
      wizardError = (e as Error).message;
    });
  });

  function visibleWizardSteps(steps: any[], component: string) {
    return steps.filter(
      (s: any) =>
        s.id !== 'gateway_port' &&
        !(component === 'nullclaw' && s.id === 'port')
    );
  }
</script>

<div class="wizard-page">
  {#if wizardError}
    <div class="wizard-error">
      <p>{wizardError}</p>
      <button onclick={() => goto('/install')}>Back</button>
    </div>
  {:else if wizardData}
    <WizardRenderer
      component={componentName}
      steps={visibleWizardSteps(wizardData?.wizard?.steps || wizardData?.steps || [], componentName)}
      onComplete={() => goto('/')}
    />
  {:else}
    <p>Loading wizard...</p>
  {/if}
</div>

<style>
  .wizard-page { max-width: 600px; margin: 0 auto; }
  .wizard-error {
    background: var(--bg-secondary);
    border: 1px solid color-mix(in srgb, var(--error) 30%, transparent);
    border-radius: var(--radius);
    padding: 2rem;
    text-align: center;
  }
  .wizard-error p {
    color: var(--text-primary);
    margin-bottom: 1rem;
    font-size: 0.9rem;
  }
  .wizard-error button {
    padding: 0.4rem 1rem;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    background: var(--bg-tertiary);
    color: var(--text-primary);
    font-size: 0.8125rem;
    cursor: pointer;
  }
  .wizard-error button:hover {
    background: var(--bg-hover);
    border-color: var(--accent);
  }
</style>
