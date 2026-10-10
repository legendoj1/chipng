import { init, run } from "./codec.js";

self.onmessage = async (e) => {
  const { id, op } = e.data;
  try {
    if (op === "init") {
      await init(e.data.oxipngWasm, e.data.imagequantWasm);
      self.postMessage({ ok: true });
      return;
    }
    self.postMessage({ id, ok: true, data: run(e.data) });
  } catch (err) {
    self.postMessage({ id, ok: false, error: String((err && err.message) || err) });
  }
};
