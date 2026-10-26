package studio.ivlis.nearclip.cli

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import studio.ivlis.nearclip.core.engine.EngineConfig
import studio.ivlis.nearclip.core.engine.EngineEvent
import studio.ivlis.nearclip.core.engine.NearclipEngine
import studio.ivlis.nearclip.core.model.Clip
import studio.ivlis.nearclip.core.model.Endpoint
import studio.ivlis.nearclip.core.model.MemberRecord
import studio.ivlis.nearclip.core.model.Platform
import studio.ivlis.nearclip.core.pairing.PairingUri
import studio.ivlis.nearclip.core.proto.Wire
import studio.ivlis.nearclip.core.proto.bool
import studio.ivlis.nearclip.core.proto.int
import studio.ivlis.nearclip.core.proto.str
import studio.ivlis.nearclip.core.store.FileStore
import studio.ivlis.nearclip.core.tailnet.TailnetOptions
import studio.ivlis.nearclip.core.tailnet.TailnetStatus
import java.io.BufferedReader
import java.io.File
import java.io.FileDescriptor
import java.io.FileOutputStream
import java.io.InputStreamReader
import java.io.PrintStream
import kotlin.system.exitProcess

/**
 * Headless Nearclip peer for cross-implementation tests (PROTOCOL.md §9).
 * stdout: one JSON event per line ({"ev": …}); stdin: one JSON command per line ({"cmd": …}); stderr: logs.
 */
private val out = PrintStream(FileOutputStream(FileDescriptor.out), false, "UTF-8")
private val err = PrintStream(FileOutputStream(FileDescriptor.err), true, "UTF-8")

private fun emit(obj: JsonObject) {
    synchronized(out) {
        out.print(obj.toString())
        out.print('\n')
        out.flush()
    }
}

private fun log(s: String) = synchronized(err) { err.println(s) }

private fun clipJson(c: Clip, live: Boolean?, ev: String?) = buildJsonObject {
    if (ev != null) put("ev", ev)
    put("id", c.id)
    put("src", c.src)
    put("kind", c.kind)
    put("ts", c.ts)
    if (live != null) put("live", live)
    c.text?.let { put("text", it) }
    c.size?.let { put("size", it) }
    c.sha?.let { put("sha", it) }
    c.mime?.let { put("mime", it) }
    if (c.isCode) put("otp", true)
}

private fun membersJson(list: List<MemberRecord>) = buildJsonObject {
    put("ev", "members")
    put("members", JsonArray(list.map { it.toJson() }))
}

private fun usage(): Nothing {
    log("usage: cli --state <dir> --name <name> [--port <n>] [--tailnet <dir> [--tailnet-control <url>]]")
    exitProcess(2)
}

private fun tailnetJson(st: TailnetStatus) = buildJsonObject {
    put("ev", "tailnet")
    put("state", st.state)
    put("ip", st.ip ?: "")
    put("peers", st.peers.size)
}

fun main(args: Array<String>) {
    var stateDir: String? = null
    var name = "Nearclip CLI"
    var port = 0
    var tailnetDir: String? = null
    var tailnetControl: String? = null
    var i = 0
    while (i < args.size) {
        when (args[i]) {
            "--state" -> stateDir = args.getOrNull(++i) ?: usage()
            "--name" -> name = args.getOrNull(++i) ?: usage()
            "--port" -> port = args.getOrNull(++i)?.toIntOrNull()?.takeIf { it in 0..65535 } ?: usage()
            "--tailnet" -> tailnetDir = args.getOrNull(++i) ?: usage()
            "--tailnet-control" -> tailnetControl = args.getOrNull(++i) ?: usage()
            else -> usage()
        }
        i++
    }
    val dir = File(stateDir ?: usage())
    if (!dir.isDirectory && !dir.mkdirs()) {
        log("cannot create state directory ${dir}")
        exitProcess(1)
    }

    val tailnet = tailnetDir?.let {
        val d = File(it)
        TailnetOptions(d, controlUrl = tailnetControl, logPath = File(d, "tailnet.log").absolutePath, testMode = tailnetControl != null)
    }
    val engine = try {
        NearclipEngine(FileStore(dir), EngineConfig(platform = Platform.CLI, defaultName = name, appVersion = "1.1.0", port = port,
            tailnet = tailnet))
    } catch (e: Exception) {
        log("init failed: ${e}")
        exitProcess(1)
    }

    var lastTailnet = ""
    engine.listener = { ev ->
        when (ev) {
            is EngineEvent.Ready -> emit(buildJsonObject {
                put("ev", "ready"); put("id", engine.deviceId); put("port", ev.port); put("group", ev.groupId); put("gt", ev.groupTag)
            })
            is EngineEvent.TicketCreated -> emit(buildJsonObject { put("ev", "ticket"); put("uri", ev.ticket.uri) })
            is EngineEvent.PairSas -> emit(buildJsonObject { put("ev", "pair_sas"); put("sas", ev.sas) })
            is EngineEvent.PairPrompt -> emit(buildJsonObject {
                put("ev", "pair_prompt"); put("peer", ev.prompt.peerId); put("name", ev.prompt.name); put("sas", ev.prompt.sas)
            })
            is EngineEvent.Paired -> emit(buildJsonObject { put("ev", "paired"); put("group", ev.groupId); put("peer", ev.peerId) })
            is EngineEvent.PairFailed -> emit(buildJsonObject { put("ev", "pair_failed"); put("reason", ev.reason) })
            is EngineEvent.PeerUp -> emit(buildJsonObject {
                put("ev", "peer_up"); put("id", ev.record.id); put("name", ev.record.name); put("route", ev.route.wire)
            })
            is EngineEvent.PeerDown -> emit(buildJsonObject { put("ev", "peer_down"); put("id", ev.id) })
            is EngineEvent.ClipAdded -> if (!ev.local) emit(clipJson(ev.clip, ev.live, "clip"))
            is EngineEvent.Transfer -> emit(buildJsonObject {
                val t = ev.transfer
                put("ev", "transfer"); put("id", t.id); put("from", t.from); put("state", t.state.wire)
                put("received", t.received); put("total", t.total)
                t.reason?.let { put("reason", it) }
            })
            is EngineEvent.ClipsDeleted -> ev.ids.forEach { id -> emit(buildJsonObject { put("ev", "deleted"); put("id", id) }) }
            is EngineEvent.MembersChanged -> emit(membersJson(ev.members))
            is EngineEvent.Left -> emit(buildJsonObject { put("ev", "left"); put("reason", ev.reason) })
            is EngineEvent.TooLarge -> emit(buildJsonObject { put("ev", "error"); put("msg", "too large: ${ev.kind}") })
            is EngineEvent.TailnetChanged -> {
                val key = "${ev.status.state}|${ev.status.ip}|${ev.status.peers.size}"
                if (key != lastTailnet) {
                    lastTailnet = key
                    emit(tailnetJson(ev.status))
                }
            }
            is EngineEvent.Log -> log(ev.message)
            else -> Unit
        }
    }

    if (engine.snapshot().deviceName != name) engine.rename(name)
    if (tailnet != null) engine.setRemoteEnabled(true)
    engine.start()

    fun quit(): Nothing {
        engine.shutdown()
        synchronized(out) { out.flush() }
        exitProcess(0)
    }

    val input = BufferedReader(InputStreamReader(System.`in`, Charsets.UTF_8))
    while (true) {
        val line = input.readLine() ?: break
        val trimmed = line.trim()
        if (trimmed.isEmpty()) continue
        val o = try { Wire.parseObject(trimmed) } catch (e: Exception) { null }
        val cmd = o?.str("cmd")
        if (o == null || cmd == null) {
            emit(buildJsonObject { put("ev", "error"); put("msg", "bad command") })
            continue
        }
        try {
            when (cmd) {
                "ticket" -> engine.createTicket()
                "pair_qr" -> {
                    val uri = o.str("uri")?.let { PairingUri.parse(it) }
                    if (uri == null) emit(buildJsonObject { put("ev", "pair_failed"); put("reason", "bad_uri") })
                    else engine.joinWithUri(uri)
                }
                "pair_code" -> {
                    val host = o.str("host")
                    val p = o.int("port")
                    if (host == null || p == null || p !in 1..65535) {
                        emit(buildJsonObject { put("ev", "error"); put("msg", "pair_code needs host and port") })
                    } else {
                        engine.pairWithCode(listOf(Endpoint(host, p)))
                    }
                }
                "accept" -> engine.answerPairPrompt(true)
                "decline" -> engine.answerPairPrompt(false)
                "connect" -> {
                    val host = o.str("host")
                    val p = o.int("port")
                    if (host != null && p != null && p in 1..65535) engine.connect(Endpoint(host, p))
                    else emit(buildJsonObject { put("ev", "error"); put("msg", "connect needs host and port") })
                }
                "send_text" -> o.str("text")?.let { engine.sendText(it, otp = o.bool("otp") == true) }
                "send_image" -> {
                    val path = o.str("path")
                    val bytes = path?.let { runCatching { File(it).readBytes() }.getOrNull() }
                    if (bytes == null) emit(buildJsonObject { put("ev", "error"); put("msg", "cannot read image") })
                    else engine.sendImage(bytes, o.str("mime") ?: "image/png", id = o.str("id"))
                }
                "announce_image" -> {
                    val id = engine.announceImage()
                    emit(buildJsonObject { put("ev", "announced"); put("id", id) })
                }
                "cancel_image" -> o.str("id")?.let { engine.cancelImage(it) }
                "delete" -> o.str("id")?.let { engine.delete(listOf(it)) }
                "remove" -> o.str("peer")?.let { engine.removeMember(it) }
                "rename" -> o.str("name")?.let { engine.rename(it) }
                "list" -> {
                    val snap = engine.snapshot()
                    val clips = snap.history.filter { it.groupId == snap.groupId }.map { clipJson(it, null, null) }
                    emit(buildJsonObject { put("ev", "history"); put("clips", JsonArray(clips)) })
                }
                "members" -> emit(membersJson(engine.snapshot().members))
                "tailnet" -> emit(tailnetJson(engine.snapshot().tailnet))
                "quit" -> quit()
                else -> emit(buildJsonObject { put("ev", "error"); put("msg", "unknown command ${cmd}") })
            }
        } catch (e: Exception) {
            emit(buildJsonObject { put("ev", "error"); put("msg", e.message ?: e.javaClass.simpleName) })
        }
    }
    quit()
}
