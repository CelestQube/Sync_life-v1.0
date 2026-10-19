package com.example.sync_life

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import java.util.concurrent.Executors

@SuppressLint("MissingPermission")
class MocapChannel(private val activity: MainActivity, engine: FlutterEngine) : AutoCloseable {
    companion object {
        const val PERMISSION_REQUEST = 7401
        val NOTIFY_UUID: UUID = UUID.fromString("adaf0101-c332-42a8-93bd-25e905756cb8")
        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }
    private val main = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private val inference = MocapInference {
        activity.applicationContext.assets.open("mocap/LFP_dense_taichi_ft.onnx").use { it.readBytes() }
    }
    private val drift = MocapDriftModel {
        activity.applicationContext.assets.open("mocap/TIC4Clothes_dense.onnx").use { it.readBytes() }
    }
    private val methods = MethodChannel(engine.dartExecutor.binaryMessenger, "sync_life/mocap")
    private val events = EventChannel(engine.dartExecutor.binaryMessenger, "sync_life/mocap_events")
    private var sink: EventChannel.EventSink? = null
    private var permissionResult: MethodChannel.Result? = null
    private val adapter get() = (activity.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
    private val links = mutableMapOf<String, Link>()
    private var scanning = false
    private var scanner: BluetoothLeScanner? = null
    private var closed = false
    private val scanTimeout = Runnable { stopScan() }

    init {
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) { sink = eventSink }
            override fun onCancel(arguments: Any?) { sink = null }
        })
        methods.setMethodCallHandler { call, result ->
            try { handle(call, result) }
            catch (error: Exception) { result.error("mocap", error.message, null) }
        }
        if(BuildConfig.DEBUG && activity.intent.getBooleanExtra("mocap_self_test",false)) {
            executor.execute { MocapDiagnostics.run(inference,drift,
                java.io.File(activity.filesDir,"mocap_diagnostics.json")) }
        }
    }

    private fun emit(event: Map<String, Any?>) { main.post { if (!closed) sink?.success(event) } }
    private fun requiredPermissions() = if (Build.VERSION.SDK_INT >= 31) {
        arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
    } else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
    private fun hasPermissions() = requiredPermissions().all { activity.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
    private fun requireBluetooth() {
        check(hasPermissions()) { "请先允许蓝牙权限" }
        check(adapter != null && adapter.isEnabled) { "请在手机设置中开启蓝牙" }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "permissions" -> {
                if (hasPermissions()) result.success(true)
                else {
                    check(permissionResult == null) { "权限请求尚未完成" }
                    permissionResult = result
                    activity.requestPermissions(requiredPermissions(), PERMISSION_REQUEST)
                }
            }
            "scan" -> { requireBluetooth(); startScan(); result.success(null) }
            "stopScan" -> { stopScan(); result.success(null) }
            "connect" -> {
                requireBluetooth()
                val role = call.argument<String>("role")!!
                val address = call.argument<String>("address")!!
                require(role == "upper" || role == "lower")
                require(BluetoothAdapter.checkBluetoothAddress(address)) { "蓝牙地址无效" }
                check(links.values.none { it.address == address && it.role != role }) { "上衣和裤子必须选择不同的设备" }
                stopScan()
                disconnect(role)
                val link = Link(role, address)
                links[role] = link
                emit(mapOf("type" to "connection", "role" to role, "state" to "connecting"))
                link.gatt = adapter.getRemoteDevice(address).connectGatt(activity, false, link.callback, BluetoothDevice.TRANSPORT_LE)
                link.armTimeout()
                result.success(null)
            }
            "disconnect" -> { disconnect(call.argument<String>("role")!!); result.success(null) }
            "prepare", "reset", "infer", "calibrateDrift" -> executor.execute {
                try {
                    val value: Any? = when (call.method) {
                        "prepare" -> { inference.prepare(); drift.prepare(); null }
                        "reset" -> { inference.reset(); null }
                        "calibrateDrift" -> drift.infer(call.argument<FloatArray>("history")!!)
                        else -> inference.infer(call.argument<FloatArray>("input")!!,
                            optimize=true, dt=call.argument<Double>("dt") ?: (1.0/30))
                    }
                    main.post { result.success(value) }
                } catch (error: Exception) {
                    main.post { result.error("inference", error.message, null) }
                }
            }
            else -> result.notImplemented()
        }
    }

    fun permissionsReturned() {
        permissionResult?.success(hasPermissions())
        permissionResult = null
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            if (!scanning) return
            emit(mapOf("type" to "device", "address" to result.device.address,
                "name" to (result.scanRecord?.deviceName ?: result.device.name ?: "未命名设备"), "rssi" to result.rssi))
        }
        override fun onScanFailed(errorCode: Int) {
            main.post { stopScan(); emit(mapOf("type" to "error", "message" to "蓝牙扫描失败：$errorCode")) }
        }
    }

    private fun startScan() {
        stopScan()
        scanner = adapter.bluetoothLeScanner ?: error("蓝牙扫描不可用")
        scanning = true
        scanner!!.startScan(null, ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), scanCallback)
        emit(mapOf("type" to "scan", "active" to true))
        main.postDelayed(scanTimeout, 10000)
    }
    private fun stopScan() {
        main.removeCallbacks(scanTimeout)
        if (scanning && hasPermissions()) scanner?.stopScan(scanCallback)
        scanning = false
        emit(mapOf("type" to "scan", "active" to false))
    }
    private fun disconnect(role: String) {
        links.remove(role)?.release()
        emit(mapOf("type" to "connection", "role" to role, "state" to "disconnected"))
    }

    private inner class Link(val role: String, val address: String) {
        var gatt: BluetoothGatt? = null
        private val timeout = Runnable { fail("连接或订阅超时，请检查衣物电源") }
        fun armTimeout() { main.removeCallbacks(timeout); main.postDelayed(timeout, 30000) }
        private fun current(g: BluetoothGatt) = !closed && links[role] === this && gatt === g
        fun release() {
            main.removeCallbacks(timeout)
            val old = gatt
            gatt = null
            try { old?.disconnect() } finally { old?.close() }
        }
        fun fail(message: String) {
            if (links[role] !== this) return
            links.remove(role)
            release()
            emit(mapOf("type" to "connection", "role" to role, "state" to "disconnected", "message" to message))
        }
        private fun discover(g: BluetoothGatt) { if (!g.discoverServices()) fail("服务发现未能启动") }
        private fun received(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray) {
            if (current(g) && c.uuid == NOTIFY_UUID) emit(mapOf("type" to "packet", "role" to role, "data" to value.copyOf()))
        }
        val callback = object : BluetoothGattCallback() {
            override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
                main.post {
                    if (!current(g)) return@post
                    if (status != BluetoothGatt.GATT_SUCCESS || newState == BluetoothProfile.STATE_DISCONNECTED) {
                        fail("蓝牙已断开（状态 $status），请重新连接并校准")
                    } else if (newState == BluetoothProfile.STATE_CONNECTED) {
                        g.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH)
                        // 217-byte payload needs ATT MTU >= 220. GATT operations are sequenced by callbacks.
                        if (!g.requestMtu(247)) fail("无法请求蓝牙 MTU，请重新连接")
                    }
                }
            }
            override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
                main.post {
                    if (!current(g)) return@post
                    if (status != BluetoothGatt.GATT_SUCCESS || mtu < 220) {
                        fail("蓝牙 MTU 为 $mtu，无法接收衣物的 217 字节数据包")
                    } else discover(g)
                }
            }
            override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
                main.post {
                    if (!current(g)) return@post
                    if (status != BluetoothGatt.GATT_SUCCESS) { fail("服务发现失败：$status"); return@post }
                    val c = g.services.flatMap { it.characteristics }.firstOrNull { it.uuid == NOTIFY_UUID }
                    if (c == null) { fail("设备没有动捕通知特征，请确认上衣/裤子选择正确"); return@post }
                    val descriptor = c.getDescriptor(CCCD_UUID)
                    if (descriptor == null || !g.setCharacteristicNotification(c, true)) { fail("无法开启数据通知"); return@post }
                    val value = if ((c.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY) != 0) {
                        BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                    } else BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
                    val started = if (Build.VERSION.SDK_INT >= 33) {
                        g.writeDescriptor(descriptor, value) == BluetoothStatusCodes.SUCCESS
                    } else {
                        @Suppress("DEPRECATION")
                        descriptor.value = value
                        @Suppress("DEPRECATION")
                        g.writeDescriptor(descriptor)
                    }
                    if (!started) fail("通知订阅未能启动")
                }
            }
            override fun onDescriptorWrite(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
                main.post {
                    if (!current(g) || descriptor.uuid != CCCD_UUID) return@post
                    if (status != BluetoothGatt.GATT_SUCCESS) { fail("通知订阅失败：$status"); return@post }
                    main.removeCallbacks(timeout)
                    emit(mapOf("type" to "connection", "role" to role, "state" to "ready"))
                }
            }
            @Deprecated("Legacy Android callback")
            override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic) {
                if (Build.VERSION.SDK_INT < 33) {
                    @Suppress("DEPRECATION")
                    val value = c.value ?: return
                    main.post { received(g, c, value) }
                }
            }
            override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray) {
                main.post { received(g, c, value) }
            }
        }
    }

    override fun close() {
        stopScan()
        links.values.toList().forEach { it.release() }
        links.clear()
        closed = true
        permissionResult?.error("closed", "页面已关闭", null)
        permissionResult = null
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        sink = null
        executor.execute { inference.close(); drift.close() }
        executor.shutdown()
    }
}
