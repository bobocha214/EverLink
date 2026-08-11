package com.everlink.app

import android.Manifest
import android.app.DownloadManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.NetworkCapabilities
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Environment
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address

/**
 * 快传功能需要接收 UDP 多播 / 广播报文来自动发现同一局域网内的设备。
 *
 * Android 的 Wi-Fi 驱动为省电，默认会在链路层**丢弃**目的地不是本机的多播与
 * 广播帧，导致纯 Dart 侧的 RawDatagramSocket 永远收不到对端心跳（表现为
 * "搜索不到设备"）。必须持有 WifiManager.MulticastLock 才能让这些报文上送。
 *
 * 这里通过 MethodChannel 暴露 acquire/release 给 Dart 侧在发现服务启停时调用。
 *
 * 另外还暴露 getWifiSignalStrength 供 Dart 侧查询当前 WiFi 信号强度（RSSI）。
 */
class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null

    // 定位权限授权结果回调的挂起对象（用于 Android 10-12 读取 WiFi 名称）。
    private var pendingLocationResult: MethodChannel.Result? = null
    private val rcWifiLocation = 0x1001

    // 应用内下载并安装 APK 的广播接收器（DownloadManager 下载完成后触发安装）。
    private var installReceiver: BroadcastReceiver? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "acquireMulticastLock" -> {
                    result.success(acquireLock())
                }
                "releaseMulticastLock" -> {
                    releaseLock()
                    result.success(true)
                }
                "getWifiSignalStrength" -> {
                    result.success(getWifiSignalStrength())
                }
                "getDnsServers" -> {
                    result.success(getDnsServers())
                }
                "getWifiInfo" -> {
                    result.success(getWifiInfo())
                }
                "getSdkInt" -> {
                    result.success(Build.VERSION.SDK_INT)
                }
                "requestWifiLocationPermission" -> {
                    requestWifiLocationPermission(result)
                }
                else -> result.notImplemented()
            }
        }

        // 应用内更新：下载 APK 并通过系统安装器安装。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            INSTALLER_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "downloadAndInstall" -> {
                    val url = call.argument<String>("url")
                    if (url.isNullOrEmpty()) {
                        result.error("ARG", "url required", null)
                    } else {
                        downloadAndInstall(url, result)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun acquireLock(): Boolean {
        return try {
            if (multicastLock?.isHeld == true) return true
            val wifi = applicationContext
                .getSystemService(Context.WIFI_SERVICE) as WifiManager
            val lock = wifi.createMulticastLock("everlink-lan-transfer").apply {
                setReferenceCounted(true)
                acquire()
            }
            multicastLock = lock
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun releaseLock() {
        try {
            multicastLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {
        } finally {
            multicastLock = null
        }
    }

    /**
     * 获取当前 WiFi 信号强度（RSSI，单位 dBm，通常 -100 ~ 0）。
     * 返回 Map: { rssi: int, level: int (0-4), description: String }
     */
    @Suppress("DEPRECATION")
    private fun getWifiSignalStrength(): Map<String, Any> {
        return try {
            val wifi = applicationContext
                .getSystemService(Context.WIFI_SERVICE) as WifiManager
            val info = wifi.connectionInfo
            val rssi = info.rssi
            val level = WifiManager.calculateSignalLevel(rssi, 5)  // 0-4
            val desc = when (level) {
                4 -> "极强"
                3 -> "强"
                2 -> "中等"
                1 -> "弱"
                else -> "极弱"
            }
            mapOf(
                "rssi" to rssi,
                "level" to level,
                "description" to desc
            )
        } catch (e: Exception) {
            mapOf("rssi" to 0, "level" to 0, "description" to "不可用")
        }
    }

    /**
     * 获取当前网络使用的 DNS 服务器地址列表。
     * Android 23+ 使用 ConnectivityManager.getLinkProperties()，
     * 兼容回退到 WifiManager.getDhcpInfo()。
     */
    private fun getDnsServers(): List<String> {
        val dnsList = mutableListOf<String>()
        try {
            val cm = applicationContext
                .getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val network = cm.activeNetwork
            val lp = cm.getLinkProperties(network) ?: return emptyList()
            for (addr in lp.dnsServers) {
                val ip = addr.hostAddress
                if (!ip.isNullOrEmpty()) dnsList.add(ip)
            }
        } catch (e: Exception) {
            // 回退：DhcpInfo（已废弃但简单可靠）
            try {
                @Suppress("DEPRECATION")
                val wifi = applicationContext
                    .getSystemService(Context.WIFI_SERVICE) as WifiManager
                @Suppress("DEPRECATION")
                val dhcp = wifi.dhcpInfo
                dnsList.add(intToIp(dhcp.dns1))
                if (dhcp.dns2 != 0) dnsList.add(intToIp(dhcp.dns2))
            } catch (_: Exception) {}
        }
        return dnsList
    }

    private fun intToIp(i: Int): String {
        return (i and 0xFF).toString() + "." +
                (i shr 8 and 0xFF) + "." +
                (i shr 16 and 0xFF) + "." +
                (i shr 24 and 0xFF)
    }

    /**
     * 获取完整的 WiFi 连接信息：SSID、BSSID、网关、子网掩码、信号强度。
     *
     * 关键修正：
     *  - 子网掩码：优先由 ConnectivityManager 的 LinkProperties 前缀长度推导，
     *    不再依赖 DhcpInfo.netmask（多数设备该字段为 0，导致子网掩码取不到）。
     *  - SSID：优先从 ConnectivityManager → NetworkCapabilities.transportInfo
     *    （API 29+ 的 WifiInfo）读取，这是官方推荐的现代 API；在 Android 13+
     *    配合 NEARBY_WIFI_DEVICES 权限无需定位即可拿到真实 SSID。
     *  - 网关：仍由 DhcpInfo 兜底（该字段通常有效）。
     * 返回 Map: { ssid, bssid, gateway, subnetMask, rssi, level, description }
     */
    @Suppress("DEPRECATION")
    private fun getWifiInfo(): Map<String, Any> {
        return try {
            val wifi = applicationContext
                .getSystemService(Context.WIFI_SERVICE) as WifiManager
            val cm = applicationContext
                .getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val network = cm.activeNetwork
            val caps = cm.getNetworkCapabilities(network)
            val dhcp = wifi.dhcpInfo

            // RSSI / SSID / BSSID：优先用 ConnectivityManager 的 transportInfo WifiInfo。
            val rssi: Int
            val ssid: String
            val bssid: String
            val modernInfo = if (Build.VERSION.SDK_INT >= 29 && caps != null) {
                caps.transportInfo as? android.net.wifi.WifiInfo
            } else {
                null
            }
            if (modernInfo != null) {
                rssi = modernInfo.rssi
                ssid = cleanSsid(modernInfo.ssid)
                bssid = modernInfo.bssid ?: ""
            } else {
                val info = wifi.connectionInfo
                rssi = info.rssi
                ssid = cleanSsid(info.ssid)
                bssid = info.bssid ?: ""
            }

            val level = WifiManager.calculateSignalLevel(rssi, 5)
            val desc = when (level) {
                4 -> "极强"
                3 -> "强"
                2 -> "中等"
                1 -> "弱"
                else -> "极弱"
            }

            // 子网掩码：由 LinkProperties 前缀长度推导（最可靠，无需定位权限）。
            var subnetMask = ""
            val lp = cm.getLinkProperties(network)
            if (lp != null) {
                for (la in lp.linkAddresses) {
                    if (la.address is Inet4Address) {
                        subnetMask = prefixToMask(la.prefixLength)
                        break
                    }
                }
            }
            if (subnetMask.isEmpty()) {
                subnetMask = intToIp(dhcp.netmask)
            }

            // 网关：DhcpInfo 兜底（通常有效）。
            val gateway = intToIp(dhcp.gateway)

            mapOf(
                "ssid" to ssid,
                "bssid" to bssid,
                "gateway" to gateway,
                "subnetMask" to subnetMask,
                "rssi" to rssi,
                "level" to level,
                "description" to desc
            )
        } catch (e: Exception) {
            mapOf(
                "ssid" to "",
                "bssid" to "",
                "gateway" to "",
                "subnetMask" to "",
                "rssi" to 0,
                "level" to 0,
                "description" to "不可用"
            )
        }
    }

    /**
     * 统一清洗 SSID：去掉前后引号，把 "<unknown ssid>" / "0x" 归一为空串。
     */
    private fun cleanSsid(raw: String?): String {
        var s = raw ?: ""
        if (s.startsWith("\"") && s.endsWith("\"") && s.length >= 2) {
            s = s.substring(1, s.length - 1)
        }
        if (s == "<unknown ssid>" || s == "0x" || s == "0x00" || s.isEmpty()) return ""
        return s
    }

    /**
     * 由 IPv4 前缀长度推导点分十进制子网掩码，例如 24 -> 255.255.255.0。
     */
    private fun prefixToMask(prefix: Int): String {
        val p = prefix.coerceIn(0, 32)
        val mask = if (p == 0) 0 else (0xFFFFFFFF.toInt() shl (32 - p))
        val a = (mask ushr 24) and 0xFF
        val b = (mask shr 16) and 0xFF
        val c = (mask shr 8) and 0xFF
        val d = mask and 0xFF
        return "$a.$b.$c.$d"
    }

    /**
     * 申请读取 WiFi 名称(SSID)所需的定位权限。
     *  - Android 13+：已通过 NEARBY_WIFI_DEVICES 获得 SSID 读取能力，无需定位，直接返回 true。
     *  - Android 10–12：SSID 需要 ACCESS_FINE_LOCATION，此处发起一次性授权请求，
     *    授权结果通过 onRequestPermissionsResult 异步回传给挂起的 MethodChannel 调用。
     */
    private fun requestWifiLocationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= 33) {
            result.success(true)
            return
        }
        val perm = Manifest.permission.ACCESS_FINE_LOCATION
        if (ContextCompat.checkSelfPermission(this, perm)
            == PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
        } else {
            pendingLocationResult = result
            ActivityCompat.requestPermissions(this, arrayOf(perm), rcWifiLocation)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == rcWifiLocation) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingLocationResult?.success(granted)
            pendingLocationResult = null
        }
    }

    /**
     * 通过系统 DownloadManager 下载 APK，下载完成后自动拉起系统安装器。
     * 需要 AndroidManifest 中声明 REQUEST_INSTALL_PACKAGES 权限
     * （Android 8+ 首次会引导用户在设置中允许“安装未知应用”）。
     */
    private fun downloadAndInstall(url: String, result: MethodChannel.Result) {
        try {
            val dm = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
            val request = DownloadManager.Request(Uri.parse(url)).apply {
                setTitle("EverLink 更新")
                setDescription("正在下载最新版本…")
                setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
                setDestinationInExternalFilesDir(
                    applicationContext,
                    Environment.DIRECTORY_DOWNLOADS,
                    "everlink-update.apk"
                )
                setMimeType("application/vnd.android.package-archive")
            }
            val id = dm.enqueue(request)

            installReceiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context?, intent: Intent?) {
                    val receivedId =
                        intent?.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1L) ?: -1L
                    if (receivedId != id) return
                    try {
                        val query = DownloadManager.Query().setFilterById(id)
                        val cursor = dm.query(query)
                        if (cursor.moveToFirst()) {
                            val status = cursor.getInt(
                                cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS)
                            )
                            if (status == DownloadManager.STATUS_SUCCESSFUL) {
                                val apkUri = dm.getUriForDownloadedFile(id)
                                val installIntent = Intent(Intent.ACTION_VIEW).apply {
                                    setDataAndType(
                                        apkUri,
                                        "application/vnd.android.package-archive"
                                    )
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                }
                                applicationContext.startActivity(installIntent)
                            } else {
                                this@MainActivity.showInstallToast("更新包下载失败")
                            }
                        }
                        cursor.close()
                    } catch (e: Exception) {
                        this@MainActivity.showInstallToast("更新失败：${e.message}")
                    }
                    installReceiver?.let { applicationContext.unregisterReceiver(it) }
                    installReceiver = null
                }
            }
            applicationContext.registerReceiver(
                installReceiver,
                IntentFilter(DownloadManager.ACTION_DOWNLOAD_COMPLETE),
                Context.RECEIVER_NOT_EXPORTED
            )
            // 下载已发起，立即回执；真正的安装会在下载完成后由广播接收器拉起。
            result.success(true)
        } catch (e: Exception) {
            result.error("DL", "下载失败：${e.message}", null)
        }
    }

    private fun showInstallToast(msg: String) {
        android.widget.Toast
            .makeText(applicationContext, msg, android.widget.Toast.LENGTH_LONG)
            .show()
    }

    override fun onDestroy() {
        releaseLock()
        installReceiver?.let {
            try {
                applicationContext.unregisterReceiver(it)
            } catch (_: Exception) {
            }
        }
        installReceiver = null
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "everlink/lan"
        private const val INSTALLER_CHANNEL = "everlink/installer"
    }
}
