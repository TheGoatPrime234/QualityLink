subprojects {
    afterEvaluate {
        // 1. Zwingt die interne Android-Konfiguration des Plugins auf Java 17
        project.extensions.findByType<com.android.build.gradle.BaseExtension>()?.let { android ->
            android.compileOptions.sourceCompatibility = org.gradle.api.JavaVersion.VERSION_17
            android.compileOptions.targetCompatibility = org.gradle.api.JavaVersion.VERSION_17
        }
        
        // 2. Zwingt den Kotlin-Compiler auf Version 17
        project.tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            kotlinOptions.jvmTarget = "17"
        }
    }
}

rootProject.buildDir = File("../build")
subprojects {
    project.buildDir = File(rootProject.buildDir, project.name)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.buildDir)
}




