allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// 统一各插件库的 compileSdk：部分依赖（如 flutter_plugin_android_lifecycle）
// 要求 compile against 36，而某些第三方插件（如 file_picker 8.x）的 AAR
// 内部声明较低 compileSdk，需覆盖拉齐到 app 级 compileSdk（36）。
// 必须在 evaluationDependsOn(":app") 之前注册，否则子项目已求值会报错。
subprojects {
    afterEvaluate {
        if (plugins.hasPlugin("com.android.library")) {
            extensions.configure<com.android.build.gradle.LibraryExtension> {
                compileSdk = 36
            }
        }
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
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
