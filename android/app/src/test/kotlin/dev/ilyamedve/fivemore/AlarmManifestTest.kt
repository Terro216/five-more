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

    @Test fun protectionDoesNotIntroduceAccessibilityOverlayOrDestructivePermissions() {
        val manifest = root("AndroidManifest.xml")
        val permissions = elements(manifest, "uses-permission").map { it.getAttributeNS(androidNamespace, "name") }
        assertTrue(permissions.contains("android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"))
        for (permission in listOf("SYSTEM_ALERT_WINDOW", "BIND_ACCESSIBILITY_SERVICE", "MASTER_CLEAR", "MANAGE_DEVICE_ADMINS", "ACCESS_NOTIFICATION_POLICY")) {
            assertFalse(permissions.contains("android.permission.$permission"))
        }
        assertFalse(elements(manifest, "service").any {
            it.getAttributeNS(androidNamespace, "permission") == "android.permission.BIND_ACCESSIBILITY_SERVICE"
        })
    }
}
