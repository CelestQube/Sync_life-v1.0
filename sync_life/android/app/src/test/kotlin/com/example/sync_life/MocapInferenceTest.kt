package com.example.sync_life

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Test
import java.io.File

class MocapInferenceTest {
    @Test fun pythonReferenceAndRecurrentReset() {
        val root = File("../..")
        val fixture = JSONObject(File(root, "test/fixtures/mocap_reference.json").readText())
        val inputArray = fixture.getJSONArray("expectedInput")
        val input = FloatArray(120) { inputArray.getDouble(it).toFloat() }
        val poses = fixture.getJSONArray("expectedPoses")
        MocapInference { File(root, "android/app/src/main/assets/mocap/LFP_dense_taichi_ft.onnx").readBytes() }.use { inference ->
            inference.prepare()
            for (frame in 0..2) {
                val expected = poses.getJSONArray(frame)
                assertArrayEquals(FloatArray(72) { expected.getDouble(it).toFloat() }, inference.infer(input), 0.0001f)
            }
            inference.reset()
            val expected = poses.getJSONArray(0)
            assertArrayEquals(FloatArray(72) { expected.getDouble(it).toFloat() }, inference.infer(input), 0.0001f)
        }
    }
}
