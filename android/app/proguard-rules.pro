# Nearclip release rules.
# The engine uses only JCA (java.security / javax.crypto) and kotlinx.serialization's JsonElement API,
# which need no reflection rules. Keep line numbers for readable crash reports.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
