package studio.ivlis.nearclip.core.engine

import studio.ivlis.nearclip.core.model.Clip
import studio.ivlis.nearclip.core.model.Endpoint
import studio.ivlis.nearclip.core.model.MemberRecord
import studio.ivlis.nearclip.core.tailnet.PeerRoute
import studio.ivlis.nearclip.core.tailnet.TailnetStatus

data class TicketInfo(val uri: String, val expiresAt: Long, val hosts: List<String>, val port: Int)

data class PairPromptInfo(val peerId: String, val name: String, val platform: String, val sas: String)

/** A device found with DNS-SD (fed in by the platform layer; the engine itself does not browse). */
data class DiscoveredService(
    val id: String,
    val name: String,
    val platform: String,
    val groupTag: String,
    val pairingMode: Boolean,
    val endpoints: List<Endpoint>,
)

/** Result of a local send. [peers] is the number of member sessions the clip was sent to right away. */
data class SendResult(val clip: Clip?, val peers: Int, val tooLarge: Boolean = false, val paused: Boolean = false)

/**
 * A live image arriving from another device (PROTOCOL §6.6), for progress UI. A transfer ends with the clip's
 * [EngineEvent.ClipAdded] or with [State.FAILED].
 */
data class IncomingTransfer(
    /** Id of the clip being transferred. */
    val id: String,
    /** The device the image was copied on. */
    val from: String,
    val state: State,
    val received: Long,
    /** 0 while the other device is still encoding the image. */
    val total: Long,
    /** [State.FAILED]: cancelled, disconnected, corrupt or timeout. */
    val reason: String? = null,
) {
    enum class State(val wire: String) { PREPARING("preparing"), RECEIVING("receiving"), FAILED("failed") }

    /** 0…1, or null while the size is unknown. */
    val fraction: Float? get() = if (total > 0) minOf(1f, received.toFloat() / total) else null
}

sealed class EngineEvent {
    data class Ready(val port: Int, val groupId: String, val groupTag: String) : EngineEvent()
    data class TicketCreated(val ticket: TicketInfo) : EngineEvent()
    data object TicketExpired : EngineEvent()
    /** Joiner side of code pairing: show this code and wait. */
    data class PairSas(val sas: String, val peerName: String, val peerPlatform: String) : EngineEvent()
    /** Inviter side of code pairing: ask the user. */
    data class PairPrompt(val prompt: PairPromptInfo) : EngineEvent()
    data object PairPromptDismissed : EngineEvent()
    data class Paired(val groupId: String, val peerId: String, val peerName: String, val peerPlatform: String, val joined: Boolean) : EngineEvent()
    data class PairFailed(val reason: String, val peerName: String?) : EngineEvent()
    data class PeerUp(val record: MemberRecord, val route: PeerRoute = PeerRoute.LAN) : EngineEvent()
    data class PeerDown(val id: String) : EngineEvent()
    /**
     * A clip entered the history. [local]: produced on this device. [apply]: a live clip from another device
     * that is newer than anything produced or applied here, so it should go to the system clipboard.
     */
    data class ClipAdded(val clip: Clip, val live: Boolean, val apply: Boolean, val local: Boolean, val sentTo: Int) : EngineEvent()
    /** Progress of a live image from another device (PROTOCOL §6.6). */
    data class Transfer(val transfer: IncomingTransfer) : EngineEvent()
    data class ClipsDeleted(val ids: List<String>) : EngineEvent()
    data class MembersChanged(val members: List<MemberRecord>) : EngineEvent()
    data class Left(val reason: String) : EngineEvent()
    data class TooLarge(val kind: String) : EngineEvent()
    /** The embedded Tailscale node changed state (remote connection). */
    data class TailnetChanged(val status: TailnetStatus) : EngineEvent()
    data class Log(val message: String) : EngineEvent()
}

data class EngineSnapshot(
    val deviceId: String,
    val deviceName: String,
    val platform: String,
    val groupId: String,
    val groupTag: String,
    /** All member records including this device and tombstones, oldest first. */
    val members: List<MemberRecord>,
    val online: Set<String>,
    val lastSeen: Map<String, Long>,
    /** All local clips (every group), newest first. */
    val history: List<Clip>,
    val nearby: List<DiscoveredService>,
    val port: Int,
    val running: Boolean,
    val paused: Boolean,
    val pairingMode: Boolean,
    val ticket: TicketInfo?,
    val prompt: PairPromptInfo?,
    val joining: Boolean,
    val addresses: List<String>,
    /** Route of every connected member. */
    val routes: Map<String, PeerRoute> = emptyMap(),
    val remoteEnabled: Boolean = false,
    val tailnet: TailnetStatus = TailnetStatus.OFF,
) {
    val me: MemberRecord? get() = members.firstOrNull { it.id == deviceId }
    val otherMembers: List<MemberRecord> get() = members.filter { it.id != deviceId && !it.removed }
    val onlineCount: Int get() = otherMembers.count { it.id in online }
}
