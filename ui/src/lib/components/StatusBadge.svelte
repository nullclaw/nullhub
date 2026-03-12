<script lang="ts">
  let { status = "stopped" } = $props();

  const colors: Record<string, string> = {
    running: "var(--success)",
    stopped: "var(--text-muted)",
    starting: "var(--warning)",
    failed: "var(--error)",
    restarting: "var(--warning)",
  };
</script>

<span
  class="badge"
  class:running={status === "running"}
  style="--badge-color: {colors[status] || 'var(--text-muted)'}"
>
  {status}
</span>

<style>
  .badge {
    display: inline-flex;
    align-items: center;
    gap: 0.5rem;
    padding: 0.25rem 0.75rem;
    border-radius: 2px;
    font-size: 0.75rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1px;
    background: color-mix(in srgb, var(--badge-color) 10%, transparent);
    color: var(--badge-color);
    box-shadow: inset 0 0 5px
      color-mix(in srgb, var(--badge-color) 20%, transparent);
    text-shadow: 0 0 5px var(--badge-color);
  }
  .badge::before {
    content: "";
    width: 6px;
    height: 6px;
    border-radius: var(--radius);
    background: var(--badge-color);
    box-shadow: 0 0 6px var(--badge-color);
  }
</style>
