// Sync is asynchronous (stream + Automerge message round trips), so tests
// poll for the expected state instead of guessing a fixed delay.
export async function waitFor(predicate, { timeout = 3000, interval = 20 } = {}) {
  const deadline = Date.now() + timeout;
  for (;;) {
    if (await predicate()) return;
    if (Date.now() > deadline) throw new Error('waitFor: timed out waiting for condition');
    await new Promise((resolve) => setTimeout(resolve, interval));
  }
}
