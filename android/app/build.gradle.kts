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
    // file_picker 依赖的 flutter_plugin_android_lifecycle 要求 compileSdk >= 36
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    packaging {
        jniLibs {
            // M9.0：AGP8 默认 extractNativeLibs=false（so 不解压、映射自 APK），
            // 此时 dlopen("libmpv.so") 按名打开会失败，media_kit 初始化抛
            // "ensureInitialized must be called..."。改为解压安装以按名加载。
            useLegacyPackaging = true
        }
    }

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
        // 应用名：AndroidManifest 里 ${appLabel} 占位（可乐听书）
        manifestPlaceholders["appLabel"] = "可乐听书"
    }

    // 签名：release 读正式 key.properties；debug/profile 读独立的 dev-key.properties（两者均 git-ignored）。
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
        // 调试专用 keystore：与正式包签名完全无关（文件与口令均不入仓库），
        // debug/profile 变体统一用它，避免本机调试包与正式包签名混用。
        create("dev") {
            val devKeyProperties = Properties()
            val devKeyFile = file("dev-key.properties")
            if (devKeyFile.exists()) {
                devKeyProperties.load(FileInputStream(devKeyFile))
            }
            storeFile = file(checkNotNull(devKeyProperties["storeFile"] as String?) {
                "android/app/dev-key.properties 缺少 storeFile，无法签名 debug/profile 变体"
            })
            storePassword = checkNotNull(devKeyProperties["storePassword"] as String?) {
                "android/app/dev-key.properties 缺少 storePassword"
            }
            keyAlias = checkNotNull(devKeyProperties["keyAlias"] as String?) {
                "android/app/dev-key.properties 缺少 keyAlias"
            }
            keyPassword = checkNotNull(devKeyProperties["keyPassword"] as String?) {
                "android/app/dev-key.properties 缺少 keyPassword"
            }
        }
    }

    buildTypes {
        release {
            // 正式签名；debug/profile 见下
            signingConfig = signingConfigs.getByName("release")
        }
        debug {
            // AGP 会给 debug 变体自动回落到默认 debug keystore，这里显式改用 dev keystore，
            // 保证本机调试包与正式包签名完全无关（不外发）。
            signingConfig = signingConfigs.getByName("dev")
        }
        getByName("profile") {
            signingConfig = signingConfigs.getByName("dev")
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
