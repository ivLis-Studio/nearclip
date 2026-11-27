package studio.ivlis.nearclip.capture;
import android.content.ClipData;
import android.content.ClipDescription;
import studio.ivlis.nearclip.capture.IClipboardEvents;
interface IClipboardAccess {
    void destroy() = 16777114;
    ClipDescription description() = 1;
    ClipData clip() = 2;
    void listen(IClipboardEvents callback, int userId) = 3;
    void unlisten() = 4;
}
