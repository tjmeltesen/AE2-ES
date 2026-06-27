pluginManagement {
    repositories {
        maven {
            name = "GTNH Maven"
            url = uri("https://nexus.gtnewhorizons.com/repository/public/")
            mavenContent {
                includeGroup("com.gtnewhorizons")
                includeGroupByRegex("com\\.gtnewhorizons\\..+")
            }
        }
        maven {
            name = "OvermindDL1"
            url = uri("https://gregtech.overminddl1.com/")
            mavenContent {
                includeGroupByRegex("com\\.gtnewhorizons\\..+")
            }
        }
        gradlePluginPortal()
        mavenCentral()
    }
}

rootProject.name = "ae2esgametest"

plugins {
    id("com.gtnewhorizons.gtnhsettingsconvention") version("2.0.24")
}
