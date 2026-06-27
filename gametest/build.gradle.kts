import org.gradle.api.tasks.compile.JavaCompile

plugins {
    id("com.gtnewhorizons.gtnhconvention")
}

// Apply dependencies
apply(from = "dependencies.gradle")

minecraft {
    mcVersion = "1.7.10"
}

// The convention plugin sets up runServer etc. but we primarily
// need compilation — the actual GameTest run requires a Forge
// server that CI builds against.
tasks.named("build") {
    dependsOn("compileJava")
}
