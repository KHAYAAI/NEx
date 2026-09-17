package nex.pocket.sync

import java.sql.Connection
import java.sql.DriverManager

/**
 * The pocket node's store-and-forward queue (CLAUDE.md Phase 4):
 * "interactions while offline get logged locally and merged into the
 * shared event log via the CRDT sync layer on reconnect."
 *
 * This class owns exactly the "logged locally" half — durable,
 * ordered, SQLite-backed, real (this file builds and is unit-tested on
 * the plain JVM, no Android SDK needed; see pocket/README.md for why
 * that matters in this environment). The "merged... via the CRDT sync
 * layer" half is deliberately NOT implemented here: a real product
 * would give this module a JNI binding into automerge-rs so the merge
 * happens on-device, but building that binding is its own real
 * project, not something to fake with a thin wrapper. Until it exists,
 * [pending] hands queued rows to an external process that performs the
 * actual Automerge merge — see pocket/scripts/pocket-demo.sh, which
 * uses the already-proven sync-protocol/ (Phase 1) Node.js Peer for
 * exactly that, and pocket/README.md, which says so plainly.
 */
class OfflineQueue(dbPath: String) : AutoCloseable {
    private val conn: Connection = DriverManager.getConnection("jdbc:sqlite:$dbPath")

    init {
        conn.createStatement().execute(
            """
            CREATE TABLE IF NOT EXISTS queued_interactions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts_ms INTEGER NOT NULL,
                question TEXT NOT NULL,
                answer TEXT NOT NULL,
                model TEXT NOT NULL,
                synced INTEGER NOT NULL DEFAULT 0
            )
            """.trimIndent()
        )
    }

    data class QueuedInteraction(
        val id: Long,
        val tsMs: Long,
        val question: String,
        val answer: String,
        val model: String,
        val synced: Boolean,
    )

    /** Logs one interaction locally. Always succeeds — this is the path
     * taken while offline, so it can never depend on connectivity. */
    fun enqueue(question: String, answer: String, model: String, tsMs: Long = System.currentTimeMillis()): Long {
        val stmt = conn.prepareStatement(
            "INSERT INTO queued_interactions (ts_ms, question, answer, model) VALUES (?, ?, ?, ?)",
            arrayOf("id"),
        )
        stmt.setLong(1, tsMs)
        stmt.setString(2, question)
        stmt.setString(3, answer)
        stmt.setString(4, model)
        stmt.executeUpdate()
        val keys = stmt.generatedKeys
        keys.next()
        return keys.getLong(1)
    }

    /** Everything not yet confirmed merged into the shared log, oldest first —
     * order matters, per the Phase 4 exit criteria ("appear correctly ordered"). */
    fun pending(): List<QueuedInteraction> {
        val rs = conn.createStatement().executeQuery(
            "SELECT id, ts_ms, question, answer, model, synced FROM queued_interactions " +
                "WHERE synced = 0 ORDER BY id ASC"
        )
        val out = mutableListOf<QueuedInteraction>()
        while (rs.next()) {
            out.add(
                QueuedInteraction(
                    id = rs.getLong("id"),
                    tsMs = rs.getLong("ts_ms"),
                    question = rs.getString("question"),
                    answer = rs.getString("answer"),
                    model = rs.getString("model"),
                    synced = rs.getInt("synced") != 0,
                )
            )
        }
        return out
    }

    /** Called once the sync layer confirms these rows made it into the
     * shared log — never before, so a crash mid-sync just means retry. */
    fun markSynced(ids: List<Long>) {
        if (ids.isEmpty()) return
        val placeholders = ids.joinToString(",") { "?" }
        val stmt = conn.prepareStatement("UPDATE queued_interactions SET synced = 1 WHERE id IN ($placeholders)")
        ids.forEachIndexed { i, id -> stmt.setLong(i + 1, id) }
        stmt.executeUpdate()
    }

    override fun close() {
        conn.close()
    }
}
