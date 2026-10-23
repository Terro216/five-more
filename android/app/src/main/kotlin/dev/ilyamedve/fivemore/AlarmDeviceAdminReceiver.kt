package dev.ilyamedve.fivemore

import android.app.admin.DeviceAdminReceiver
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager

/** Optional, user-enabled uninstall friction. It never locks, wipes, or changes the device. */
class AlarmDeviceAdminReceiver : DeviceAdminReceiver() {
    companion object {
        fun component(context: Context) = ComponentName(context, AlarmDeviceAdminReceiver::class.java)

        /** Null is unsupported, rather than a failed permission that the user must grant. */
        fun active(context: Context): Boolean? {
            if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_DEVICE_ADMIN)) return null
            return context.getSystemService(DevicePolicyManager::class.java).isAdminActive(component(context))
        }
    }
}
