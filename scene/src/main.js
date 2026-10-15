import * as THREE from "three";
import "./styles.css";

const canvas = document.querySelector("#scene-canvas");
const app = document.querySelector("#app");
const rootnote = document.querySelector("#rootnote");
const rootnoteWrap = document.querySelector("#rootnote-wrap");
const demoToggle = document.querySelector("#demo-toggle");
const statusState = document.querySelector("#status-state");
const statusRole = document.querySelector("#status-role");
const statusAgents = document.querySelector("#status-agents");
const statusPressure = document.querySelector("#status-pressure");
const stateCaption = document.querySelector("#state-caption");
const youngTreeCanvas = document.querySelector("#young-tree-canvas");
const youngTreeBillboard = document.querySelector("#young-tree-billboard");
const treeBillboard = document.querySelector("#tree-billboard");
const stateButtons = [...document.querySelectorAll("[data-state-button]")];
const modifierButtons = [...document.querySelectorAll("[data-modifier-button]")];
const billboardAgentNodes = [...document.querySelectorAll(".agent-node")];
const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
const assetUrl = (path) => new URL(path, document.baseURI).href;

const worldMap = {
  companion: {
    label: "同行",
    role: "在场",
    caption: "保持在场",
    tree: 0,
    agents: 0,
    pressure: 0,
    weather: 0,
    field: 0,
    paths: 0,
    mist: 0,
    rootnoteSet: "idle",
  },
  margin: {
    label: "探索",
    role: "观察",
    caption: "来源与证据开始显影",
    tree: 0,
    agents: 0,
    pressure: 0.12,
    weather: 0,
    field: 0.08,
    paths: 1,
    mist: 0.74,
    rootnoteSet: "running",
  },
  agents: {
    label: "共振",
    role: "组织",
    caption: "能力离体扎根",
    tree: 0.68,
    agents: 3,
    pressure: 0.32,
    weather: 0,
    field: 0.28,
    paths: 0.16,
    mist: 0,
    rootnoteSet: "running",
  },
  shelter: {
    label: "展开",
    role: "庇护",
    caption: "为行动撑开空间",
    tree: 1,
    agents: 5,
    pressure: 1,
    weather: 1,
    field: 1,
    paths: 0,
    mist: 0,
    rootnoteSet: "review",
  },
};

const modifierMap = {
  waiting: {
    label: "等待",
    role: "请求",
    caption: "等待你的确认",
    rootnoteSet: "waiting",
  },
  failure: {
    label: "冲击",
    role: "复稳",
    caption: "吸收冲击，重新站稳",
    rootnoteSet: "failed",
  },
  review: {
    label: "完成",
    role: "确认",
    caption: "结果已归还给你",
    rootnoteSet: "review",
  },
};

const frameSets = {
  idle: Array.from({ length: 6 }, (_, index) => assetUrl(`rootnote/idle/${String(index).padStart(2, "0")}.png`)),
  running: Array.from({ length: 6 }, (_, index) => assetUrl(`rootnote/running/${String(index).padStart(2, "0")}.png`)),
  waiting: Array.from({ length: 6 }, (_, index) => assetUrl(`rootnote/waiting/${String(index).padStart(2, "0")}.png`)),
  failed: Array.from({ length: 8 }, (_, index) => assetUrl(`rootnote/failed/${String(index).padStart(2, "0")}.png`)),
  review: Array.from({ length: 6 }, (_, index) => assetUrl(`rootnote/review/${String(index).padStart(2, "0")}.png`)),
};

Object.values(frameSets).flat().forEach((source) => {
  const image = new Image();
  image.src = source;
});

const renderer = new THREE.WebGLRenderer({ canvas, alpha: true, antialias: true, preserveDrawingBuffer: true });
renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
renderer.setClearColor(0x000000, 0);
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 1.05;

const scene = new THREE.Scene();
const camera = new THREE.OrthographicCamera(-6, 6, 4.5, -4.5, 0.1, 40);
camera.position.set(0, 0, 14);
camera.lookAt(0, 0, 0);

scene.add(new THREE.HemisphereLight(0xcfe5d5, 0x141c1b, 1.45));
const keyLight = new THREE.DirectionalLight(0xf4e4bd, 2.1);
keyLight.position.set(4, 7, 8);
scene.add(keyLight);
const resonanceLight = new THREE.PointLight(0x4fd8ca, 7, 9, 2);
resonanceLight.position.set(-0.8, 0.8, 3);
scene.add(resonanceLight);

const treeGroup = new THREE.Group();
treeGroup.position.set(-1.35, -3.45, 0);
scene.add(treeGroup);

const branchSegments = [];
const veinSegments = [];
const leaves = [];
const agentNodes = [];
const random = mulberry32(0x524f4f54);
const unitY = new THREE.Vector3(0, 1, 0);
const zAxis = new THREE.Vector3(0, 0, 1);

const barkMaterial = new THREE.MeshStandardMaterial({
  color: 0x33433a,
  roughness: 0.9,
  metalness: 0.03,
});
const rootMaterial = new THREE.MeshStandardMaterial({
  color: 0x293b35,
  roughness: 0.96,
  metalness: 0.01,
});
const leafMaterials = [
  new THREE.MeshStandardMaterial({ color: 0x5f8054, roughness: 0.88 }),
  new THREE.MeshStandardMaterial({ color: 0x78925c, roughness: 0.9 }),
  new THREE.MeshStandardMaterial({ color: 0x496b5d, roughness: 0.86 }),
  new THREE.MeshStandardMaterial({ color: 0x8ba065, roughness: 0.92 }),
];
const veinMaterial = new THREE.LineBasicMaterial({
  color: 0x5ee4d0,
  transparent: true,
  opacity: 0,
  blending: THREE.AdditiveBlending,
  depthWrite: false,
});

buildTree();
treeGroup.visible = false;
const field = buildField();
const weather = buildWeather();
const ambient = buildAmbientParticles();
const exploration = buildExploration();
void prepareYoungTree();

const current = { tree: 0, agents: 0, pressure: 0, weather: 0, field: 0, paths: 0, mist: 0 };
const petAnchor = { x: 0.82, y: 0.86 };
const petAnchorTarget = { ...petAnchor };
let treeAnchorX = petAnchor.x;
let anchorInitialized = false;
let fieldAnchorX = 2.15;
const clock = new THREE.Clock();
let activeWorld = "companion";
let activeModifier = "none";
let agentCount = 0;
let activeFrameSet = "idle";
let frameIndex = 0;
let nextFrameAt = 0;
let shockStartedAt = -10;
let modifierStartedAt = -10;
let waitingTreeLevel = 0;
let demoTimer = null;
let demoIndex = 0;
const demoScenarios = [
  { world: "companion", agents: 0 },
  { world: "margin", agents: 0 },
  { world: "agents", agents: 1 },
  { world: "agents", agents: 3 },
  { world: "shelter", agents: 5 },
  { world: "shelter", agents: 5, modifier: "waiting" },
  { world: "shelter", agents: 5, modifier: "failure" },
  { world: "shelter", agents: 5, modifier: "review" },
];

stateButtons.forEach((button) => {
  button.addEventListener("click", () => {
    stopDemo();
    setWorld(button.dataset.stateButton);
  });
});

modifierButtons.forEach((button) => {
  button.addEventListener("click", () => {
    stopDemo();
    setModifier(button.dataset.modifierButton);
  });
});

demoToggle.addEventListener("click", () => {
  if (demoTimer) {
    stopDemo();
    return;
  }
  demoToggle.setAttribute("aria-pressed", "true");
  demoToggle.querySelector("span").textContent = "■";
  demoIndex = 0;
  applyScenario(demoScenarios[demoIndex]);
  demoTimer = window.setInterval(() => {
    demoIndex = (demoIndex + 1) % demoScenarios.length;
    applyScenario(demoScenarios[demoIndex]);
  }, reducedMotion ? 3400 : 4600);
});

window.addEventListener("keydown", (event) => {
  if (event.key === "1") setWorld("companion");
  if (event.key === "2") setWorld("margin");
  if (event.key === "3") setWorld("agents");
  if (event.key === "4") setWorld("shelter");
  if (event.key.toLowerCase() === "w") setModifier("waiting");
  if (event.key.toLowerCase() === "f") setModifier("failure");
  if (event.key.toLowerCase() === "r") setModifier("review");
});

window.addEventListener("resize", resize);
resize();
setWorld("companion");

const renderFrame = () => {
  const delta = Math.min(clock.getDelta(), 0.05);
  const elapsed = clock.elapsedTime;
  updateTrackedAnchor(delta);
  updateState(delta, elapsed);
  updateRootnote(elapsed);
  renderer.render(scene, camera);
};

window.RootnoteSceneLifecycle.attach({
  start: () => renderer.setAnimationLoop(renderFrame),
  stop: () => renderer.setAnimationLoop(null),
  reset: () => {
    stopDemo();
    setWorld("companion");
    for (const key of Object.keys(current)) current[key] = 0;
  },
  discardDelta: () => clock.getDelta(),
});
if (!document.documentElement.classList.contains("desktop-runtime")) {
  window.RootnoteSceneLifecycle.setSuspended(false);
}

window.RootnoteResonance = Object.freeze({
  setWorld,
  setModifier,
  setAgentCount,
  setPetAnchor,
  setPresentationMode,
  dispatch: dispatchStimulus,
  snapshot: () => ({
    world: activeWorld,
    modifier: activeModifier,
    agents: agentCount,
    tree: Number(current.tree.toFixed(3)),
    pressure: Number(current.pressure.toFixed(3)),
    weather: Number(current.weather.toFixed(3)),
    field: Number(current.field.toFixed(3)),
    paths: Number(current.paths.toFixed(3)),
    mist: Number(current.mist.toFixed(3)),
    anchor: { x: petAnchor.x, y: petAnchor.y },
    anchorTarget: { x: petAnchorTarget.x, y: petAnchorTarget.y },
    treeAnchorX,
    pathAnchorError: Math.hypot(
      (exploration.destination.x - camera.left) / (camera.right - camera.left) - petAnchor.x,
      (camera.top - exploration.destination.y) / (camera.top - camera.bottom) - petAnchor.y,
    ),
    anchorTargetError: Math.hypot(
      petAnchorTarget.x - petAnchor.x,
      petAnchorTarget.y - petAnchor.y,
    ),
    pathTargetError: Math.max(...exploration.paths.map((path) => path.curve.v3.distanceTo(exploration.destination))),
    fieldTargetError: Math.abs(fieldAnchorX - (exploration.destination.x - 0.6)),
  }),
});

window.webkit?.messageHandlers?.rootnoteDesktop?.postMessage({ type: "ready" });

function setWorld(nextWorld, options = {}) {
  if (!worldMap[nextWorld]) return false;
  const nextAgentCount = THREE.MathUtils.clamp(
    Number.isFinite(options.agentCount) ? Math.round(options.agentCount) : worldMap[nextWorld].agents,
    0,
    5,
  );
  if (nextWorld === "shelter" && nextAgentCount === 0) return false;
  const previousWorld = activeWorld;
  activeWorld = nextWorld;
  agentCount = nextAgentCount;

  if (!options.keepModifier) activeModifier = "none";
  if (nextWorld === "shelter" && previousWorld !== "shelter") shockStartedAt = clock.elapsedTime;
  syncUi();
  return true;
}

function setPresentationMode(mode) {
  if (!["background", "desktop", "reveal"].includes(mode)) return false;
  app.dataset.presentation = mode;
  return true;
}

function setPetAnchor(x, y = petAnchor.y) {
  const nextX = Number(x);
  const nextY = Number(y);
  if (!Number.isFinite(nextX) || !Number.isFinite(nextY)) return false;
  petAnchorTarget.x = THREE.MathUtils.clamp(nextX, 0.04, 0.96);
  petAnchorTarget.y = THREE.MathUtils.clamp(nextY, 0.08, 0.96);
  if (!anchorInitialized) {
    petAnchor.x = petAnchorTarget.x;
    petAnchor.y = petAnchorTarget.y;
    treeAnchorX = petAnchorTarget.x;
    anchorInitialized = true;
    updateAnchorLayout();
  }
  return true;
}

function updateTrackedAnchor(delta) {
  const previousX = petAnchor.x;
  const previousY = petAnchor.y;
  const followSpeed = reducedMotion ? 18 : 9;
  petAnchor.x = damp(petAnchor.x, petAnchorTarget.x, followSpeed, delta);
  petAnchor.y = damp(petAnchor.y, petAnchorTarget.y, followSpeed, delta);
  if (current.tree < 0.055) {
    treeAnchorX = damp(treeAnchorX, petAnchorTarget.x, 5.5, delta);
  }
  if (Math.abs(previousX - petAnchor.x) > 0.00005 || Math.abs(previousY - petAnchor.y) > 0.00005) {
    updateAnchorLayout();
  }
}

function setModifier(nextModifier) {
  const requestedModifier = nextModifier === activeModifier ? "none" : nextModifier;
  if (requestedModifier !== "none" && !modifierMap[requestedModifier]) return false;
  activeModifier = requestedModifier;
  modifierStartedAt = clock.elapsedTime;
  if (activeModifier === "waiting") waitingTreeLevel = current.tree;
  if (activeModifier === "failure") shockStartedAt = clock.elapsedTime;
  syncUi();
  return true;
}

function setAgentCount(nextCount) {
  const next = THREE.MathUtils.clamp(Math.round(Number(nextCount) || 0), 0, 5);
  if (next > 0 && (activeWorld === "companion" || activeWorld === "margin")) {
    return setWorld("agents", { agentCount: next });
  }
  if (next === 0 && (activeWorld === "agents" || activeWorld === "shelter")) {
    return setWorld("companion", { agentCount: 0 });
  }
  agentCount = next;
  syncUi();
  return true;
}

function applyScenario(scenario) {
  setWorld(scenario.world, { agentCount: scenario.agents });
  if (scenario.modifier) setModifier(scenario.modifier);
}

function dispatchStimulus(type, detail = {}) {
  if (["idle", "no-task", "companion"].includes(type)) return setWorld("companion");
  if (["search", "reading", "analysis", "explore"].includes(type)) return setWorld("margin");
  if (["agent-start", "agents", "collaboration"].includes(type)) {
    return setWorld("agents", { agentCount: detail.agents ?? 1 });
  }
  if (["pressure", "deploy", "shelter"].includes(type)) {
    if (agentCount > 0) return setWorld("shelter", { agentCount: Math.max(agentCount, 1) });
    return setModifier("failure");
  }
  if (["waiting", "approval"].includes(type)) return setModifier("waiting");
  if (["failure", "retry", "scope-change"].includes(type)) return setModifier("failure");
  if (["complete", "review"].includes(type)) return setModifier("review");
  if (type === "clear") return setModifier("none");
  return false;
}

function syncUi() {
  const world = worldMap[activeWorld];
  const modifier = activeModifier === "none" ? null : modifierMap[activeModifier];
  const nextFrameSet = modifier?.rootnoteSet ?? world.rootnoteSet;
  if (nextFrameSet !== activeFrameSet) {
    activeFrameSet = nextFrameSet;
    frameIndex = 0;
    nextFrameAt = 0;
  }

  app.dataset.sceneState = activeWorld;
  app.dataset.modifier = activeModifier;
  rootnoteWrap.dataset.state = activeWorld;
  rootnoteWrap.dataset.modifier = activeModifier;

  stateButtons.forEach((button) => {
    button.setAttribute("aria-pressed", String(button.dataset.stateButton === activeWorld));
  });
  modifierButtons.forEach((button) => {
    button.setAttribute("aria-pressed", String(button.dataset.modifierButton === activeModifier));
  });

  statusState.textContent = modifier ? `${world.label} · ${modifier.label}` : world.label;
  statusRole.textContent = modifier?.role ?? world.role;
  statusAgents.textContent = `协作 ${agentCount}`;
  stateCaption.textContent = modifier?.caption ?? world.caption;
  billboardAgentNodes.forEach((node, index) => {
    node.classList.toggle("is-active", index % 5 < agentCount);
  });
}

function stopDemo() {
  if (!demoTimer) return;
  window.clearInterval(demoTimer);
  demoTimer = null;
  demoToggle.setAttribute("aria-pressed", "false");
  demoToggle.querySelector("span").textContent = "▶";
}

function updateState(delta, elapsed) {
  const world = worldMap[activeWorld];
  let targetTree = world.tree;
  let targetAgents = agentCount;
  let targetPressure = world.pressure;
  let targetWeather = world.weather;
  let targetField = world.field;
  let targetPaths = world.paths;
  let targetMist = world.mist;

  if (activeWorld === "agents") {
    targetTree = agentCount > 0 ? 0.27 + ((agentCount - 1) / 4) * 0.44 : 0;
    targetField = 0.15 + (agentCount / 5) * 0.22;
  }

  const modifierAge = Math.max(0, elapsed - modifierStartedAt);
  if (activeModifier === "waiting") {
    targetTree = waitingTreeLevel;
    targetWeather *= 0.62;
    targetField *= 0.72;
  } else if (activeModifier === "failure") {
    targetPressure = Math.max(targetPressure, 0.78);
    targetWeather = Math.max(targetWeather, activeWorld === "shelter" ? 1 : 0.48);
    targetPaths = 0;
    targetMist *= 0.28;
  } else if (activeModifier === "review") {
    const explorationReview = activeWorld === "margin";
    const retractStart = explorationReview ? 14 : 0.7;
    const retractDuration = explorationReview ? 5 : 5.8;
    const retract = smoothstep(THREE.MathUtils.clamp((modifierAge - retractStart) / retractDuration, 0, 1));
    targetTree *= 1 - retract;
    targetAgents *= 1 - retract;
    targetPressure = 0;
    targetWeather = 0;
    targetField *= (1 - retract) * (explorationReview ? 0.72 : 0.35);
    targetPaths = explorationReview ? world.paths * (1 - retract) * 0.82 : 0;
    targetMist *= (1 - retract) * (explorationReview ? 0.58 : 0.18);
  }

  current.tree = damp(current.tree, targetTree, 2.25, delta);
  current.agents = damp(current.agents, targetAgents, 2.7, delta);
  current.pressure = damp(current.pressure, targetPressure, 1.9, delta);
  current.weather = damp(current.weather, targetWeather, 2.2, delta);
  current.field = damp(current.field, targetField, 2.5, delta);
  current.paths = damp(current.paths, targetPaths, 2.4, delta);
  current.mist = damp(current.mist, targetMist, 1.7, delta);

  updateTree(elapsed);
  updateField(elapsed);
  updateWeather(delta, elapsed);
  updateExploration(delta, elapsed);
  updateAmbient(elapsed);

  statusAgents.textContent = `协作 ${Math.round(current.agents)}`;
  statusPressure.textContent = `负荷 ${Math.round(current.pressure * 100)}`;
  app.dataset.agentCount = String(Math.max(0, Math.round(current.agents)));
  const matureTree = smoothstep(remap(current.tree, 0.58, 1));
  const youngTree = smoothstep(remap(current.tree, 0.06, 0.31)) * (1 - smoothstep(remap(current.tree, 0.67, 0.94)));
  const impactDecay = activeModifier === "failure" ? Math.max(0, 1 - modifierAge / 2.2) : 0;
  const treeLean = reducedMotion ? 0 : Math.sin(elapsed * 8.4) * impactDecay * 1.7;
  app.style.setProperty("--tree-progress", matureTree.toFixed(3));
  app.style.setProperty("--young-tree-progress", youngTree.toFixed(3));
  app.style.setProperty("--tree-reveal", `${Math.max(0, (1 - current.tree) * 76).toFixed(2)}%`);
  app.style.setProperty("--tree-brightness", (0.7 + current.tree * 0.28 + current.field * 0.08).toFixed(3));
  app.style.setProperty("--tree-scale", (0.84 + matureTree * 0.16).toFixed(3));
  app.style.setProperty("--young-tree-scale", (0.58 + current.tree * 0.72).toFixed(3));
  app.style.setProperty("--tree-lean", `${treeLean.toFixed(3)}deg`);
  resonanceLight.intensity = 1.2 + current.tree * 4.8 + Math.sin(elapsed * 2.1) * current.tree * 0.55;
  ambient.material.opacity = 0.1 + current.tree * 0.2 + current.paths * 0.08;
}

function updateTree(elapsed) {
  branchSegments.forEach((segment) => {
    const progress = smoothstep(remap(current.tree, segment.growStart, segment.growEnd));
    segment.mesh.visible = progress > 0.002;
    segment.mesh.scale.y = Math.max(progress, 0.001);
    segment.mesh.position.copy(segment.start).addScaledVector(segment.direction, segment.length * progress * 0.5);
  });

  veinSegments.forEach((segment) => {
    const progress = smoothstep(remap(current.tree, segment.growStart, segment.growEnd));
    const positions = segment.positionAttribute.array;
    positions[3] = segment.start.x + segment.direction.x * segment.length * progress;
    positions[4] = segment.start.y + segment.direction.y * segment.length * progress;
    positions[5] = segment.start.z + segment.direction.z * segment.length * progress;
    segment.positionAttribute.needsUpdate = true;
    segment.line.visible = progress > 0.01;
  });

  veinMaterial.opacity = current.tree * (0.18 + Math.sin(elapsed * 2.4) * 0.05);

  leaves.forEach((leaf) => {
    const progress = smoothstep(remap(current.tree, leaf.growAt, leaf.growAt + 0.14));
    const pulse = 1 + Math.sin(elapsed * 1.4 + leaf.phase) * 0.035 * current.tree;
    leaf.mesh.visible = progress > 0.002;
    leaf.mesh.scale.set(
      leaf.baseScale.x * progress * pulse,
      leaf.baseScale.y * progress * pulse,
      leaf.baseScale.z * progress * pulse,
    );
  });

  agentNodes.forEach((node, index) => {
    const enabled = current.agents > index + 0.25;
    const scale = enabled ? 0.78 + Math.sin(elapsed * 3.2 + index) * 0.18 : 0;
    node.visible = current.tree > node.userData.growAt;
    node.scale.setScalar(Math.max(0, scale * current.tree));
    node.material.opacity = enabled ? 0.78 : 0;
  });

  treeGroup.rotation.z = reducedMotion ? 0 : Math.sin(elapsed * 0.72) * (0.004 + current.weather * 0.009);
}

function updateRootnote(elapsed) {
  const frames = frameSets[activeFrameSet];
  if (elapsed < nextFrameAt) return;
  rootnote.src = frames[frameIndex % frames.length];
  frameIndex += 1;
  const cadence = {
    idle: 0.36,
    running: 0.23,
    waiting: 0.32,
    failed: 0.22,
    review: 0.29,
  };
  nextFrameAt = elapsed + (reducedMotion ? 0.7 : cadence[activeFrameSet]);
}

function updateField(elapsed) {
  field.arcs.forEach((arc, index) => {
    arc.material.opacity = current.field * (0.12 - index * 0.025) * (0.82 + Math.sin(elapsed * 1.9 + index) * 0.18);
    const scale = 0.94 + current.field * 0.07 + Math.sin(elapsed * 1.2 + index) * 0.008;
    arc.scale.setScalar(scale);
  });

  field.ground.material.opacity = current.tree * 0.12 + current.field * 0.13;
  field.ground.rotation.z = elapsed * 0.035;

  const shockAge = elapsed - shockStartedAt;
  if (shockAge >= 0 && shockAge < 4) {
    const progress = shockAge / 4;
    field.shock.visible = true;
    field.shock.scale.setScalar(0.45 + progress * 1.3);
    field.shock.material.opacity = Math.sin(progress * Math.PI) * 0.38;
  } else {
    field.shock.visible = false;
  }
}

function updateWeather(delta, elapsed) {
  weather.material.opacity = current.weather * 0.46;
  const positions = weather.positionAttribute.array;
  weather.drops.forEach((drop, index) => {
    drop.y -= drop.speed * delta * (0.7 + current.weather * 0.8);
    drop.x -= delta * (0.35 + current.weather * 0.55);
    if (drop.y < -4.7 || drop.x < -7.2) {
      drop.y = 4.8 + random() * 1.2;
      drop.x = -6.5 + random() * 13;
    }

    const fieldCenterX = fieldAnchorX;
    const fieldCenterY = -1.55;
    const distanceX = drop.x - fieldCenterX;
    const distanceY = drop.y - fieldCenterY;
    const nearField = Math.max(0, 1 - Math.hypot(distanceX / 2.45, distanceY / 3.2));
    const shield = nearField * current.field;
    const deflection = Math.sign(distanceX || 1) * shield * 1.28;
    const base = index * 6;
    positions[base] = drop.x + deflection;
    positions[base + 1] = drop.y;
    positions[base + 2] = drop.z;
    positions[base + 3] = drop.x + 0.16 + deflection * 1.7;
    positions[base + 4] = drop.y - drop.length;
    positions[base + 5] = drop.z;
  });
  weather.positionAttribute.needsUpdate = true;
  weather.lines.rotation.z = Math.sin(elapsed * 0.22) * 0.012 * current.weather;
}

function updateExploration(delta, elapsed) {
  exploration.paths.forEach((path, index) => {
    const reveal = smoothstep(THREE.MathUtils.clamp(current.paths * 1.24 - index * 0.055, 0, 1));
    path.line.geometry.setDrawRange(0, Math.max(1, Math.floor(path.pointCount * reveal)));
    path.line.material.opacity = current.paths * (0.2 + Math.sin(elapsed * 1.25 + index) * 0.035);
    path.source.material.opacity = current.paths * 0.58;
    path.source.scale.setScalar(0.72 + current.paths * 0.28 + Math.sin(elapsed * 1.7 + index) * 0.08);
    path.pulse.visible = current.paths > 0.04;
    path.pulse.material.opacity = current.paths * 0.84;
    path.pulse.position.copy(path.curve.getPoint((elapsed * path.speed + path.phase) % 0.94));
  });

  exploration.mist.material.opacity = current.mist * 0.22;
  const positions = exploration.mist.positionAttribute.array;
  exploration.mist.segments.forEach((segment, index) => {
    segment.x += segment.speed * delta;
    if (segment.x > 7.4) segment.x = -7.4 - segment.length;
    const driftY = Math.sin(elapsed * 0.34 + segment.phase) * 0.055;
    const offset = index * 6;
    positions[offset] = segment.x;
    positions[offset + 1] = segment.y + driftY;
    positions[offset + 2] = segment.z;
    positions[offset + 3] = segment.x + segment.length;
    positions[offset + 4] = segment.y + driftY;
    positions[offset + 5] = segment.z;
  });
  exploration.mist.positionAttribute.needsUpdate = true;
}

function updateAmbient(elapsed) {
  if (reducedMotion) return;
  ambient.points.rotation.z = Math.sin(elapsed * 0.08) * 0.018;
  ambient.points.position.x = Math.sin(elapsed * 0.13) * 0.05;
  ambient.points.position.y = Math.sin(elapsed * 0.17) * 0.035;
}

function buildExploration() {
  const destination = new THREE.Vector3(2.45, -1.36, 1.7);
  const pathSpecs = [
    { start: [-6.1, 2.7], controlA: [-3.9, 3.0], controlB: [-0.2, 0.7], color: 0x6faad1 },
    { start: [-5.8, 0.72], controlA: [-3.8, 0.2], controlB: [-0.4, -0.3], color: 0xd0a652 },
    { start: [-5.2, -2.65], controlA: [-3.2, -2.1], controlB: [-0.5, -1.5], color: 0x79b997 },
    { start: [-1.7, 3.75], controlA: [-0.7, 2.8], controlB: [1.2, 0.4], color: 0xb8c3b9 },
    { start: [1.0, 3.95], controlA: [1.2, 2.35], controlB: [2.0, 0.45], color: 0x8cae7e },
  ];
  const paths = pathSpecs.map((spec, index) => {
    const start = new THREE.Vector3(spec.start[0], spec.start[1], 1.7);
    const curve = new THREE.CubicBezierCurve3(
      start,
      new THREE.Vector3(spec.controlA[0], spec.controlA[1], 1.7),
      new THREE.Vector3(spec.controlB[0], spec.controlB[1], 1.7),
      destination.clone().add(new THREE.Vector3(0, (index - 2) * 0.08, 0)),
    );
    const points = curve.getPoints(72);
    const geometry = new THREE.BufferGeometry().setFromPoints(points);
    geometry.setDrawRange(0, 1);
    const material = new THREE.LineBasicMaterial({
      color: spec.color,
      transparent: true,
      opacity: 0,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
    });
    const line = new THREE.Line(geometry, material);
    scene.add(line);

    const sourceMaterial = new THREE.MeshBasicMaterial({
      color: spec.color,
      transparent: true,
      opacity: 0,
      depthWrite: false,
    });
    const source = new THREE.Mesh(new THREE.RingGeometry(0.07, 0.105, 18), sourceMaterial);
    source.position.copy(start);
    scene.add(source);

    const pulseMaterial = new THREE.MeshBasicMaterial({
      color: spec.color,
      transparent: true,
      opacity: 0,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
    });
    const pulse = new THREE.Mesh(new THREE.CircleGeometry(0.045, 14), pulseMaterial);
    pulse.visible = false;
    scene.add(pulse);
    return {
      curve,
      line,
      source,
      pulse,
      pointCount: points.length,
      speed: 0.055 + index * 0.007,
      phase: index * 0.17,
    };
  });

  const segments = [];
  const positions = new Float32Array(52 * 6);
  for (let index = 0; index < 52; index += 1) {
    segments.push({
      x: -7.4 + random() * 14.8,
      y: -3.7 + random() * 7.5,
      z: 0.8 + random() * 0.7,
      length: 0.28 + random() * 0.88,
      speed: 0.08 + random() * 0.16,
      phase: random() * Math.PI * 2,
    });
  }
  const mistGeometry = new THREE.BufferGeometry();
  const positionAttribute = new THREE.BufferAttribute(positions, 3);
  mistGeometry.setAttribute("position", positionAttribute);
  const mistMaterial = new THREE.LineBasicMaterial({
    color: 0xb8c5c6,
    transparent: true,
    opacity: 0,
    depthWrite: false,
  });
  const mistLines = new THREE.LineSegments(mistGeometry, mistMaterial);
  scene.add(mistLines);

  return {
    destination,
    paths,
    mist: { segments, lines: mistLines, material: mistMaterial, positionAttribute },
  };
}

async function prepareYoungTree() {
  const source = new Image();
  source.src = assetUrl("agents-tree-young-source.png");
  try {
    await source.decode();
    youngTreeCanvas.width = source.naturalWidth;
    youngTreeCanvas.height = source.naturalHeight;
    const context = youngTreeCanvas.getContext("2d", { willReadFrequently: true });
    context.drawImage(source, 0, 0);
    const imageData = context.getImageData(0, 0, source.naturalWidth, source.naturalHeight);
    const pixels = imageData.data;
    for (let index = 0; index < pixels.length; index += 4) {
      const red = pixels[index];
      const green = pixels[index + 1];
      const blue = pixels[index + 2];
      const minimum = Math.min(red, green, blue);
      const maximum = Math.max(red, green, blue);
      const spread = maximum - minimum;
      if (minimum > 208 && spread < 9) {
        pixels[index + 3] = 0;
      } else if (minimum > 192 && spread < 24) {
        pixels[index + 3] = Math.round(pixels[index + 3] * (spread / 24));
      }
    }
    context.putImageData(imageData, 0, 0);
    youngTreeCanvas.dataset.ready = "true";
  } catch {
    youngTreeCanvas.dataset.ready = "false";
  }
}

function buildTree() {
  const trunkPoints = [new THREE.Vector3(0, 0, 0)];
  for (let index = 1; index <= 9; index += 1) {
    trunkPoints.push(
      new THREE.Vector3(
        Math.sin(index * 0.76) * 0.14 + index * 0.035,
        index * 0.63,
        Math.sin(index * 0.51) * 0.08,
      ),
    );
  }

  for (let index = 0; index < trunkPoints.length - 1; index += 1) {
    addSegment(
      trunkPoints[index],
      trunkPoints[index + 1],
      0.34 - index * 0.025,
      0.31 - index * 0.025,
      index * 0.055,
      index * 0.055 + 0.14,
      false,
    );
  }

  const branchSpecs = [
    { index: 3, side: -1, angle: 0.88, length: 2.45 },
    { index: 4, side: 1, angle: 0.72, length: 3.25 },
    { index: 5, side: -1, angle: 0.68, length: 3.15 },
    { index: 6, side: 1, angle: 0.53, length: 3.0 },
    { index: 7, side: -1, angle: 0.48, length: 2.7 },
    { index: 7, side: 1, angle: 0.42, length: 3.35 },
    { index: 8, side: -1, angle: 0.34, length: 2.45 },
    { index: 8, side: 1, angle: 0.28, length: 2.55 },
  ];

  branchSpecs.forEach((spec, index) => {
    const direction = new THREE.Vector3(
      spec.side * Math.cos(spec.angle),
      Math.sin(spec.angle),
      (random() - 0.5) * 0.28,
    ).normalize();
    growBranch(trunkPoints[spec.index], direction, spec.length, 0.18 - index * 0.008, 0, 0.24 + index * 0.035);
  });

  const crownStart = trunkPoints.at(-1);
  [-0.62, -0.24, 0.2, 0.56].forEach((xDirection, index) => {
    const direction = new THREE.Vector3(xDirection, 0.88, (random() - 0.5) * 0.2).normalize();
    growBranch(crownStart, direction, 2.0 + random() * 0.7, 0.12, 0, 0.42 + index * 0.025);
  });

  const rootDirections = [-2.75, -2.28, -1.82, -1.28, -0.62, -0.18];
  rootDirections.forEach((angle, index) => {
    const start = new THREE.Vector3(0, 0.02, -0.05);
    const end = new THREE.Vector3(Math.cos(angle) * (1.75 + random()), Math.sin(angle) * 0.42, -0.12 + random() * 0.2);
    addSegment(start, end, 0.15, 0.028, 0.04 + index * 0.018, 0.2 + index * 0.018, true);
  });

  const nodeGeometry = new THREE.SphereGeometry(0.085, 10, 8);
  const nodePositions = [
    [-2.35, 3.7, 0.16],
    [2.5, 3.22, 0.08],
    [-1.8, 5.1, 0.04],
    [1.88, 4.85, 0.12],
    [0.52, 5.72, 0.18],
    [3.05, 4.2, -0.02],
  ];
  nodePositions.forEach((position, index) => {
    const material = new THREE.MeshBasicMaterial({
      color: index % 2 ? 0x75aee6 : 0x62e0c8,
      transparent: true,
      opacity: 0,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
    });
    const node = new THREE.Mesh(nodeGeometry, material);
    node.position.set(...position);
    node.userData.growAt = 0.48 + index * 0.045;
    treeGroup.add(node);
    agentNodes.push(node);
  });
}

function growBranch(start, initialDirection, length, radius, depth, growStart) {
  const parts = depth === 0 ? 5 : 4;
  let point = start.clone();
  let direction = initialDirection.clone();
  for (let index = 0; index < parts; index += 1) {
    const bend = (random() - 0.5) * (depth === 0 ? 0.16 : 0.26);
    direction.applyAxisAngle(zAxis, bend).normalize();
    direction.y = Math.max(direction.y, 0.2 + depth * 0.05);
    direction.normalize();
    const segmentLength = (length / parts) * (0.88 + random() * 0.2);
    const next = point.clone().addScaledVector(direction, segmentLength);
    const localStart = growStart + index * 0.055 + depth * 0.025;
    addSegment(
      point,
      next,
      radius * (1 - index / (parts + 1)),
      radius * (1 - (index + 0.8) / (parts + 1)),
      localStart,
      localStart + 0.13,
      false,
    );

    if (depth < 2 && index >= 2) {
      const childSide = index % 2 === 0 ? -1 : 1;
      const childDirection = direction.clone().applyAxisAngle(zAxis, childSide * (0.48 + random() * 0.28));
      growBranch(next, childDirection, length * (0.44 - depth * 0.07), radius * 0.56, depth + 1, localStart + 0.09);
    }
    point = next;
  }
  addLeafCluster(point, depth === 0 ? 0.68 : 0.48, depth === 0 ? 16 : 10, growStart + 0.34 + depth * 0.05);
}

function addSegment(start, end, startRadius, endRadius, growStart, growEnd, isRoot) {
  const direction = end.clone().sub(start);
  const length = direction.length();
  direction.normalize();
  const geometry = new THREE.CylinderGeometry(
    Math.max(endRadius, 0.012),
    Math.max(startRadius, 0.016),
    length,
    isRoot ? 7 : 9,
    1,
    false,
  );
  const mesh = new THREE.Mesh(geometry, isRoot ? rootMaterial : barkMaterial);
  mesh.quaternion.setFromUnitVectors(unitY, direction);
  mesh.position.copy(start);
  mesh.scale.y = 0.001;
  mesh.visible = false;
  treeGroup.add(mesh);
  branchSegments.push({ mesh, start: start.clone(), direction, length, growStart, growEnd });

  if (!isRoot && startRadius > 0.045) {
    const lineGeometry = new THREE.BufferGeometry();
    const positionAttribute = new THREE.BufferAttribute(
      new Float32Array([start.x, start.y, start.z + startRadius * 0.72, start.x, start.y, start.z + startRadius * 0.72]),
      3,
    );
    lineGeometry.setAttribute("position", positionAttribute);
    const line = new THREE.Line(lineGeometry, veinMaterial);
    treeGroup.add(line);
    veinSegments.push({ line, positionAttribute, start: start.clone(), direction, length, growStart, growEnd });
  }
}

function addLeafCluster(center, spread, count, growAt) {
  const geometry = new THREE.SphereGeometry(0.12, 6, 4);
  for (let index = 0; index < count; index += 1) {
    const mesh = new THREE.Mesh(geometry, leafMaterials[Math.floor(random() * leafMaterials.length)]);
    mesh.position.set(
      center.x + (random() - 0.5) * spread * 2,
      center.y + (random() - 0.45) * spread * 1.15,
      center.z + (random() - 0.5) * 0.72,
    );
    mesh.rotation.set((random() - 0.5) * 0.4, (random() - 0.5) * 0.8, random() * Math.PI);
    const baseScale = new THREE.Vector3(1.4 + random() * 0.8, 0.48 + random() * 0.26, 0.58 + random() * 0.32);
    mesh.scale.setScalar(0.001);
    mesh.visible = false;
    treeGroup.add(mesh);
    leaves.push({ mesh, baseScale, growAt: growAt + random() * 0.12, phase: random() * Math.PI * 2 });
  }
}

function buildField() {
  const arcs = [
    makeArc(1.7, -2.35, 6.6, 5.35, 0x5ed8c5),
    makeArc(1.7, -2.35, 7.05, 5.7, 0x5aa7dc),
    makeArc(1.7, -2.35, 7.5, 6.05, 0x8fcf86),
  ];
  arcs.forEach((arc, index) => {
    arc.position.z = 1.2 - index * 0.08;
    scene.add(arc);
  });

  const ground = makeEllipse(1.7, -4.08, 5.4, 0.62, 0x5ed8c5, 112);
  ground.material.opacity = 0;
  ground.position.z = 0.5;
  scene.add(ground);

  const shock = makeEllipse(1.7, -3.96, 4.4, 0.68, 0xa9f0d9, 112);
  shock.material.opacity = 0;
  shock.position.z = 2.4;
  shock.visible = false;
  scene.add(shock);

  return { arcs, ground, shock };
}

function makeArc(centerX, centerY, radiusX, radiusY, color) {
  const points = [];
  for (let index = 0; index <= 96; index += 1) {
    const angle = (index / 96) * Math.PI;
    points.push(new THREE.Vector3(centerX + Math.cos(angle) * radiusX, centerY + Math.sin(angle) * radiusY, 0));
  }
  const geometry = new THREE.BufferGeometry().setFromPoints(points);
  const material = new THREE.LineBasicMaterial({
    color,
    transparent: true,
    opacity: 0,
    blending: THREE.AdditiveBlending,
    depthWrite: false,
  });
  return new THREE.Line(geometry, material);
}

function makeEllipse(centerX, centerY, radiusX, radiusY, color, segments) {
  const points = [];
  for (let index = 0; index < segments; index += 1) {
    const angle = (index / segments) * Math.PI * 2;
    points.push(new THREE.Vector3(centerX + Math.cos(angle) * radiusX, centerY + Math.sin(angle) * radiusY, 0));
  }
  const geometry = new THREE.BufferGeometry().setFromPoints(points);
  const material = new THREE.LineBasicMaterial({
    color,
    transparent: true,
    opacity: 0,
    blending: THREE.AdditiveBlending,
    depthWrite: false,
  });
  return new THREE.LineLoop(geometry, material);
}

function buildWeather() {
  const drops = [];
  const positions = new Float32Array(260 * 6);
  for (let index = 0; index < 260; index += 1) {
    drops.push({
      x: -6.5 + random() * 13,
      y: -4.2 + random() * 9.2,
      z: 2.6 + random() * 0.8,
      length: 0.16 + random() * 0.28,
      speed: 2.6 + random() * 2.8,
    });
  }
  const geometry = new THREE.BufferGeometry();
  const positionAttribute = new THREE.BufferAttribute(positions, 3);
  geometry.setAttribute("position", positionAttribute);
  const material = new THREE.LineBasicMaterial({
    color: 0xb9d6dc,
    transparent: true,
    opacity: 0,
    blending: THREE.AdditiveBlending,
    depthWrite: false,
  });
  const lines = new THREE.LineSegments(geometry, material);
  scene.add(lines);
  return { drops, lines, material, positionAttribute };
}

function buildAmbientParticles() {
  const count = 110;
  const positions = new Float32Array(count * 3);
  for (let index = 0; index < count; index += 1) {
    positions[index * 3] = -6 + random() * 12;
    positions[index * 3 + 1] = -3.8 + random() * 7.8;
    positions[index * 3 + 2] = -1 + random() * 2;
  }
  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute("position", new THREE.BufferAttribute(positions, 3));
  const material = new THREE.PointsMaterial({
    color: 0xbfc8ab,
    size: 0.025,
    transparent: true,
    opacity: 0.14,
    depthWrite: false,
  });
  const points = new THREE.Points(geometry, material);
  scene.add(points);
  return { points, material };
}

function resize() {
  const width = Math.max(app.clientWidth, 1);
  const height = Math.max(app.clientHeight, 1);
  renderer.setSize(width, height, false);
  const vertical = 4.5;
  const aspect = width / height;
  camera.left = -vertical * aspect;
  camera.right = vertical * aspect;
  camera.top = vertical;
  camera.bottom = -vertical;
  camera.updateProjectionMatrix();
  updateAnchorLayout();
}

function updateAnchorLayout() {
  if (!exploration || !field) return;
  const treeSize = treeBillboard.offsetWidth || Math.min(innerHeight * 0.58, innerWidth * 0.36);
  const youngTreeSize = youngTreeBillboard.offsetWidth || Math.min(innerHeight * 0.36, innerWidth * 0.26);
  const treeLeft = THREE.MathUtils.clamp(
    treeAnchorX * innerWidth - treeSize * 0.69,
    18,
    innerWidth - treeSize - 18,
  );
  const youngTreeLeft = THREE.MathUtils.clamp(
    treeAnchorX * innerWidth - youngTreeSize * 0.68,
    18,
    innerWidth - youngTreeSize - 18,
  );
  app.style.setProperty("--tree-left", `${treeLeft.toFixed(2)}px`);
  app.style.setProperty("--young-tree-left", `${youngTreeLeft.toFixed(2)}px`);

  const worldX = THREE.MathUtils.lerp(camera.left, camera.right, petAnchor.x);
  const worldY = THREE.MathUtils.lerp(camera.top, camera.bottom, petAnchor.y);
  exploration.destination.set(worldX, worldY, 1.7);
  exploration.paths.forEach((path, index) => {
    path.curve.v2.set(worldX - 1.1, worldY + 0.52 + (index - 2) * 0.07, 1.7);
    path.curve.v3.copy(exploration.destination).add(new THREE.Vector3(0, (index - 2) * 0.035, 0));
    const points = path.curve.getPoints(path.pointCount - 1);
    const positions = path.line.geometry.getAttribute("position");
    points.forEach((point, pointIndex) => point.toArray(positions.array, pointIndex * 3));
    positions.needsUpdate = true;
    path.line.geometry.computeBoundingSphere();
  });

  const targetFieldX = worldX - 0.6;
  const fieldShift = targetFieldX - 1.7;
  field.arcs.forEach((arc) => { arc.position.x = fieldShift; });
  field.ground.position.x = fieldShift;
  field.shock.position.x = fieldShift;
  fieldAnchorX = targetFieldX;
}

function remap(value, start, end) {
  return THREE.MathUtils.clamp((value - start) / Math.max(end - start, 0.0001), 0, 1);
}

function smoothstep(value) {
  return value * value * (3 - 2 * value);
}

function damp(value, target, speed, delta) {
  return THREE.MathUtils.damp(value, target, speed, delta);
}

function mulberry32(seed) {
  return function next() {
    let value = (seed += 0x6d2b79f5);
    value = Math.imul(value ^ (value >>> 15), value | 1);
    value ^= value + Math.imul(value ^ (value >>> 7), value | 61);
    return ((value ^ (value >>> 14)) >>> 0) / 4294967296;
  };
}
