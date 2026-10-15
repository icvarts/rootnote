(() => {
  const $ = (id) => document.getElementById(id);
  const number = new Intl.NumberFormat("zh-CN", { maximumFractionDigits: 1 });
  const severityRank = { normal: 0, notice: 1, warning: 2, high: 3, critical: 4 };
  const petMotion = {
    green: { folder: "idle", frames: 6, interval: 820 },
    yellow: { folder: "waiting", frames: 6, interval: 560 },
    red: { folder: "failed", frames: 8, interval: 520 },
  };
  let petTimer = null;

  function bytes(value) {
    const n = Number(value || 0);
    if (n >= 1e9) return `${number.format(n / 1e9)} GB`;
    if (n >= 1e6) return `${number.format(n / 1e6)} MB`;
    return `${number.format(n / 1e3)} KB`;
  }

  function symbol(state) {
    return state === "red" ? "!" : state === "yellow" ? "△" : "✓";
  }

  function animatePet(state) {
    const motion = petMotion[state] || petMotion.red;
    const stage = $("pet-stage");
    const image = $("status-pet");
    let frame = 0;
    clearInterval(petTimer);
    stage.className = `pet-stage ${state}`;
    image.src = `../scene/rootnote/${motion.folder}/00.png`;
    petTimer = setInterval(() => {
      frame = (frame + 1) % motion.frames;
      image.src = `../scene/rootnote/${motion.folder}/${String(frame).padStart(2, "0")}.png`;
    }, motion.interval);
  }

  function pathFor(points, width, height) {
    if (!points.length) return "";
    const min = Math.min(...points);
    const max = Math.max(...points);
    const spread = Math.max(max - min, 1);
    return points.map((value, index) => {
      const x = 14 + index * ((width - 28) / Math.max(points.length - 1, 1));
      const y = height - 18 - ((value - min) / spread) * (height - 42);
      return `${index ? "L" : "M"}${x.toFixed(2)},${y.toFixed(2)}`;
    }).join(" ");
  }

  function inferredRiskSource(session) {
    const size = Number(session.sizeBytes || 0);
    const growth = Number(session.growthBytesPerHour || 0);
    const signals = [];
    if (size >= 1e9) signals.push("体积 ≥ 1 GB");
    else if (size >= 500e6) signals.push("体积 ≥ 500 MB");
    else if (size >= 250e6) signals.push("体积 ≥ 250 MB");
    else if (size >= 100e6) signals.push("体积 ≥ 100 MB");
    if (growth >= 400e6) signals.push("增长 ≥ 400 MB/h");
    else if (growth >= 200e6) signals.push("增长 ≥ 200 MB/h");
    return signals.length ? signals.join(" · ") : "低于会话阈值";
  }

  function sessionAction(session) {
    const rank = severityRank[session.severityID] || 0;
    if (rank >= 4) return "立即停止扩展，完成交接与归档";
    if (rank >= 3) return "优先建立承接窗口，交接后归档";
    if (rank >= 2) return "尽快收口，不再开启复杂分支";
    if (rank >= 1) return "留意增长，确认已有续接记录";
    return session.active ? "正在运行 · 当前无需处理" : "已打开 · 当前无需处理";
  }

  function archiveLabel(session) {
    const rank = severityRank[session.severityID] || 0;
    if (rank >= 4) return "交接后归档";
    if (rank >= 3) return "优先归档";
    if (rank >= 2) return "建议归档";
    if (rank >= 1) return "暂缓扩展";
    return "无需归档";
  }

  function applySnapshot(snapshot) {
    const state = ["green", "yellow", "red"].includes(snapshot.microState)
      ? snapshot.microState : "red";
    const metrics = snapshot.metrics || {};
    const sessions = Array.isArray(snapshot.sessions) ? [...snapshot.sessions] : [];
    const history = Array.isArray(snapshot.history) ? snapshot.history : [];
    sessions.sort((left, right) => {
      const riskDelta = (severityRank[right.severityID] || 0) -
        (severityRank[left.severityID] || 0);
      return riskDelta || Number(right.sizeBytes || 0) - Number(left.sizeBytes || 0);
    });
    const riskySessions = sessions.filter((session) =>
      (severityRank[session.severityID] || 0) > 0
    );

    $("status-chip").className = `status-chip ${state}`;
    $("status-symbol").textContent = symbol(state);
    $("severity-label").textContent = snapshot.severityLabel || "未知";
    animatePet(state);
    $("headline").textContent = snapshot.headline || "暂时无法确认系统压力";
    $("recommendation").textContent = snapshot.recommendation || "等待下一次本地采样。";
    $("observed-at").textContent = snapshot.observedAt
      ? `更新于 ${new Date(snapshot.observedAt).toLocaleTimeString("zh-CN", {
        hour: "2-digit", minute: "2-digit"
      })}`
      : "等待第一份本地快照";
    $("task-count").textContent = snapshot.activeTaskCountReliable
      ? String(snapshot.activeTaskCount ?? 0) : "统计中";
    $("risk-session-count").textContent = String(riskySessions.length);
    $("risk-session-fact").className = `summary-fact risk ${state}`;
    $("memory").textContent = `${bytes(metrics.memoryUsedBytes)} / ${bytes(metrics.memoryTotalBytes)}`;
    $("free-memory").textContent = metrics.memoryFreePercent == null
      ? "可用比例暂不可确认" : `系统可用 ${number.format(metrics.memoryFreePercent)}%`;
    $("swap").textContent = bytes(metrics.swapUsedBytes);
    $("compressed").textContent = bytes(metrics.compressedBytes);
    $("sessions-summary").textContent =
      `${metrics.activeSessionCount || 0} 个 · ${bytes(metrics.totalOpenBytes)}`;
    $("history-total").textContent = bytes(metrics.totalOpenBytes);
    $("collector-health").textContent =
      `采集器：${snapshot.collectorHealth === "healthy" ? "正常" :
        snapshot.collectorHealth === "degraded" ? "降级" : "不可用"}`;

    if (riskySessions.length) {
      const first = riskySessions[0];
      $("risk-context").textContent =
        `先处理《${first.title || "未命名会话"}》：${first.riskSource ||
          inferredRiskSource(first)}。其余会话按风险等级继续向下排列。`;
    } else if (state === "red") {
      $("risk-context").textContent =
        "当前红色主要来自系统级 Swap / 压缩内存压力；没有单一会话越过容量红线，先收口体积最大的运行会话。";
    } else if (snapshot.codexIdle === true) {
      $("risk-context").textContent =
        "当前没有打开或运行中的 Codex 会话，无需归档。";
    } else {
      $("risk-context").textContent = "当前没有会话越过容量或增长阈值。";
    }

    const values = history.map((item) => Number(item.sessions || 0));
    const line = pathFor(values, 800, 150);
    $("history-line").setAttribute("d", line);
    $("history-area").setAttribute("d", line ? `${line} L786,138 L14,138 Z` : "");

    const rows = sessions.map((session) => {
      const row = document.createElement("div");
      row.className = `session-row ${session.severityID || "normal"}`;
      row.innerHTML = `
        <div class="session-title">
          <div class="session-name-line">
            <strong></strong>
            <span class="risk-badge">${session.severityLabel || "正常"}</span>
          </div>
          <small>${session.riskSource || inferredRiskSource(session)} · ${sessionAction(session)}</small>
        </div>
        <div class="session-size">
          <strong>${bytes(session.sizeBytes)}</strong>
          <small>${archiveLabel(session)}</small>
        </div>`;
      row.querySelector(".session-title strong").textContent =
        session.title || "未命名会话";
      return row;
    });
    if (!rows.length) {
      const empty = document.createElement("div");
      empty.className = "empty-state";
      empty.textContent = snapshot.codexIdle === true
        ? "当前没有打开或运行中的 Codex 会话"
        : "尚未发现打开的 Codex 会话元数据";
      rows.push(empty);
    }
    $("session-list").replaceChildren(...rows);
  }

  window.RootnotePerformance = { applySnapshot };

  const fixture = new URLSearchParams(location.search).get("fixture");
  if (fixture) {
    const idle = fixture === "idle";
    const fixtureState = idle ? "green" : fixture;
    applySnapshot({
      observedAt: new Date().toISOString(),
      microState: fixtureState,
      codexIdle: idle,
      severityLabel: fixtureState === "red" ? "严重" : fixtureState === "yellow" ? "预警" : "正常",
      collectorHealth: "healthy",
      headline: idle ? "当前没有运行任务" : fixtureState === "red" ? "性能压力需要立即关注" :
        fixtureState === "yellow" ? "性能压力需要留意" : "系统呼吸平稳",
      recommendation: idle
        ? "暂时没有 Codex 工作负载，无需性能处置；系统指标仅作背景参考。"
        : fixtureState === "red"
        ? "先处理高风险会话；完成交接和归档后，再决定是否重启 Codex 与 Mac。"
        : fixtureState === "yellow" ? "当前阶段尽快收口，不再开启复杂分支。" :
          "状态正常，可以继续使用。",
      activeTaskCount: idle ? 0 : 3,
      activeTaskCountReliable: true,
      metrics: {
        memoryUsedBytes: 15e9, memoryTotalBytes: 17.18e9,
        swapUsedBytes: idle ? 4.3e9 : fixtureState === "red" ? 11.27e9 :
          fixtureState === "yellow" ? 4.8e9 : .8e9,
        compressedBytes: idle ? 4.7e9 : fixtureState === "red" ? 6.54e9 : 3.2e9,
        memoryFreePercent: 13,
        activeSessionCount: idle ? 0 : 3,
        totalOpenBytes: idle ? 0 : 646e6
      },
      history: (idle ? [0, 0, 0, 0, 0, 0, 0, 0] : [130, 160, 190, 250, 310, 420, 520, 646]).map((sessions) => ({
        sessions: sessions * 1e6
      })),
      sessions: idle ? [] : [
        {
          title: "内容增长 0.2", active: true,
          severityID: fixtureState === "red" ? "high" :
            fixtureState === "yellow" ? "warning" : "normal",
          severityLabel: fixtureState === "red" ? "高风险" :
            fixtureState === "yellow" ? "预警" : "正常",
          riskSource: fixtureState === "red" ? "体积 ≥ 500 MB · 增长 ≥ 200 MB/h" :
            fixtureState === "yellow" ? "增长 ≥ 200 MB/h" : "低于会话阈值",
          sizeBytes: fixtureState === "green" ? 82.9e6 : 552.9e6,
          growthBytesPerHour: fixtureState === "green" ? 18e6 : 228e6
        },
        {
          title: "Rootnote × Codex 性能守卫融合 0.1", active: true,
          severityID: "normal", severityLabel: "正常",
          riskSource: "低于会话阈值",
          sizeBytes: 55e6, growthBytesPerHour: 18e6
        },
        {
          title: "人生设计记录 1.0", active: true,
          severityID: "normal", severityLabel: "正常",
          riskSource: "低于会话阈值",
          sizeBytes: 38.1e6, growthBytesPerHour: 3e6
        }
      ]
    });
  }
})();
