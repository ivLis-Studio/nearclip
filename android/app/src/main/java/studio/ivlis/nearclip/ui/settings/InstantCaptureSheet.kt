package studio.ivlis.nearclip.ui.settings

import android.os.Build
import androidx.annotation.DrawableRes
import androidx.annotation.StringRes
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import studio.ivlis.nearclip.R
import studio.ivlis.nearclip.runtime.CaptureSetup
import studio.ivlis.nearclip.runtime.CaptureStatus
import studio.ivlis.nearclip.ui.components.StatusDot
import studio.ivlis.nearclip.ui.components.Sym
import studio.ivlis.nearclip.ui.theme.Brand

class CaptureSheetActions(
    val turnOn: () -> Unit,
    val turnOff: () -> Unit,
    val getShizuku: () -> Unit,
    val openShizuku: () -> Unit,
    val allow: () -> Unit,
)

/** Why "Bring copies into Nearclip instantly" is on but not working; null when it works or is off. */
@StringRes
fun captureProblem(on: Boolean, stayConnected: Boolean, st: CaptureStatus): Int? = when {
    !on -> null
    st.failed -> R.string.instant_capture_failed
    st.setup == CaptureSetup.NOT_INSTALLED -> R.string.instant_capture_not_installed
    st.setup == CaptureSetup.OUTDATED -> R.string.instant_capture_outdated
    st.setup == CaptureSetup.NOT_RUNNING -> R.string.instant_capture_not_running
    st.setup == CaptureSetup.NEEDS_PERMISSION || st.setup == CaptureSetup.DENIED -> R.string.instant_capture_not_allowed
    !stayConnected -> R.string.instant_capture_needs_background
    else -> null
}

/**
 * Setup and details of "Bring copies into Nearclip instantly" (InstantCapture): says that it needs Shizuku, walks
 * through installing, starting and allowing it — the button always does the next step — and turns the feature on
 * only when asked. The notes say what is sent, what is never read, and the paste notice Android shows.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun InstantCaptureSheet(
    on: Boolean,
    stayConnected: Boolean,
    st: CaptureStatus,
    actions: CaptureSheetActions,
    onDismiss: () -> Unit,
) {
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    val close: () -> Unit = { scope.launch { sheet.hide() }.invokeOnCompletion { onDismiss() } }
    val builtIn = st.setup == CaptureSetup.BUILT_IN
    val problem = captureProblem(on, stayConnected, st)

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheet) {
        Column(
            Modifier
                .verticalScroll(rememberScrollState())
                .navigationBarsPadding()
                .padding(horizontal = 24.dp)
                .padding(bottom = 16.dp),
        ) {
            Box(
                Modifier
                    .size(52.dp)
                    .clip(RoundedCornerShape(16.dp))
                    .background(MaterialTheme.colorScheme.primaryContainer),
                contentAlignment = Alignment.Center,
            ) {
                Sym(R.drawable.ic_content_paste_go, null, tint = MaterialTheme.colorScheme.onPrimaryContainer)
            }
            Spacer(Modifier.height(16.dp))
            Text(stringResource(R.string.instant_capture), style = MaterialTheme.typography.headlineSmall)
            if (on) {
                Spacer(Modifier.height(10.dp))
                StatusLine(problem)
            }
            Spacer(Modifier.height(12.dp))
            if (!builtIn) {
                Text(
                    stringResource(R.string.capture_needs_shizuku),
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.primary,
                )
                Spacer(Modifier.height(6.dp))
            }
            Text(
                stringResource(if (builtIn) R.string.capture_body_builtin else R.string.capture_body),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (!builtIn) {
                Spacer(Modifier.height(20.dp))
                Steps(st)
            }
            Spacer(Modifier.height(24.dp))

            val primary: Pair<Int, () -> Unit>? = when {
                st.setup == CaptureSetup.NOT_INSTALLED -> R.string.capture_get_shizuku to actions.getShizuku
                st.setup == CaptureSetup.OUTDATED -> R.string.capture_update_shizuku to actions.getShizuku
                st.setup == CaptureSetup.NOT_RUNNING || st.setup == CaptureSetup.DENIED -> R.string.capture_open_shizuku to actions.openShizuku
                st.setup == CaptureSetup.NEEDS_PERMISSION -> R.string.capture_allow to actions.allow
                on -> R.string.done to close
                st.failed -> null
                else -> R.string.capture_turn_on to { actions.turnOn(); close() }
            }
            if (primary != null) {
                Button(
                    onClick = primary.second,
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 56.dp),
                ) {
                    Text(stringResource(primary.first), style = MaterialTheme.typography.titleSmall)
                }
                Spacer(Modifier.height(4.dp))
            }
            TextButton(
                onClick = { if (on) actions.turnOff(); close() },
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(
                    stringResource(if (on) R.string.capture_turn_off else R.string.cancel),
                    color = if (on) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary,
                )
            }
            Spacer(Modifier.height(20.dp))
            Notes(st)
        }
    }

}

@Composable
internal fun StatusLine(@StringRes problem: Int?, @StringRes ok: Int = R.string.instant_capture_on) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        if (problem == null) {
            StatusDot(online = true, ring = MaterialTheme.colorScheme.surfaceContainerLow)
            Spacer(Modifier.width(10.dp))
            Text(stringResource(ok), style = MaterialTheme.typography.bodyMedium, color = Brand.OnlineText)
        } else {
            Sym(R.drawable.ic_error, null, Modifier.size(18.dp), tint = Brand.Warning)
            Spacer(Modifier.width(8.dp))
            Text(stringResource(problem), style = MaterialTheme.typography.bodyMedium)
        }
    }
}

/** Install → start → allow, each checked off as it is done; only the current step explains itself. */
@Composable
private fun Steps(st: CaptureStatus) {
    val installed = st.setup != CaptureSetup.NOT_INSTALLED && st.setup != CaptureSetup.OUTDATED
    val running = installed && st.setup != CaptureSetup.NOT_RUNNING
    val allowed = st.setup == CaptureSetup.READY
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainer,
        shape = RoundedCornerShape(20.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(vertical = 6.dp)) {
            Step(
                1, R.string.capture_step_install,
                if (st.setup == CaptureSetup.OUTDATED) R.string.capture_step_update_hint else R.string.capture_step_install_hint,
                R.string.capture_installed, done = installed, current = !installed,
            )
            Step(2, R.string.capture_step_start, R.string.capture_step_start_hint, R.string.capture_running, done = running, current = installed && !running)
            Step(
                3, R.string.capture_step_allow,
                if (st.setup == CaptureSetup.DENIED) R.string.capture_step_denied_hint else R.string.capture_step_allow_hint,
                R.string.capture_allowed, done = allowed, current = running && !allowed,
            )
        }
    }
}

/** One step of a setup; [extra] (a command, a button) shows under the hint while it is the current step. */
@Composable
internal fun Step(
    n: Int,
    @StringRes title: Int,
    @StringRes hint: Int,
    @StringRes doneLabel: Int,
    done: Boolean,
    current: Boolean,
    extra: (@Composable () -> Unit)? = null,
) {
    val primary = MaterialTheme.colorScheme.primary
    Row(
        Modifier
            .fillMaxWidth()
            .semantics(mergeDescendants = true) {}
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Box(
            Modifier
                .size(28.dp)
                .clip(CircleShape)
                .then(
                    when {
                        done -> Modifier.background(primary)
                        current -> Modifier.border(2.dp, primary, CircleShape)
                        else -> Modifier.border(1.dp, MaterialTheme.colorScheme.outlineVariant, CircleShape)
                    },
                ),
            contentAlignment = Alignment.Center,
        ) {
            if (done) {
                Sym(R.drawable.ic_check, null, Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onPrimary)
            } else {
                Text(
                    n.toString(),
                    style = MaterialTheme.typography.labelLarge,
                    color = if (current) primary else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        Spacer(Modifier.width(14.dp))
        Column(
            Modifier
                .weight(1f)
                .padding(top = 3.dp),
        ) {
            Text(
                stringResource(title),
                style = MaterialTheme.typography.titleSmall,
                color = if (done || current) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant,
            )
            when {
                done -> Text(stringResource(doneLabel), style = MaterialTheme.typography.bodySmall, color = Brand.OnlineText)
                current -> {
                    Spacer(Modifier.height(2.dp))
                    Text(stringResource(hint), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    extra?.invoke()
                }
            }
        }
    }
}

@Composable
private fun Notes(st: CaptureStatus) {
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Note(R.drawable.ic_notes, stringResource(R.string.capture_note_text_only))
        Note(R.drawable.ic_password, stringResource(R.string.capture_note_sensitive))
        // Android 12+ tells the user each time the clipboard is read by an app other than the one that copied.
        if (st.setup != CaptureSetup.BUILT_IN && Build.VERSION.SDK_INT >= 31) {
            Note(
                R.drawable.ic_notifications,
                stringResource(R.string.capture_note_notices),
            )
        }
    }
}

@Composable
internal fun Note(@DrawableRes icon: Int, text: String) {
    Row(verticalAlignment = Alignment.Top) {
        Sym(icon, null, Modifier.size(20.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
