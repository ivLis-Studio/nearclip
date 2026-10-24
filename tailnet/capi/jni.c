// JNI entry points for Android (and the desktop JVM test CLI). Compiled only with -DNCTN_JNI.
// Kotlin: object studio.ivlis.nearclip.core.tailnet.TailnetNative { @JvmStatic external fun ... }
#ifdef NCTN_JNI
#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include "_cgo_export.h"

static char *nctn_in(JNIEnv *env, jstring s) {
    if (s == NULL) return strdup("");
    const char *u = (*env)->GetStringUTFChars(env, s, NULL);
    char *c = strdup(u ? u : "");
    if (u) (*env)->ReleaseStringUTFChars(env, s, u);
    return c;
}

static jstring nctn_out(JNIEnv *env, char *s) {
    if (s == NULL) return NULL;
    jstring r = (*env)->NewStringUTF(env, s);
    NCTailnetFree(s);
    return r;
}

#define NCTN_FN(name) Java_studio_ivlis_nearclip_core_tailnet_TailnetNative_##name

JNIEXPORT jstring JNICALL NCTN_FN(nativeStart)(JNIEnv *env, jclass cls, jstring config) {
    char *c = nctn_in(env, config);
    char *r = NCTailnetStart(c);
    free(c);
    return nctn_out(env, r);
}

JNIEXPORT jstring JNICALL NCTN_FN(nativeStatus)(JNIEnv *env, jclass cls) { return nctn_out(env, NCTailnetStatus()); }
JNIEXPORT jstring JNICALL NCTN_FN(nativeLogin)(JNIEnv *env, jclass cls) { return nctn_out(env, NCTailnetLogin()); }
JNIEXPORT jstring JNICALL NCTN_FN(nativeLogout)(JNIEnv *env, jclass cls) { return nctn_out(env, NCTailnetLogout()); }
JNIEXPORT jstring JNICALL NCTN_FN(nativeStop)(JNIEnv *env, jclass cls) { return nctn_out(env, NCTailnetStop()); }

JNIEXPORT jstring JNICALL NCTN_FN(nativeSetNetwork)(JNIEnv *env, jclass cls, jstring info) {
    char *c = nctn_in(env, info);
    char *r = NCTailnetSetNetwork(c);
    free(c);
    return nctn_out(env, r);
}

JNIEXPORT void JNICALL NCTN_FN(nativeNetworkChanged)(JNIEnv *env, jclass cls) { NCTailnetNetworkChanged(); }
#else
typedef int nctn_jni_disabled;
#endif
