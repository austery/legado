import org.jetbrains.kotlin.gradle.plugin.mpp.KotlinNativeTarget

plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.kotlin.serialization)
}

kotlin {
    val configureFramework: KotlinNativeTarget.() -> Unit = {
        binaries.framework {
            baseName = "ReaderEngine"
            isStatic = false
            binaryOption("bundleId", "io.legado.engine")
            val nativeDir = rootProject.file("data/build/iosNativeLibs/${konanTarget.name}")
            linkerOpts("-L${nativeDir.absolutePath}", "-lquickjs", "-lmbedtls", "-lsqlite3")
            optimized = false
        }
    }
    iosArm64(configureFramework)
    iosSimulatorArm64 {
        configureFramework()
        binaries.withType<org.jetbrains.kotlin.gradle.plugin.mpp.TestExecutable>().configureEach {
            val nativeDir = rootProject.file("data/build/iosNativeLibs/ios_simulator_arm64")
            linkerOpts("-L${nativeDir.absolutePath}", "-lquickjs", "-lmbedtls", "-lsqlite3")
        }
    }
    sourceSets {
        commonTest.dependencies { implementation(libs.jetbrains.kotlin.test) }
        val iosMain = maybeCreate("iosMain").apply { dependsOn(commonMain.get()) }
        iosArm64Main.get().dependsOn(iosMain)
        iosSimulatorArm64Main.get().dependsOn(iosMain)
        commonMain.dependencies {
            implementation(project(":core"))
            implementation(libs.kotlinx.coroutines.core)
            implementation(libs.kotlinx.serialization.json)
            implementation(libs.kotlinx.atomicfu)
            implementation(libs.ktor.client.core)
        }
    }
}
