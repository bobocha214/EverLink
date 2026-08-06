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
}
subprojects {
    project.evaluationDependsOn(":app")
}

// 统一所有子模块（含第三方插件，如 file_picker）的 JVM 目标为 17，与本机 JDK 对齐。
//
// Kotlin Gradle Plugin 2.3.20 会把 jvmTarget 自动推导为运行 Gradle 的 JDK 版本，
// 这里显式拉回 JVM_17，避免与 file_picker 等写死 Java 17 的插件出现
// “Inconsistent JVM Target Compatibility”。
// Kotlin 侧用 configureEach 惰性配置（任务创建即套用）即可，无需 afterEvaluate
// 或 projectsEvaluated。各模块（app、file_picker 等）自身 compileOptions 已是 17，
// 这里再强制一次仅作兜底对齐，同值不冲突。
// Java 侧因第三方插件会写死 1.8，必须在 projectsEvaluated 后兜底（见下方），
// 不能用 configureEach 直接设（会被插件覆盖回 1.8）。
subprojects {
    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }
}

// JavaCompile 任务的 sourceCompatibility/targetCompatibility 是 String 类型，
// 不能用 JavaVersion 枚举（那只在 AGP 的 compileOptions 里成立）。
//
// 关键：必须在所有工程评估完成后才兜底设置。第三方插件（如 clipboard_watcher）
// 自身会把 compileOptions 写死为 1.8，且其配置动作晚于根 subprojects 的
// configureEach，从而把 17 覆盖回 1.8，导致 Kotlin(17) 与 Java(1.8) 不匹配。
// 这里用 gradle.projectsEvaluated（Gradle 级钩子，注册阶段不会触碰任何已评估工程）
// 在所有子模块 build 脚本评估完成后，把每个子模块的 JavaCompile 目标拉回 17，
// 作为最后写入值生效，彻底消除 “Inconsistent JVM Target”。
// 注意：不能用 project.afterEvaluate —— 本工程在根 subprojects 执行时部分子模块
// 已评估完，会抛 “Cannot run Project.afterEvaluate ... when already evaluated”。
gradle.projectsEvaluated {
    // 用 subprojects 返回的 Set<Project> 直接 forEach（Kotlin 标准库），
    // 避免 subprojects { 闭包 } 暴露的 Groovy Closure 重载与 Kotlin lambda 不兼容。
    rootProject.subprojects.forEach { p ->
        // JavaCompile 的 sourceCompatibility/targetCompatibility 是任务属性（惰性可读写），
        // 在 projectsEvaluated 兜底设置可覆盖第三方插件写死的 1.8，使 Kotlin(17) 与 Java(17) 对齐。
        // 注意：compileSdk 不能用此方式兜底——它在评估阶段即被读取，projectsEvaluated 已“太晚”
        // （会报 "It is too late to set compileSdk"）。compileSdk 应在各模块自己的
        // android { compileSdk = ... } 中设置（本项目统一在 app/build.gradle.kts 设为 36，
        // Flutter 会据此配置所有插件）。
        p.tasks.withType<org.gradle.api.tasks.compile.JavaCompile>().configureEach {
            sourceCompatibility = "17"
            targetCompatibility = "17"
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
