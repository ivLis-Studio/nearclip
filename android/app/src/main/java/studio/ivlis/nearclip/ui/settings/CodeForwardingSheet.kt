package studio.ivlis.nearclip.ui.settings

import androidx.annotation.StringRes
import androidx.compose.foundation.background
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.IconButton
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
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import studio.ivlis.nearclip.R
import studio.ivlis.nearclip.runtime.CaptureSetup
import studio.ivlis.nearclip.runtime.CaptureStatus
import studio.ivlis.nearclip.runtime.CodeStatus
import studio.ivlis.nearclip.ui.components.Sym

class CodeSheetActions(
    val turnOn: () -> Unit,
    val turnOff: () -> Unit,
    val openAccess: () -> Unit,
    val openAppInfo: () -> Unit,
    val unhide: () -> Unit,
    val getShizuku: () -> Unit,
    val openShizuku: () -> Unit,
    val copyCommand: () -> Unit,
)

/** Why "Send verification codes" is on but not working; null when it works or is off. [inSheet]: said where the fix is. */
@StringRes
fun codesProblem(on: Boolean, hidden: Boolean, st: CodeStatus, inSheet: Boolean = false): Int? = when {
    !on -> null
    !st.access -> R.string.forward_codes_needs_access
    hidden && !st.unhidden -> if (inSheet) R.string.codes_hidden_status else R.string.forward_codes_hidden
    hidden -> R.string.codes_still_hidden
    else -> null
}

/**
 * Setup and details of "Send verification codes" (CodeForwarding): notification access, then — on Android 15 and
 * later, which hide codes from apps like Nearclip — letting Nearclip see codes, with Shizuku or one adb command. The
 * button always does the next step. The notes say what leaves the phone and what the other devices do.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CodeForwardingSheet(
    on: Boolean,
    hidden: Boolean,
    st: CodeStatus,
    shizuku: CaptureStatus,
    restricted: Boolean,
    command: String,
    actions: CodeSheetActions,
    onDismiss: () -> Unit,
) {
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    val close: () -> Unit = { scope.launch { sheet.hide() }.invokeOnCompletion { onDismiss() } }
    val problem = codesProblem(on, hidden, st, inSheet = true)
    val needsUnhide = st.mayHide && !st.unhidden
    val viaShizuku = shizuku.setup == CaptureSetup.READY || shizuku.setup == CaptureSetup.NEEDS_PERMISSION

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
                Sym(R.drawable.ic_pin, null, tint = MaterialTheme.colorScheme.onPrimaryContainer)
            }
            Spacer(Modifier.height(16.dp))
            Text(stringResource(R.string.forward_codes), style = MaterialTheme.typography.headlineSmall)
            if (on) {
                Spacer(Modifier.height(10.dp))
                StatusLine(problem, ok = R.string.forward_codes_on)
            }
            Spacer(Modifier.height(12.dp))
            Text(
                stringResource(R.string.codes_body),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(20.dp))
            Surface(
                color = MaterialTheme.colorScheme.surfaceContainer,
                shape = RoundedCornerShape(20.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(Modifier.padding(vertical = 6.dp)) {
                    Step(
                        1, R.string.codes_step_access, R.string.codes_step_access_hint, R.string.codes_allowed,
                        done = st.access, current = !st.access,
                        extra = if (!restricted) null else ({
                            Spacer(Modifier.height(6.dp))
                            Text(
                                stringResource(R.string.codes_step_restricted_hint),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                            TextButton(onClick = actions.openAppInfo, modifier = Modifier.padding(start = 0.dp)) {
                                Text(stringResource(R.string.codes_open_app_info))
                            }
                        }),
                    )
                    if (st.mayHide) {
                        Step(
                            2, R.string.codes_step_unhide, R.string.codes_step_unhide_hint, R.string.codes_allowed,
                            done = st.unhidden, current = st.access && !st.unhidden,
                            extra = {
                                CommandBox(command, actions.copyCommand)
                                if (st.unhideFailed) {
                                    Spacer(Modifier.height(6.dp))
                                    Text(
                                        stringResource(R.string.codes_unhide_failed),
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.error,
                                    )
                                }
                                if (shizuku.setup == CaptureSetup.NOT_INSTALLED) {
                                    TextButton(onClick = actions.getShizuku) { Text(stringResource(R.string.capture_get_shizuku)) }
                                }
                            },
                        )
                    }
                }
            }
            Spacer(Modifier.height(24.dp))

            val primary: Pair<Int, () -> Unit> = when {
                !st.access -> R.string.codes_open_access to actions.openAccess
                needsUnhide && viaShizuku -> (if (st.unhiding) R.string.codes_unhiding else R.string.codes_unhide_shizuku) to actions.unhide
                needsUnhide && (shizuku.setup == CaptureSetup.NOT_RUNNING || shizuku.setup == CaptureSetup.DENIED) ->
                    R.string.capture_open_shizuku to actions.openShizuku
                needsUnhide -> R.string.codes_copy_command to actions.copyCommand
                !on -> R.string.codes_turn_on to { actions.turnOn(); close() }
                else -> R.string.done to close
            }
            Button(
                onClick = primary.second,
                enabled = !st.unhiding,
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 56.dp),
            ) {
                Text(stringResource(primary.first), style = MaterialTheme.typography.titleSmall)
            }
            Spacer(Modifier.height(4.dp))
            TextButton(
                onClick = { if (on) actions.turnOff(); close() },
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(
                    stringResource(if (on) R.string.codes_turn_off else R.string.cancel),
                    color = if (on) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary,
                )
            }
            Spacer(Modifier.height(20.dp))
            Column {
                Note(R.drawable.ic_lock, stringResource(R.string.codes_note_only_code))
                Spacer(Modifier.height(14.dp))
                Note(R.drawable.ic_notifications, stringResource(R.string.codes_note_apps))
                Spacer(Modifier.height(14.dp))
                Note(R.drawable.ic_content_copy, stringResource(R.string.codes_note_ask))
            }
        }
    }
}

/** The adb command, selectable, with a copy button. */
@Composable
private fun CommandBox(command: String, onCopy: () -> Unit) {
    Spacer(Modifier.height(10.dp))
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainerHighest,
        shape = RoundedCornerShape(12.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(Modifier.padding(start = 12.dp, end = 2.dp), verticalAlignment = Alignment.CenterVertically) {
            androidx.compose.foundation.text.selection.SelectionContainer(Modifier.weight(1f)) {
                Text(
                    command,
                    style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                    modifier = Modifier.padding(vertical = 10.dp),
                )
            }
            IconButton(onClick = onCopy) {
                Sym(R.drawable.ic_content_copy, stringResource(R.string.codes_copy_command), Modifier.size(20.dp))
            }
        }
    }
}
