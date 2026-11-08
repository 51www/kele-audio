import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.dsl.KotlinAndroidProjectExtension

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
    // AGP 9 下 file_picker 11 把 Kotlin 编译交给 AGP 内置 Kotlin，只有开启
    // android.builtInKotlin 才会编译其 Kotlin 源码；但 flutter_tts 4.2.5 仍显式
    // 应用旧 KGP，开启内置 Kotlin 会直接冲突。这里单独给 file_picker 补上 KGP，
    // 避免 GeneratedPluginRegistrant 找不到 FilePickerPlugin。
    if (project.name == "file_picker") {
        project.pluginManager.apply("org.jetbrains.kotlin.android")
        // 主工程 Java/Kotlin 统一为 JVM 17，插件默认跟随机 JDK 25 会被 AGP 拒绝。
        project.extensions.configure<KotlinAndroidProjectExtension>("kotlin") {
            compilerOptions.jvmTarget.set(JvmTarget.JVM_17)
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
