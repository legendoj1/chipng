// Hosts a pool of workers that run Squoosh's WebAssembly codecs.
//
// macOS (WKWebView) calls `window.chipngReady()` / `window.chipngRun(...)`.
// Windows (WebView2) sends {id, op, ...} messages through `chrome.webview` and
// gets {id, ok, data | error} back. Image data travels as base64 strings.

const workerCount = Math.max(1, Math.min(6, (navigator.hardwareConcurrency || 4) - 1));

const wasmBinaries = Promise.all([
  fetch("codecs/oxipng/squoosh_oxipng_bg.wasm").then((r) => r.arrayBuffer()),
  fetch("codecs/imagequant/imagequant.wasm").then((r) => r.arrayBuffer()),
]);

const workers = [];
const queue = [];
const pending = new Map();
let nextJobId = 1;
let inlineCodec = null;

function pump() {
  for (const slot of workers) {
    if (slot.busy || queue.length === 0) continue;
    const job = queue.shift();
    slot.busy = true;
    pending.set(job.id, job);
    slot.worker.postMessage(job.message);
  }
}

function onWorkerMessage(slot, e) {
  const { id, ok, data, error } = e.data;
  const job = pending.get(id);
  if (!job) return;
  pending.delete(id);
  slot.busy = false;
  if (ok) job.resolve(data);
  else job.reject(new Error(error));
  pump();
}

function startWorker(oxipngWasm, imagequantWasm) {
  const worker = new Worker("worker.js", { type: "module" });
  const slot = { worker, busy: false };
  return new Promise((resolve, reject) => {
    worker.onerror = (e) => reject(new Error(e.message || "Worker failed to start"));
    worker.onmessage = (e) => {
      if (e.data.ok) {
        worker.onmessage = (msg) => onWorkerMessage(slot, msg);
        resolve(slot);
      } else {
        reject(new Error(e.data.error));
      }
    };
    worker.postMessage({ op: "init", oxipngWasm, imagequantWasm });
  });
}

const ready = (async () => {
  const [oxipngWasm, imagequantWasm] = await wasmBinaries;
  const forceInline = new URLSearchParams(location.search).has("inline");
  if (!forceInline) {
    try {
      workers.push(...(await Promise.all(Array.from({ length: workerCount }, () => startWorker(oxipngWasm, imagequantWasm)))));
      return workers.length;
    } catch (err) {
      console.warn("Chipng: workers unavailable, running codecs on the page", err);
      workers.forEach((slot) => slot.worker.terminate());
      workers.length = 0;
    }
  }
  inlineCodec = await import("./codec.js");
  await inlineCodec.init(oxipngWasm, imagequantWasm);
  return 0;
})();

let inlineChain = Promise.resolve();

function runJob(message) {
  if (inlineCodec) {
    // One job at a time on the page itself.
    const result = inlineChain.then(() => inlineCodec.run(message));
    inlineChain = result.catch(() => {});
    return result;
  }
  return new Promise((resolve, reject) => {
    const id = nextJobId++;
    queue.push({ id, resolve, reject, message: { ...message, id } });
    pump();
  });
}

window.chipngReady = () => ready;

window.chipngRun = async (op, input, width, height, options) => {
  await ready;
  return runJob({ op, input, width, height, options });
};

// WebView2 bridge (Windows).
if (window.chrome && window.chrome.webview) {
  window.chrome.webview.addEventListener("message", async (e) => {
    const { id, op, input, width, height, options } = e.data;
    try {
      const data = op === "ready" ? String(await ready) : await window.chipngRun(op, input, width, height, options);
      window.chrome.webview.postMessage({ id, ok: true, data });
    } catch (err) {
      window.chrome.webview.postMessage({ id, ok: false, error: String((err && err.message) || err) });
    }
  });
}
