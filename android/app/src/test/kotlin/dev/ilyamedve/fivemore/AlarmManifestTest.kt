package dev.ilyamedve.fivemore

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/** Packaging checks: admin remains voluntary/minimal, and locked boot can reach the alarm engine. */
class AlarmManifestTest {
    private val androidNamespace = "http://schemas.android.com/apk/res/android"

    private fun source(path: String): File {
        var directory = File(checkNotNull(System.getProperty("user.dir")))
        repeat(6) {
            for (prefix in listOf("", "app/", "android/app/")) {
                val file = File(directory, prefix + "src/main/" + path)
                if (file.isFile) return file
            }
            directory = directory.parentFile ?: directory
        }
        error("Cannot locate Android source file $path")
    }

    private fun root(path: String): Element = DocumentBuilderFactory.newInstance().apply {
        isNamespaceAware = true
        setFeature("http://apache.org/xml/features/disallow-doctype-decl", true)
    }.newDocumentBuilder().parse(source(path)).documentElement

    private fun elements(root: Element, tag: String): List<Element> {
        val list = root.getElementsByTagName(tag)
        return (0 until list.length).map { list.item(it) as Element }
    }

    @Test fun appLanguagesIncludeCompleteNativeAlarmResources() {
        val app = elements(root("AndroidManifest.xml"), "application").single()
        assertEquals("@string/app_name", app.getAttributeNS(androidNamespace, "label"))
        assertEquals("@xml/locales_config", app.getAttributeNS(androidNamespace, "localeConfig"))
        val locales = elements(root("res/xml/locales_config.xml"), "locale")
            .map { it.getAttributeNS(androidNamespace, "name") }.toSet()
        assertEquals(setOf("en", "ru"), locales)
        fun messages(directory: String) = elements(root("res/$directory/strings.xml"), "string")
            .associate { it.getAttribute("name") to it.textContent }
        val english = messages("values")
        val russian = messages("values-ru")
        assertEquals(english.keys, russian.keys)
        assertEquals("Five More", english["app_name"])
        assertEquals("Ещё пять", russian["app_name"])
        val format = Regex("%[0-9]+\\$[ds]")
        for ((key, translated) in russian) {
            assertTrue(key, translated.isNotBlank())
            assertEquals(key, format.findAll(english.getValue(key)).map { it.value }.sorted().toList(),
                format.findAll(translated).map { it.value }.sorted().toList())
        }
    }

    @Test fun deviceAdminReceiverIsSystemProtectedAndRequestsNoDeviceControlPolicies() {
        val receiver = elements(root("AndroidManifest.xml"), "receiver")
            .single { it.getAttributeNS(androidNamespace, "name") == ".AlarmDeviceAdminReceiver" }
        assertEquals("true", receiver.getAttributeNS(androidNamespace, "exported"))
        assertEquals("android.permission.BIND_DEVICE_ADMIN", receiver.getAttributeNS(androidNamespace, "permission"))
        val metadata = elements(receiver, "meta-data").single()
        assertEquals("android.app.device_admin", metadata.getAttributeNS(androidNamespace, "name"))
        assertEquals("@xml/alarm_device_admin", metadata.getAttributeNS(androidNamespace, "resource"))
        val policies = elements(root("res/xml/alarm_device_admin.xml"), "uses-policies").single()
        assertEquals(0, elements(policies, "*").size)
    }

    @Test fun bootRecoveryAndMediaPlaybackAreAvailableBeforeFirstUnlock() {
        val manifest = root("AndroidManifest.xml")
        val permissions = elements(manifest, "uses-permission").map { it.getAttributeNS(androidNamespace, "name") }
        assertTrue(permissions.contains("android.permission.RECEIVE_BOOT_COMPLETED"))
        val receiver = elements(manifest, "receiver")
            .single { it.getAttributeNS(androidNamespace, "name") == ".AlarmReceiver" }
        assertEquals("true", receiver.getAttributeNS(androidNamespace, "directBootAware"))
        assertEquals("false", receiver.getAttributeNS(androidNamespace, "exported"))
        val actions = elements(receiver, "action").map { it.getAttributeNS(androidNamespace, "name") }
        for (action in listOf("BOOT_COMPLETED", "LOCKED_BOOT_COMPLETED", "MY_PACKAGE_REPLACED", "TIME_SET", "TIMEZONE_CHANGED")) {
            assertTrue(actions.contains("android.intent.action.$action"))
        }
        assertTrue(actions.contains("android.app.action.SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED"))
        val service = elements(manifest, "service")
            .single { it.getAttributeNS(androidNamespace, "name") == ".AlarmRingingService" }
        assertEquals("true", service.getAttributeNS(androidNamespace, "directBootAware"))
        assertEquals("false", service.getAttributeNS(androidNamespace, "exported"))
    }

    @Test fun protectionDoesNotIntroduceOverlayOrDestructivePermissions() {
        val manifest = root("AndroidManifest.xml")
        val permissions = elements(manifest, "uses-permission").map { it.getAttributeNS(androidNamespace, "name") }
        assertTrue(permissions.contains("android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"))
        for (permission in listOf("SYSTEM_ALERT_WINDOW", "BIND_ACCESSIBILITY_SERVICE", "MASTER_CLEAR", "MANAGE_DEVICE_ADMINS", "ACCESS_NOTIFICATION_POLICY")) {
            assertFalse(permissions.contains("android.permission.$permission"))
        }
        val service = elements(manifest, "service").single {
            it.getAttributeNS(androidNamespace, "permission") == "android.permission.BIND_ACCESSIBILITY_SERVICE"
        }
        assertEquals(".PowerMenuGuardService", service.getAttributeNS(androidNamespace, "name"))
        val config = root("res/xml/power_menu_guard.xml")
        assertEquals("com.android.systemui", config.getAttributeNS(androidNamespace, "packageNames"))
        assertEquals("typeWindowStateChanged", config.getAttributeNS(androidNamespace, "accessibilityEventTypes"))
        assertEquals("flagRetrieveInteractiveWindows", config.getAttributeNS(androidNamespace, "accessibilityFlags"))
        for (capability in listOf("canPerformGestures", "canRequestFilterKeyEvents", "canTakeScreenshot", "isAccessibilityTool")) {
            assertEquals("false", config.getAttributeNS(androidNamespace, capability))
        }
    }
}
