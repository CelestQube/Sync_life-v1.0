package com.example.sync_life

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var mocap: MocapChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        mocap = MocapChannel(this, flutterEngine)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == MocapChannel.PERMISSION_REQUEST) mocap?.permissionsReturned()
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        mocap?.close()
        mocap = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
