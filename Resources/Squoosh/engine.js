// Hosts a pool of workers that run Squoosh's WebAssembly codecs.
// The native app talks to this page through `window.chipngReady()` and
// `window.chipngRun(...)`, passing image data as base64 strings.

const workerCount = Math.max(1, Math.min(6, (navigator.hardwareConcurrency || 4) - 1));

const wasmBinaries = Promise.all([
  fetch("codecs/oxipng/squoosh_oxipng_bg.wasm").then((r) => r.arrayBuffer()),
  fetch("codecs/imagequant/imagequant.wasm").then((r) => r.arrayBuffer()),
]);

const workers = [];
const queue = [];
const pending = new Map();
let nextJobId = 1;

function pump() {
  for (const slot of workers) {
    if (slot.busy || queue.length === 0) continue;
    const job = queue.shift();
    slot.busy = true;
    pending.set(job.id, { ...job, slot });
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

const ready = (async () => {
  const [oxipngWasm, imagequantWasm] = await wasmBinaries;
  await Promise.all(
    Array.from({ length: workerCount }, () => {
      const worker = new Worker("worker.js", { type: "module" });
      const slot = { worker, busy: false };
      return new Promise((resolve, reject) => {
        worker.onerror = (e) => reject(new Error(e.message || "Worker failed to start"));
        worker.onmessage = (e) => {
          if (e.data.ok) {
            worker.onmessage = (msg) => onWorkerMessage(slot, msg);
            workers.push(slot);
            resolve();
          } else {
            reject(new Error(e.data.error));
          }
        };
        worker.postMessage({ op: "init", oxipngWasm, imagequantWasm });
      });
    })
  );
  return workerCount;
})();

window.chipngReady = () => ready;

window.chipngRun = async (op, input, width, height, options) => {
  await ready;
  return new Promise((resolve, reject) => {
    const id = nextJobId++;
    queue.push({ id, resolve, reject, message: { id, op, input, width, height, options } });
    pump();
  });
};
