import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// --------------- release signing ---------------
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(keystorePropertiesFile.inputStream())
}

// AGP 9.0.1 把旧的 `Project.android(Action<BaseAppModuleExtension>)` 访问器标记为
// ERROR 级弃用（消息指向 ApplicationExtension）。本项目 gradle.properties 显式设了
// android.newDsl=false（沿用旧 DSL，以保证 clipboard_watcher 等未维护插件能正常编译），
// 故此处用 @Suppress 抑制该弃用告警，而不是切到 newDsl=true（那会让旧插件出问题）。
@Suppress("DEPRECATION")
android {
    namespace = "com.everlink.app"
    // 显式锁定 compileSdk=36：本项目多个插件（file_picker、network_info_plus、
    // package_info_plus、saver_gallery、url_launcher_android、webview_flutter_android 等）
    // 要求 compileSdk >= 36，jni/jni_flutter 要求 >= 35。compileSdk 取所有插件要求的最大值，
    // 且 Flutter 会以 App 的 compileSdk 为准去配置各插件（含 clipboard_watcher），
    // 因此升到 36 后插件侧的 AAR 元数据检查也会通过。compileSdk 与 targetSdk 相互独立，
    // 仅控制“可编译调用哪些 API”，不影响运行期行为，无需同步升 targetSdk。
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.everlink.app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Flutter Gradle 插件在编译时注入此占位符，显式声明让 Android Studio Lint 不报红
        manifestPlaceholders["applicationName"] = "android.app.Application"
    }

    sourceSets {
        getByName("main") {
            kotlin.directories.add("src/main/kotlin")
        }
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }

}

// 输出的 APK 文件名统一为 EverLink-<版本号>.apk（如 EverLink-1.0.0.apk）。
// AGP 9 已彻底移除旧的 applicationVariants / BaseVariantOutput.outputFileName API，
// 其替代的 VariantOutput.outputFileName 在本版本(9.0.1)也解析不到，故不依赖脆弱的
// variant API，改用 assembleRelease 之后的重命名任务：
//   通用包 app-release.apk               -> EverLink-<ver>.apk
//   按 ABI 拆分 app-<abi>-release.apk    -> EverLink-<ver>-<abi>.apk
val everlinkApkVersion: String = flutter.versionName
tasks.register("renameEverLinkApk") {
    doLast {
        val outDir = File(layout.buildDirectory.get().asFile, "app/outputs/flutter-apk")
        if (outDir.isDirectory) {
            outDir.listFiles { f -> f.extension == "apk" }?.forEach { apk ->
                val newName = when (val n = apk.name) {
                    "app-release.apk" ->
                        "EverLink-$everlinkApkVersion.apk"
                    else ->
                        if (n.endsWith("-release.apk"))
                            "EverLink-$everlinkApkVersion-${n.removePrefix("app-").removeSuffix("-release.apk")}.apk"
                        else n
                }
                val target = File(outDir, newName)
                if (!target.exists()) apk.renameTo(target)
            }
        }
    }
}
// assembleRelease 在 AGP 9 中是延迟注册的，脚本体执行时它还不存在，
// 直接用 tasks.named 查会报 “not found”，故改用 whenTaskAdded 监听其注册后再挂 finalizedBy。
tasks.whenTaskAdded {
    if (name == "assembleRelease") {
        finalizedBy("renameEverLinkApk")
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
