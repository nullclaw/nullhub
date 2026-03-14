<script lang="ts">
  let { workflow = { nodes: {}, edges: [] }, nodeStatus = {} } = $props<{
    workflow: { nodes: Record<string, any>; edges: { from: string; to: string; condition?: string }[] };
    nodeStatus: Record<string, string>;
  }>();

  const NODE_W = 140;
  const NODE_H = 40;
  const LAYER_GAP = 80;
  const NODE_GAP = 60;
  const PAD = 40;
  const CIRCLE_R = 16;

  const typeLabels: Record<string, string> = {
    task: 'T', route: 'R', interrupt: 'I', agent: 'A', send: 'S', transform: 'X', subgraph: 'G',
  };

  const statusColors: Record<string, string> = {
    pending: 'var(--fg-dim)',
    running: 'var(--accent)',
    completed: 'var(--success)',
    failed: 'var(--error)',
    interrupted: 'var(--warning)',
  };

  interface LayoutNode {
    id: string;
    x: number;
    y: number;
    type: string;
    label: string;
    isTerminal: boolean;
  }

  function layout(nodes: Record<string, any>, edges: { from: string; to: string }[]): {
    lnodes: LayoutNode[];
    ledges: { x1: number; y1: number; x2: number; y2: number }[];
    width: number;
    height: number;
  } {
    const allIds = new Set<string>();
    allIds.add('__start__');
    allIds.add('__end__');
    for (const id of Object.keys(nodes || {})) allIds.add(id);
    for (const e of edges || []) { allIds.add(e.from); allIds.add(e.to); }

    // BFS layering
    const adj = new Map<string, string[]>();
    for (const id of allIds) adj.set(id, []);
    for (const e of edges || []) {
      adj.get(e.from)?.push(e.to);
    }

    const layers = new Map<string, number>();
    const queue: string[] = ['__start__'];
    layers.set('__start__', 0);

    // Guard against cycles: limit total iterations to n * e
    const maxIter = allIds.size * (edges?.length || 1) + allIds.size;
    let iter = 0;
    while (queue.length > 0 && iter < maxIter) {
      iter++;
      const cur = queue.shift()!;
      const cl = layers.get(cur)!;
      for (const next of adj.get(cur) || []) {
        if (!layers.has(next) || layers.get(next)! < cl + 1) {
          layers.set(next, cl + 1);
          queue.push(next);
        }
      }
    }

    // Assign unvisited nodes to layer 1
    for (const id of allIds) {
      if (!layers.has(id)) layers.set(id, 1);
    }

    // Group by layer
    const byLayer = new Map<number, string[]>();
    for (const [id, layer] of layers) {
      if (!byLayer.has(layer)) byLayer.set(layer, []);
      byLayer.get(layer)!.push(id);
    }

    const maxLayer = Math.max(...byLayer.keys(), 0);

    // Position nodes
    const positions = new Map<string, { x: number; y: number }>();
    let maxWidth = 0;
    for (let l = 0; l <= maxLayer; l++) {
      const ids = byLayer.get(l) || [];
      const count = ids.length;
      const totalWidth = count * NODE_W + (count - 1) * NODE_GAP;
      if (totalWidth > maxWidth) maxWidth = totalWidth;
      for (let i = 0; i < count; i++) {
        positions.set(ids[i], {
          x: PAD + i * (NODE_W + NODE_GAP) + NODE_W / 2,
          y: PAD + l * (NODE_H + LAYER_GAP) + NODE_H / 2,
        });
      }
    }

    // Center each layer relative to widest
    const viewW = maxWidth + PAD * 2;
    for (let l = 0; l <= maxLayer; l++) {
      const ids = byLayer.get(l) || [];
      const count = ids.length;
      const layerWidth = count * NODE_W + (count - 1) * NODE_GAP;
      const offset = (viewW - layerWidth) / 2 - PAD;
      for (const id of ids) {
        const p = positions.get(id)!;
        p.x += offset;
      }
    }

    const viewH = (maxLayer + 1) * (NODE_H + LAYER_GAP) + PAD;

    const lnodes: LayoutNode[] = [];
    for (const id of allIds) {
      const pos = positions.get(id)!;
      const isTerminal = id === '__start__' || id === '__end__';
      lnodes.push({
        id,
        x: pos.x,
        y: pos.y,
        type: nodes?.[id]?.type || 'task',
        label: isTerminal ? id.replace(/__/g, '') : id,
        isTerminal,
      });
    }

    const ledges: { x1: number; y1: number; x2: number; y2: number }[] = [];
    for (const e of edges || []) {
      const from = positions.get(e.from);
      const to = positions.get(e.to);
      if (from && to) {
        ledges.push({
          x1: from.x,
          y1: from.y + (allIds.has(e.from) && (e.from === '__start__' || e.from === '__end__') ? CIRCLE_R : NODE_H / 2),
          x2: to.x,
          y2: to.y - (allIds.has(e.to) && (e.to === '__start__' || e.to === '__end__') ? CIRCLE_R : NODE_H / 2),
        });
      }
    }

    return { lnodes, ledges, width: viewW, height: viewH };
  }

  let graph = $derived(layout(workflow.nodes || {}, workflow.edges || []));
</script>

<div class="graph-viewer">
  <svg viewBox="0 0 {Math.max(graph.width, 200)} {Math.max(graph.height, 100)}" class="dag-svg">
    <defs>
      <marker id="arrowhead" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
        <polygon points="0 0, 8 3, 0 6" fill="var(--fg-dim)" />
      </marker>
    </defs>

    {#each graph.ledges as edge}
      <line
        x1={edge.x1}
        y1={edge.y1}
        x2={edge.x2}
        y2={edge.y2}
        class="edge-line"
        marker-end="url(#arrowhead)"
      />
    {/each}

    {#each graph.lnodes as node}
      {#if node.isTerminal}
        <circle
          cx={node.x}
          cy={node.y}
          r={CIRCLE_R}
          class="terminal-node"
          style="--node-fill: {statusColors[nodeStatus[node.id] || 'pending']}"
        />
        <text x={node.x} y={node.y + 4} class="terminal-label">{node.label}</text>
      {:else}
        {@const color = statusColors[nodeStatus[node.id] || 'pending']}
        <rect
          x={node.x - NODE_W / 2}
          y={node.y - NODE_H / 2}
          width={NODE_W}
          height={NODE_H}
          rx="6"
          class="node-rect"
          style="--node-stroke: {color}"
        />
        <text
          x={node.x - NODE_W / 2 + 10}
          y={node.y + 1}
          class="type-label"
          style="fill: {color}"
        >{typeLabels[node.type] || '?'}</text>
        <text
          x={node.x - NODE_W / 2 + 26}
          y={node.y + 1}
          class="node-label"
        >{node.label.length > 12 ? node.label.slice(0, 11) + '...' : node.label}</text>
      {/if}
    {/each}
  </svg>
</div>

<style>
  .graph-viewer {
    width: 100%;
    height: 100%;
    overflow: auto;
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 4px;
  }
  .dag-svg {
    width: 100%;
    height: auto;
    min-height: 200px;
  }
  .edge-line {
    stroke: var(--fg-dim);
    stroke-width: 1.5;
    opacity: 0.6;
  }
  .terminal-node {
    fill: color-mix(in srgb, var(--node-fill) 25%, var(--bg-surface));
    stroke: var(--node-fill);
    stroke-width: 2;
  }
  .terminal-label {
    fill: var(--fg-dim);
    font-size: 10px;
    font-family: var(--font-mono);
    text-anchor: middle;
    text-transform: uppercase;
    letter-spacing: 0.5px;
  }
  .node-rect {
    fill: var(--bg-surface);
    stroke: var(--node-stroke);
    stroke-width: 2;
    transition: stroke 0.3s ease;
  }
  .type-label {
    font-size: 11px;
    font-family: var(--font-mono);
    font-weight: 700;
    dominant-baseline: middle;
  }
  .node-label {
    fill: var(--fg);
    font-size: 11px;
    font-family: var(--font-mono);
    dominant-baseline: middle;
  }
</style>
