# Nearclip release rules.
# The engine uses only JCA (java.security / javax.crypto) and kotlinx.serialization's JsonElement API,
# which need no reflection rules. Keep line numbers for readable crash reports.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
# The embedded Tailscale node is called through JNI (tailnet/capi/jni.c): keep the class and its native methods.
-keep class studio.ivlis.nearclip.core.tailnet.TailnetNative { *; }
-keepclasseswithmembernames,includedescriptorclasses class * { native <methods>; }
