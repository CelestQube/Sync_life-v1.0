package com.example.sync_life

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import java.nio.FloatBuffer

/** Own all recurrent state on the channel's single inference executor. */
class MocapInference(private val loadModel: () -> ByteArray) : AutoCloseable {
    private val env by lazy { OrtEnvironment.getEnvironment() }
    private var session: OrtSession? = null
    private val stateNames = listOf("h_1", "c_1", "h_2", "c_2", "h_3", "c_3")
    private val states = stateNames.associateWith { FloatArray(512) }.toMutableMap()
    val physics = MocapPhysics()

    fun prepare() {
        if (session != null) return
        val model = loadModel()
        OrtSession.SessionOptions().use { options ->
            options.setIntraOpNumThreads(2)
            options.setInterOpNumThreads(1)
            session = env.createSession(model, options)
        }
        check(session!!.inputInfo.keys == (stateNames + "imu_data").toSet()) { "Unexpected model inputs" }
    }

    fun reset() { stateNames.forEach { states[it] = FloatArray(512) }; physics.reset() }

    fun infer(input: FloatArray, optimize: Boolean = false, dt: Double = 1.0/30): FloatArray {
        require(input.size == 120 && input.all { it.isFinite() }) { "Expected 120 finite IMU values" }
        prepare()
        val tensors = mutableMapOf<String, OnnxTensor>()
        try {
            tensors["imu_data"] = OnnxTensor.createTensor(env, FloatBuffer.wrap(input), longArrayOf(1, 120))
            stateNames.forEach { name ->
                tensors[name] = OnnxTensor.createTensor(env, FloatBuffer.wrap(states.getValue(name)), longArrayOf(2, 1, 256))
            }
            session!!.run(tensors).use { output ->
                val poseTensor = output.get("pose").get() as OnnxTensor
                val pose = FloatArray(72)
                poseTensor.floatBuffer.get(pose)
                check(pose.all { it.isFinite() }) { "Model returned invalid pose" }
                stateNames.forEach { name ->
                    val next = FloatArray(512)
                    (output.get("${name}_n").get() as OnnxTensor).floatBuffer.get(next)
                    check(next.all { it.isFinite() }) { "Model returned invalid state" }
                    states[name] = next
                }
                val result = if(optimize) {
                    val velocity=FloatArray(72)
                    (output.get("vel").get() as OnnxTensor).floatBuffer.get(velocity)
                    physics.optimize(pose,velocity,dt)
                } else pose
                for (i in 21..26) result[i] = 0f
                return result
            }
        } finally { tensors.values.forEach { it.close() } }
    }

    override fun close() { session?.close(); session = null }
}
