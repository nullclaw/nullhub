<script>
  import '../app.css';
  import { onMount } from 'svelte';
  import Sidebar from '$lib/components/Sidebar.svelte';
  import TopBar from '$lib/components/TopBar.svelte';
  import { redirectToPreferredOrigin } from '$lib/nullhubAccess';

  let { children } = $props();

  onMount(() => {
    void redirectToPreferredOrigin(window.location);
  });
</script>

<div class="app-layout">
  <Sidebar />
  <div class="main-area">
    <TopBar />
    <main class="content">
      {@render children()}
    </main>
  </div>
</div>

<style>
  .app-layout {
    display: flex;
    height: 100vh;
    overflow: hidden;
  }
  .main-area {
    flex: 1;
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }
  .content {
    flex: 1;
    overflow-y: auto;
    padding: 1.5rem;
    position: relative;
    z-index: 10;
  }
</style>
