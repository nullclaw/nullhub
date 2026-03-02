<script lang="ts">
  import { onMount } from 'svelte';
  import ComponentCard from '$lib/components/ComponentCard.svelte';
  import { api } from '$lib/api/client';

  let components = $state<any[]>([]);

  onMount(async () => {
    try {
      const data = await api.getComponents();
      components = data.components || [];
    } catch (e) {
      console.error(e);
    }
  });
</script>

<div class="install-page">
  <h1>Install Component</h1>
  <p class="subtitle">Choose a component to install</p>

  <div class="catalog-grid">
    {#each components as comp}
      <ComponentCard
        name={comp.name}
        displayName={comp.display_name}
        description={comp.description}
        installed={comp.installed}
        standalone={comp.standalone}
        instanceCount={comp.instance_count}
      />
    {/each}
  </div>
</div>

<style>
  .install-page { max-width: 900px; }
  h1 { margin-bottom: 0.25rem; }
  .subtitle { color: var(--text-secondary); margin-bottom: 1.5rem; }
  .catalog-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 1rem; }
</style>
