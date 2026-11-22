"""Patches the Android project that `flutter create` generates in CI.

- permissions, app name, picture-in-picture, "Open with" for videos
- custom MainActivity (open-with + PiP bridge)
- forces compileSdk 36 on plugins that still target older SDKs
"""
import glob
import os
import shutil

# ---------------------------------------------------------------- manifest
f = 'android/app/src/main/AndroidManifest.xml'
s = open(f, encoding='utf-8').read()

perms = (
    '<uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE"/>\n'
    '    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32"/>\n'
    '    <uses-permission android:name="android.permission.READ_MEDIA_VIDEO"/>\n'
    '    '
)
if 'MANAGE_EXTERNAL_STORAGE' not in s:
    s = s.replace('<application', perms + '<application', 1)
s = s.replace('android:label="reel"', 'android:label="AURA"')

if 'supportsPictureInPicture' not in s:
    s = s.replace(
        'android:name=".MainActivity"',
        'android:name=".MainActivity"\n            android:supportsPictureInPicture="true"\n            android:resizeableActivity="true"',
        1,
    )

filters = '''
            <intent-filter>
                <action android:name="android.intent.action.VIEW"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <category android:name="android.intent.category.BROWSABLE"/>
                <data android:scheme="content"/>
                <data android:scheme="file"/>
                <data android:mimeType="video/*"/>
            </intent-filter>
            <intent-filter>
                <action android:name="android.intent.action.VIEW"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <data android:scheme="content"/>
                <data android:scheme="file"/>
                <data android:mimeType="application/x-matroska"/>
                <data android:mimeType="application/mp4"/>
                <data android:mimeType="application/x-mpegURL"/>
            </intent-filter>
        </activity>'''
if 'android.intent.action.VIEW' not in s:
    s = s.replace('</activity>', filters, 1)

open(f, 'w', encoding='utf-8').write(s)

# ---------------------------------------------------------------- activity
targets = glob.glob('android/app/src/main/kotlin/**/MainActivity.kt', recursive=True)
dest = targets[0] if targets else 'android/app/src/main/kotlin/dev/reel/reel/MainActivity.kt'
os.makedirs(os.path.dirname(dest), exist_ok=True)
shutil.copy('ci/MainActivity.kt', dest)

# ---------------------------------------------------------------- gradle
g = 'android/build.gradle.kts'
s = open(g, encoding='utf-8').read()
block = '''subprojects {
    if (name != "app") {
        afterEvaluate {
            val ext = extensions.findByName("android")
            if (ext != null) {
                try {
                    ext.javaClass.methods
                        .firstOrNull { it.name == "setCompileSdk" && it.parameterCount == 1 }
                        ?.invoke(ext, 36)
                } catch (e: Throwable) {
                }
            }
        }
    }
}

'''
if 'setCompileSdk' not in s:
    s = s.replace('allprojects', block + 'allprojects', 1) if 'allprojects' in s else block + s
open(g, 'w', encoding='utf-8').write(s)
# ---------------------------------------------------------------- signing
# One permanent key (from repo secrets) so every build installs as an update.
a = 'android/app/build.gradle.kts'
s = open(a, encoding='utf-8').read()
if 'REEL_KEYSTORE' not in s:
    signing = '''    signingConfigs {
        if (System.getenv("REEL_KEYSTORE") != null) {
            create("reel") {
                storeFile = file(System.getenv("REEL_KEYSTORE")!!)
                storePassword = System.getenv("REEL_KEY_PASS")
                keyAlias = "reel"
                keyPassword = System.getenv("REEL_KEY_PASS")
            }
        }
    }

    buildTypes {'''
    s = s.replace('    buildTypes {', signing, 1)
    s = s.replace(
        'signingConfig = signingConfigs.getByName("debug")',
        'signingConfig = if (System.getenv("REEL_KEYSTORE") != null) signingConfigs.getByName("reel") else signingConfigs.getByName("debug")',
        1,
    )
    open(a, 'w', encoding='utf-8').write(s)
print('patched')
