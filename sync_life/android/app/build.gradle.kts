plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.sync_life"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlin{
        jvmToolchain(17)
    }

    packaging {
        jniLibs {
            useLegacyPackaging = false
        }
        resources {
            pickFirsts.add("**/libil2cpp.so")
            pickFirsts.add("**/libmain.so")
        }
    }

    buildFeatures {
        buildConfig = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.sync_life"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
        // The phone Unity export contains ARM64 only. Override Flutter's per-build defaults.
        configureEach {
            ndk.abiFilters.clear()
            ndk.abiFilters.add("arm64-v8a")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("com.microsoft.onnxruntime:onnxruntime-android:1.19.2")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
    testImplementation("com.microsoft.onnxruntime:onnxruntime:1.19.2")
    implementation(project(":unityLibrary"))
    implementation(platform("org.jetbrains.kotlin:kotlin-bom:2.1.0"))
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.6.1")
    implementation("com.google.android.material:material:1.11.0")
    implementation("androidx.constraintlayout:constraintlayout:2.1.4")
}

val validatePhoneMocapUnityExport = tasks.register("validatePhoneMocapUnityExport") {
    doLast {
        val assembly = project(":unityLibrary").file("src/main/Il2CppOutputProject/Source/il2cppOutput/Assembly-CSharp.cpp")
        check(assembly.exists() && assembly.readText().contains("SyncLifeMoCapBridge")) {
            "Unity 导出库缺少手机动捕接口。请导出更新后的 Unity 项目，或用 -PphoneUnityLibrary 指向已更新的导出库。"
        }
    }
}

tasks.configureEach {
    if (name in listOf("assembleDebug", "assembleRelease", "assembleProfile")) dependsOn(validatePhoneMocapUnityExport)
}

tasks.register("copyApkToFlutterExpectedLocation") {
    dependsOn(validatePhoneMocapUnityExport)
    doLast {
        val assembleState = tasks.findByName("assembleDebug")?.state
        if (assembleState?.executed != true || assembleState.failure != null) {
            println("assembleDebug 未成功，保留现有 APK")
            return@doLast
        }
        val buildDir = layout.buildDirectory.get().asFile
        val sourceApk = file("${buildDir}/outputs/apk/debug/app-debug.apk")
        val targetDir = file("${projectDir}/../../build/app/outputs/flutter-apk")
        val targetApk = file("${targetDir}/app-debug.apk")
        
        if (sourceApk.exists()) {
            targetDir.mkdirs()
            sourceApk.copyTo(targetApk, overwrite = true)
            println("APK 已复制到: ${targetApk.absolutePath}")
        } else {
            println("未找到 APK 文件: ${sourceApk.absolutePath}")
        }
    }
}

afterEvaluate {
    tasks.findByName("assembleDebug")?.finalizedBy("copyApkToFlutterExpectedLocation")
}
