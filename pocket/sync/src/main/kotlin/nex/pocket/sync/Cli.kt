package nex.pocket.sync

/**
 * CLI wrapper around [OfflineQueue] so pocket/scripts/pocket-demo.sh can
 * drive the real Kotlin queue from a shell script without needing a
 * JVM<->shell binding library — this is the same "small CLI as the
 * integration seam" pattern used throughout this repo (hub/agent/agent.py,
 * hub/dreaming/consolidate.py).
 *
 * Usage:
 *   cli enqueue <dbPath> <question> <answer> <model> [tsMs]
 *   cli pending <dbPath>
 *   cli mark-synced <dbPath> <id...>
 */
fun main(args: Array<String>) {
    if (args.isEmpty()) {
        System.err.println("usage: enqueue|pending|mark-synced <dbPath> ...")
        kotlin.system.exitProcess(2)
    }

    when (args[0]) {
        "enqueue" -> {
            val (dbPath, question, answer, model) = args.drop(1)
            val tsMs = args.getOrNull(5)?.toLong() ?: System.currentTimeMillis()
            OfflineQueue(dbPath).use { q ->
                val id = q.enqueue(question, answer, model, tsMs)
                println(id)
            }
        }
        "pending" -> {
            val dbPath = args[1]
            OfflineQueue(dbPath).use { q ->
                for (row in q.pending()) {
                    // Simple pipe-delimited output — no JSON dependency
                    // needed for a handful of fields the demo script parses.
                    println("${row.id}|${row.tsMs}|${row.question}|${row.answer}|${row.model}")
                }
            }
        }
        "mark-synced" -> {
            val dbPath = args[1]
            val ids = args.drop(2).map { it.toLong() }
            OfflineQueue(dbPath).use { q -> q.markSynced(ids) }
        }
        else -> {
            System.err.println("unknown command: ${args[0]}")
            kotlin.system.exitProcess(2)
        }
    }
}
