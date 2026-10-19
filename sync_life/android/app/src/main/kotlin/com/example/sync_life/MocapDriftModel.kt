package com.example.sync_life

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import java.nio.FloatBuffer

/** Original TIC4Clothes_dense model, invoked only after sufficient rotation diversity. */
class MocapDriftModel(private val loadModel: () -> ByteArray) : AutoCloseable {
    private val env by lazy { OrtEnvironment.getEnvironment() }
    private var session: OrtSession? = null
    fun prepare() {
        if(session != null) return
        OrtSession.SessionOptions().use { options ->
            options.setIntraOpNumThreads(2); options.setInterOpNumThreads(1)
            session=env.createSession(loadModel(),options)
        }
        check(session!!.inputInfo.keys==setOf("imu_rot"))
    }
    fun infer(history: FloatArray): FloatArray {
        require(history.size==256*120 && history.all{it.isFinite()})
        prepare()
        OnnxTensor.createTensor(env,FloatBuffer.wrap(history),longArrayOf(1,256,120)).use { input ->
            session!!.run(mapOf("imu_rot" to input)).use { result ->
                val shifts=FloatArray(120)
                (result.get("global_shift").get() as OnnxTensor).floatBuffer.get(shifts,0,60)
                (result.get("local_shift").get() as OnnxTensor).floatBuffer.get(shifts,60,60)
                check(shifts.all{it.isFinite()}) { "Invalid drift correction" }
                return shifts
            }
        }
    }
    override fun close() { session?.close(); session=null }
}
