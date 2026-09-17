package nex.pocket.sync

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.nio.file.Files

class OfflineQueueTest {

    private fun tempDbPath(): String =
        Files.createTempFile("nex-pocket-queue-test", ".db").toString()

    @Test
    fun `enqueue then pending returns rows in insertion order`() {
        OfflineQueue(tempDbPath()).use { q ->
            q.enqueue("first?", "answer1", "m")
            q.enqueue("second?", "answer2", "m")
            q.enqueue("third?", "answer3", "m")

            val pending = q.pending()
            assertEquals(3, pending.size)
            assertEquals(listOf("first?", "second?", "third?"), pending.map { it.question })
            assertTrue(pending.all { !it.synced })
        }
    }

    @Test
    fun `marking synced removes rows from pending but not from the table`() {
        OfflineQueue(tempDbPath()).use { q ->
            val id1 = q.enqueue("q1", "a1", "m")
            val id2 = q.enqueue("q2", "a2", "m")
            q.enqueue("q3", "a3", "m")

            q.markSynced(listOf(id1, id2))

            val pending = q.pending()
            assertEquals(1, pending.size)
            assertEquals("q3", pending[0].question)
        }
    }

    @Test
    fun `queue survives being reopened against the same db file`() {
        val path = tempDbPath()
        OfflineQueue(path).use { q -> q.enqueue("persisted?", "yes", "m") }

        OfflineQueue(path).use { q ->
            val pending = q.pending()
            assertEquals(1, pending.size)
            assertEquals("persisted?", pending[0].question)
        }
    }

    @Test
    fun `mark synced with empty list is a no-op`() {
        OfflineQueue(tempDbPath()).use { q ->
            q.enqueue("q1", "a1", "m")
            q.markSynced(emptyList())
            assertEquals(1, q.pending().size)
        }
    }
}
