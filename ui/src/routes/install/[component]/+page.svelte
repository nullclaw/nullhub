<script lang="ts">
  import { page } from '$app/stores';
  import { goto } from '$app/navigation';
  import WizardRenderer from '$lib/components/WizardRenderer.svelte';
  import { api } from '$lib/api/client';

  let componentName = $derived($page.params.component);
  let wizardData = $state<any>(null);

  $effect(() => {
    const comp = componentName;
    wizardData = null;
    api.getWizard(comp).then((data) => {
      wizardData = data;
    }).catch((e) => {
      console.error(e);
    });
  });
</script>

<div class="wizard-page">
  {#if wizardData}
    <WizardRenderer
      component={componentName}
      steps={wizardData?.wizard?.steps || wizardData?.steps || []}
      onComplete={() => goto('/')}
    />
  {:else}
    <p>Loading wizard...</p>
  {/if}
</div>

<style>
  .wizard-page { max-width: 600px; margin: 0 auto; }
</style>
