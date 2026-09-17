package com.nex.pocket

/**
 * The hardware modem kill switch's state, surfaced as a first-class UI
 * element per CLAUDE.md Phase 4 — "not an afterthought." This models
 * the switch's state; it does not (and on real hardware, should not)
 * control the modem itself from software. The point of a *hardware*
 * kill switch is that no software bug, compromised app, or malicious
 * update can override it — this class only reads and displays what the
 * hardware reports.
 *
 * On real hardware this would read a GPIO line or a vendor HAL signal;
 * there is no such hardware in this environment (no phone exists yet —
 * see pocket/README.md), so [KillSwitchState.UNKNOWN] is the only
 * value this class can honestly produce here. The UI (MainActivity)
 * still renders all three states so the design is exercised even
 * though the real signal isn't.
 */
enum class KillSwitchState {
    MODEM_ON,
    MODEM_OFF,
    UNKNOWN,
}

interface ModemKillSwitchReader {
    fun currentState(): KillSwitchState
}

/** Stand-in for the real hardware read, since no such hardware exists
 * in this environment to read from. */
class UnavailableModemKillSwitchReader : ModemKillSwitchReader {
    override fun currentState(): KillSwitchState = KillSwitchState.UNKNOWN
}
