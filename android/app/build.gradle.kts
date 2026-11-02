import java.util.Properties
import java.io.FileInputStream

// Load signing credentials from android/app/key.properties (git-ignored)
val keystoreProperties = Properties()
val keystorePropertiesFile = file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.kele.audio"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.kele.audio"
        // 最低支持 Android 8.0（API 26），见 PRD §6
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // 正式签名：从 key.properties 读取密钥材料（文件已被 gitignore，不入仓库）。
    signingConfigs {
        create("release") {
            storeFile = file(checkNotNull(keystoreProperties["storeFile"]) {
                "android/app/key.properties 缺少 storeFile，无法使用正式签名打包 release"
            } as String)
            storePassword = checkNotNull(keystoreProperties["storePassword"]) {
                "android/app/key.properties 缺少 storePassword"
            } as String
            keyAlias = checkNotNull(keystoreProperties["keyAlias"]) {
                "android/app/key.properties 缺少 keyAlias"
            } as String
            keyPassword = checkNotNull(keystoreProperties["keyPassword"]) {
                "android/app/key.properties 缺少 keyPassword"
            } as String
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
