package studio.ivlis.nearclip

import android.app.Application
import studio.ivlis.nearclip.runtime.Nearclip

class NearclipApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Nearclip.get(this)
    }
}
