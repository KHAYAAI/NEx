package com.nex.pocket

import androidx.compose.runtime.mutableStateOf
import nex.pocket.sync.OfflineQueue

/**
 * Wires the UI to the real store-and-forward queue (pocket/sync/,
 * genuinely built and unit-tested — see its README) and the offline
 * model. Network calls to a real llama-server (offline fallback) and
 * the actual CRDT sync handoff are left as TODOs with pointers to
 * where the real versions live, rather than faked:
 *
 * - Offline answering: pocket/local-model/offline_answer.py implements
 *   this for the demo harness (Python, calling llama-server). A real
 *   Android build would embed llama.cpp via its own JNI bindings
 *   (llama.cpp ships an Android example doing exactly this) rather
 *   than shelling out to Python — that embedding is unbuilt here.
 * - CRDT sync on reconnect: sync-protocol/'s Peer class (Phase 1,
 *   proven) is what actually performs the Automerge merge in
 *   pocket/scripts/pocket-demo.sh. A real Android build needs a JNI
 *   binding to automerge-rs to run that logic on-device; building that
 *   binding is real, separate, unbuilt follow-up work — see
 *   pocket/README.md's "What's not built" section rather than treating
 *   this gap as solved.
 */
class PocketViewModel(
    private val queue: OfflineQueue,
    private val killSwitch: ModemKillSwitchReader,
) {
    val killSwitchState = mutableStateOf(killSwitch.currentState())
    val history = mutableStateOf<List<OfflineQueue.QueuedInteraction>>(queue.pending())

    /** Called when the user asks a question, online or not — the queue
     * doesn't care; it's always written to first. */
    fun ask(question: String, answerFromLocalModel: String, model: String) {
        queue.enqueue(question, answerFromLocalModel, model)
        history.value = queue.pending()
    }

    fun refreshKillSwitchState() {
        killSwitchState.value = killSwitch.currentState()
    }
}
