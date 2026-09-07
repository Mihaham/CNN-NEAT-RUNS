/* Shared dashboard helpers. Paths are relative for GitVerse Pages. */

function qs(name) {
  return new URLSearchParams(location.search).get(name);
}

function fmt(v, digits) {
  if (v == null || (typeof v === "number" && Number.isNaN(v))) return "—";
  if (typeof v === "number") return v.toFixed(digits == null ? 4 : digits);
  return String(v);
}

async function loadJSON(rel) {
  const url = rel;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Failed to load ${url}: ${res.status}`);
  return res.json();
}

function seriesFromRows(rows, xKey, yKeys) {
  if (!Array.isArray(rows) || !rows.length) return [];
  const traces = [];
  for (const y of yKeys) {
    const xs = [];
    const ys = [];
    for (const row of rows) {
      if (row[y] == null) continue;
      xs.push(row[xKey]);
      ys.push(row[y]);
    }
    if (!xs.length) continue;
    traces.push({ x: xs, y: ys, name: y, mode: "lines+markers", type: "scatter" });
  }
  return traces;
}

function profileRows(values, yName) {
  if (!Array.isArray(values) || !values.length) return [];
  return values.map((v, i) => ({ index: i, [yName]: v }));
}

function renderCharts(container, dataSources) {
  const specs = window.CHART_SPECS || [];
  container.innerHTML = "";
  for (const spec of specs) {
    let rows = null;
    if (spec.source === "epochs") rows = dataSources.epochs;
    else if (spec.source === "history") rows = dataSources.history;
    else if (spec.source === "cone") rows = dataSources.cone;
    else if (spec.source === "cache") rows = dataSources.cache;
    else if (spec.source === "spatial") rows = profileRows(dataSources.spatialSides, "side");
    else if (spec.source === "channels") rows = profileRows(dataSources.channelProfile, "channels");
    else if (spec.source === "weights") rows = dataSources.weights;
    const traces = seriesFromRows(rows, spec.x, spec.y);
    if (!traces.length) continue;
    const wrap = document.createElement("div");
    wrap.className = "card";
    const title = document.createElement("div");
    title.className = "chart-title";
    title.textContent = spec.title;
    const div = document.createElement("div");
    div.className = "chart";
    div.id = "chart-" + spec.id;
    wrap.appendChild(title);
    wrap.appendChild(div);
    container.appendChild(wrap);
    Plotly.newPlot(
      div,
      traces,
      {
        margin: { t: 24, r: 16, b: 40, l: 52 },
        paper_bgcolor: "transparent",
        plot_bgcolor: "transparent",
        font: { color: "#c5d0da", size: 11 },
        legend: { orientation: "h", y: 1.12 },
        xaxis: { gridcolor: "#2a3542", title: spec.x },
        yaxis: { gridcolor: "#2a3542" },
      },
      { responsive: true, displayModeBar: false }
    );
  }
}

function renderKeyValues(el, obj, title) {
  if (!el || !obj || !Object.keys(obj).length) return;
  const lines = Object.keys(obj)
    .sort()
    .map((k) => `${k}: ${JSON.stringify(obj[k])}`);
  el.textContent = (title ? title + "\n" : "") + lines.join("\n");
}

function renderTopologySketch(el, draw) {
  if (!el || !draw || !Array.isArray(draw.nodes) || !draw.nodes.length) {
    if (el) el.textContent = "No topology_draw.";
    return;
  }
  const nodes = draw.nodes;
  const edges = draw.edges || [];
  const xs = nodes.map((n) => n.x);
  const ys = nodes.map((n) => n.y);
  const colors = nodes.map((n) => (n.kind === "input" ? "#5b9fd4" : n.kind === "output" ? "#3dd68c" : "#c5d0da"));
  const sizes = nodes.map((n) => Math.max(8, Math.min(28, (n.side || 1) * 0.6)));
  const edgeTraces = [];
  const byId = Object.fromEntries(nodes.map((n) => [n.id, n]));
  for (const e of edges) {
    const a = byId[e.src];
    const b = byId[e.dst];
    if (!a || !b) continue;
    const color = !e.enabled ? "#444" : e.sign < 0 ? "#f87171" : e.sign > 0 ? "#34d399" : "#8b9aab";
    edgeTraces.push({
      x: [a.x, b.x],
      y: [a.y, b.y],
      mode: "lines",
      type: "scatter",
      line: { color, width: e.enabled ? (e.on_output_path ? 2.2 : 1.2) : 0.6, dash: e.enabled ? "solid" : "dot" },
      hoverinfo: "text",
      text: `e ${e.src}→${e.dst} w=${e.weight_scale} k=${JSON.stringify(e.kernel)}`,
      showlegend: false,
    });
  }
  Plotly.newPlot(
    el,
    [
      ...edgeTraces,
      {
        x: xs,
        y: ys,
        mode: "markers+text",
        type: "scatter",
        text: nodes.map((n) => String(n.id)),
        textposition: "top center",
        marker: { size: sizes, color: colors },
        hovertext: nodes.map((n) => `#${n.id} ${n.kind} ${n.h}x${n.w} c=${n.c}`),
        hoverinfo: "text",
        showlegend: false,
      },
    ],
    {
      margin: { t: 16, r: 16, b: 32, l: 32 },
      paper_bgcolor: "transparent",
      plot_bgcolor: "transparent",
      font: { color: "#c5d0da", size: 11 },
      xaxis: { title: "depth", gridcolor: "#2a3542", zeroline: false },
      yaxis: { title: "lane", gridcolor: "#2a3542", zeroline: false },
    },
    { responsive: true, displayModeBar: false }
  );
}

function genomeSummary(genome) {
  if (!genome || typeof genome !== "object") return "No champion genome.";
  const nodes = genome.node_sizes ? Object.keys(genome.node_sizes).length : "?";
  const conns = Array.isArray(genome.connections) ? genome.connections.length : 0;
  const enabled = Array.isArray(genome.connections)
    ? genome.connections.filter((c) => c && c.enabled !== false).length
    : 0;
  const acts = genome.node_activations || {};
  const actSet = [...new Set(Object.values(acts))];
  return [
    `nodes≈${nodes}  connections=${conns} (enabled=${enabled})`,
    `activations: ${actSet.join(", ") || "—"}`,
    `input_channels=${genome.input_channels}  image=${JSON.stringify(genome.input_image_size)}`,
    `output_nodes=${JSON.stringify(genome.output_nodes)}`,
    `edge_weights=${genome.edge_weights}`,
  ].join("\n");
}

function sortTable(table, col, numeric) {
  const tbody = table.tBodies[0];
  const rows = Array.from(tbody.rows);
  const dir = table.dataset.sortCol === String(col) && table.dataset.sortDir === "asc" ? "desc" : "asc";
  table.dataset.sortCol = String(col);
  table.dataset.sortDir = dir;
  rows.sort((a, b) => {
    const av = a.cells[col].dataset.val ?? a.cells[col].textContent;
    const bv = b.cells[col].dataset.val ?? b.cells[col].textContent;
    if (numeric) {
      const an = parseFloat(av);
      const bn = parseFloat(bv);
      if (Number.isNaN(an) && Number.isNaN(bn)) return 0;
      if (Number.isNaN(an)) return 1;
      if (Number.isNaN(bn)) return -1;
      return dir === "asc" ? an - bn : bn - an;
    }
    return dir === "asc" ? String(av).localeCompare(String(bv)) : String(bv).localeCompare(String(av));
  });
  rows.forEach((r) => tbody.appendChild(r));
}

async function initIndex() {
  const meta = document.getElementById("meta");
  const tbody = document.querySelector("#studies tbody");
  const filter = document.getElementById("filter");
  try {
    const data = await loadJSON("./data/studies.json");
    meta.textContent = `head ${String(data.head || "").slice(0, 12)} · generated ${data.generated_at || "—"} · ${
      (data.studies || []).length
    } studies`;
    const render = () => {
      const q = (filter.value || "").toLowerCase();
      tbody.innerHTML = "";
      for (const s of data.studies || []) {
        const hay = `${s.id} ${s.label} ${s.source_path} ${s.script_id || ""}`.toLowerCase();
        if (q && !hay.includes(q)) continue;
        const tr = document.createElement("tr");
        tr.innerHTML = `
          <td><a href="./study.html?s=${encodeURIComponent(s.id)}">${s.id}</a></td>
          <td>${s.source_path || ""}</td>
          <td>${s.script_id ?? "—"}</td>
          <td data-val="${s.n_runs ?? ""}">${s.n_runs ?? "—"}</td>
          <td data-val="${s.n_results ?? ""}">${s.n_results ?? "—"}</td>
          <td data-val="${s.best_bal_acc ?? ""}">${fmt(s.best_bal_acc)}</td>
          <td>${s.has_holdout ? "yes" : "—"}</td>
          <td>${s.finished ? "done" : "…"}</td>`;
        tbody.appendChild(tr);
      }
    };
    filter.addEventListener("input", render);
    document.querySelectorAll("#studies th[data-col]").forEach((th) => {
      th.addEventListener("click", () =>
        sortTable(document.getElementById("studies"), Number(th.dataset.col), th.dataset.num === "1")
      );
    });
    render();
  } catch (e) {
    meta.innerHTML = `<span class="error">${e.message}</span>`;
  }
}

async function initStudy() {
  const sid = qs("s");
  const meta = document.getElementById("meta");
  if (!sid) {
    meta.innerHTML = '<span class="error">Missing ?s=study_id</span>';
    return;
  }
  document.getElementById("title").textContent = sid;
  document.getElementById("back").href = "./index.html";
  try {
    const summary = await loadJSON(`./data/studies/${encodeURIComponent(sid)}/summary.json`);
    const results = await loadJSON(`./data/studies/${encodeURIComponent(sid)}/results.json`);
    meta.textContent = `${summary.source_path} · runs ${summary.n_runs} · results ${summary.n_results} · best bal_acc ${fmt(
      summary.best_bal_acc
    )}`;

    const tbody = document.querySelector("#runs tbody");
    const filter = document.getElementById("filter");
    const errBox = document.getElementById("errors");
    const errors = (results || []).filter((r) => r.error);
    if (errors.length && errBox) {
      errBox.style.display = "block";
      errBox.innerHTML =
        `<h2>Result errors (${errors.length})</h2><ul>` +
        errors
          .slice(0, 50)
          .map(
            (r) =>
              `<li><code>${r.phase || ""}/${r.config_name || ""}</code> class=${r.class_id}: ${String(r.error).slice(0, 200)}</li>`
          )
          .join("") +
        (errors.length > 50 ? `<li>…and ${errors.length - 50} more</li>` : "") +
        `</ul>`;
    }
    const render = () => {
      const q = (filter.value || "").toLowerCase();
      tbody.innerHTML = "";
      for (const r of summary.runs || []) {
        const hay = `${r.run_key} ${r.run_dir} ${JSON.stringify(r.meta)}`.toLowerCase();
        if (q && !hay.includes(q)) continue;
        const tr = document.createElement("tr");
        tr.innerHTML = `
          <td><a href="./run.html?s=${encodeURIComponent(sid)}&r=${encodeURIComponent(r.run_key)}">${r.run_key}</a></td>
          <td>${r.meta?.activation ?? "—"} / ${r.meta?.output_readout ?? "—"}</td>
          <td data-val="${r.n_epochs ?? ""}">${r.n_epochs ?? "—"}</td>
          <td data-val="${r.best_bal_acc ?? ""}">${fmt(r.best_bal_acc)}</td>
          <td data-val="${r.best_fitness ?? ""}">${fmt(r.best_fitness)}</td>
          <td data-val="${r.series_fitness_gain ?? ""}">${fmt(r.series_fitness_gain)}</td>
          <td data-val="${r.best_nodes ?? ""}">${r.best_nodes ?? "—"}</td>
          <td data-val="${r.topo_graph_depth ?? ""}">${r.topo_graph_depth ?? "—"}</td>
          <td data-val="${r.topo_weight_neg_frac ?? ""}">${fmt(r.topo_weight_neg_frac)}</td>
          <td data-val="${r.topo_spatial_reduction_ratio ?? ""}">${fmt(r.topo_spatial_reduction_ratio, 2)}</td>
          <td data-val="${r.w_sign_neg_frac ?? ""}">${fmt(r.w_sign_neg_frac)}</td>
          <td>${r.has_champion ? "yes" : "—"}</td>`;
        tbody.appendChild(tr);
      }
    };
    filter.addEventListener("input", render);
    render();

    // Overlay history charts for top result rows (first matching)
    const charts = document.getElementById("charts");
    const top = [...results]
      .filter((x) => x.history_compact && x.history_compact.length)
      .sort((a, b) => (b.best_bal_acc || 0) - (a.best_bal_acc || 0))[0];
    if (top) {
      const note = document.createElement("p");
      note.className = "muted";
      note.textContent = `Study-level curves from best result row: ${top.config_name} phase=${top.phase} class=${top.class_id}`;
      charts.appendChild(note);
      renderCharts(charts, { history: top.history_compact, epochs: null, cone: null, cache: null });
    }

    try {
      const holdout = await loadJSON(`./data/studies/${encodeURIComponent(sid)}/holdout.json`);
      const box = document.getElementById("holdout");
      box.style.display = "block";
      const s = holdout.summary || {};
      box.innerHTML = `<h2>Holdout</h2>
        <p>n=${s.n_evaluated ?? "—"} mean_val_bal=${fmt(s.mean_val_bal_acc)} mean_test_bal=${fmt(
        s.mean_test_bal_acc
      )} mean_gap=${fmt(s.mean_gap)} pearson=${fmt(s.pearson_val_test)}</p>`;
    } catch (_) {
      /* no holdout */
    }
  } catch (e) {
    meta.innerHTML = `<span class="error">${e.message}</span>`;
  }
}

async function initRun() {
  const sid = qs("s");
  const rid = qs("r");
  const meta = document.getElementById("meta");
  if (!sid || !rid) {
    meta.innerHTML = '<span class="error">Missing ?s= &amp; ?r=</span>';
    return;
  }
  document.getElementById("title").textContent = rid;
  document.getElementById("back").href = `./study.html?s=${encodeURIComponent(sid)}`;
  try {
    const run = await loadJSON(
      `./data/studies/${encodeURIComponent(sid)}/runs/${encodeURIComponent(rid)}.json`
    );
    meta.textContent = `${run.run_dir} · epochs ${run.epochs?.length ?? 0} · topo_count ${
      run.topology_registry_count ?? "—"
    }`;
    const m = run.meta || {};
    document.getElementById("meta-box").textContent = Object.entries(m)
      .map(([k, v]) => `${k}: ${JSON.stringify(v)}`)
      .join("\n");

    let history = null;
    try {
      const results = await loadJSON(`./data/studies/${encodeURIComponent(sid)}/results.json`);
      const match = (results || []).find((row) => {
        const path = String(row.run_path || "").replace(/\\/g, "/");
        return path.endsWith(run.run_dir) || path.includes(rid.replace(/__/g, "/")) || path.includes(run.run_dir);
      });
      if (match) history = match.history_compact;
    } catch (_) {}

    renderCharts(document.getElementById("charts"), {
      epochs: run.epochs,
      history,
      cone: run.cone_points,
      cache: run.cache_points,
      weights: run.weight_series,
      spatialSides: (run.champion && run.champion.topology_draw && run.champion.topology_draw.spatial_sides) || [],
      channelProfile: (run.champion && run.champion.topology_draw && run.champion.topology_draw.channel_profile) || [],
    });

    renderKeyValues(document.getElementById("topo-metrics"), run.topology_metrics, "topology_metrics");
    renderKeyValues(document.getElementById("series-metrics"), run.series_metrics, "series_metrics");
    renderKeyValues(document.getElementById("lineage-metrics"), run.lineage_metrics, "lineage_metrics");
    renderKeyValues(document.getElementById("weight-metrics"), run.weight_metrics, "weight_metrics (Conv tensors)");
    const sketch = document.getElementById("topo-sketch");
    if (sketch) {
      renderTopologySketch(sketch, (run.champion && run.champion.topology_draw) || null);
    }

    const g = document.getElementById("genome");
    if (run.champion) {
      g.textContent =
        genomeSummary(run.champion.genome) +
        "\n\n" +
        JSON.stringify(
          {
            generation: run.champion.generation,
            idx: run.champion.idx,
            fitness: run.champion.fitness,
            lineage: run.champion.lineage,
            topology_metrics: run.champion.topology_metrics,
            topology_draw: run.champion.topology_draw,
            genome: run.champion.genome,
          },
          null,
          2
        );
    } else {
      g.textContent = "No champion genome extracted.";
    }
  } catch (e) {
    meta.innerHTML = `<span class="error">${e.message}</span>`;
  }
}

window.Dashboard = { initIndex, initStudy, initRun };
