# R8 keep rules for AniBaka (ani.baka)
#
# Flutter plugins that use JNI, reflection, or are referenced from
# AndroidManifest/services must keep their class names.

# Flutter's Gradle plugin and embedding provide their own R8 rules. Keeping the
# entire embedding would also retain its optional Play Store deferred-component
# implementation, which is not used by this APK and requires Play Core classes.

# audio_service: MediaBrowserService / MediaSessionService are referenced
# from the manifest and via reflection by the plugin.
-keep class com.ryanheise.audioservice.** { *; }

# media_kit: JNI entry points used by libmediakitandroidhelper.so.
-keep class com.mediakit.** { *; }

# Apache Tika (MIME detection, pulled in by a file-type plugin) is
# data-driven and reflective; keep it whole.
-keep class org.apache.tika.** { *; }
-dontwarn org.apache.tika.**
-dontwarn javax.**
-dontwarn java.awt.**
-dontwarn org.slf4j.**

# Hive TypeAdapters are code-generated and registered explicitly;
# nothing needed here, but keep adapter classes that might be looked
# up reflectively by future versions.
-keep class * extends com.hive** { *; }
