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
// Kotlin / Java 都用 configureEach 惰性配置（任务创建即套用），无需 afterEvaluate
// 或 projectsEvaluated。各模块（app、file_picker 等）自身 compileOptions 已是 17，
// 这里再强制一次仅作兜底对齐，同值不冲突。
subprojects {
    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }
    // JavaCompile 任务的 sourceCompatibility/targetCompatibility 是 String 类型，
    // 不能用 JavaVersion 枚举（那只在 AGP 的 compileOptions 里成立）。
    tasks.withType<JavaCompile>().configureEach {
        sourceCompatibility = "17"
        targetCompatibility = "17"
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
