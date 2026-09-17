package com.nex.pocket

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import nex.pocket.sync.OfflineQueue

/**
 * The pocket app shell (CLAUDE.md Phase 4). Text Q&A only in v0 — voice
 * input (Faster-Whisper, streamed to the hub when connected) is a named
 * Phase 4 bring-up item this session didn't implement; pocket/README.md
 * says so rather than pretending a microphone button here would do
 * anything real.
 *
 * The modem kill-switch state is rendered unconditionally, at the same
 * level as the question box — not buried in a settings menu — per the
 * plan's explicit "first-class UI element, not an afterthought."
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Real device path: /data/data/com.nex.pocket/files/pocket-queue.db
        val queue = OfflineQueue(filesDir.resolve("pocket-queue.db").absolutePath)
        val viewModel = PocketViewModel(queue, UnavailableModemKillSwitchReader())

        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    PocketScreen(viewModel)
                }
            }
        }
    }
}

@Composable
fun PocketScreen(viewModel: PocketViewModel) {
    var question by remember { mutableStateOf("") }
    val killSwitchState by viewModel.killSwitchState
    val history by viewModel.history

    Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Modem: ${killSwitchState.name}")

        TextField(value = question, onValueChange = { question = it }, label = { Text("Ask NEx") })

        Button(onClick = {
            // TODO: real on-device inference (llama.cpp JNI) belongs
            // here. This UI layer is the reviewable draft; see
            // PocketViewModel's doc comment for exactly what's real
            // versus stubbed.
            viewModel.ask(question, answerFromLocalModel = "(offline model wiring not built in this session)", model = "unbuilt")
            question = ""
        }) {
            Text("Ask")
        }

        Text("Queued interactions: ${history.size}")
    }
}
