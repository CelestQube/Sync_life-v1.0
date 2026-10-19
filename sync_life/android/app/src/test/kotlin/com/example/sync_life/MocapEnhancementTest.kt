package com.example.sync_life

import java.io.File
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class MocapEnhancementTest {
    private val root=File("../..")
    private fun floats(array: JSONArray)=FloatArray(array.length()) { array.getDouble(it).toFloat() }
    private fun fixture()=JSONObject(File(root,"test/fixtures/mocap_enhancements.json").readText())

    @Test fun optimizerMatchesOriginalDesktopObjectiveAndAxisMapping() {
        val frames=fixture().getJSONArray("physics")
        val optimizer=MocapPhysics()
        for(i in 0 until frames.length()) {
            val frame=frames.getJSONObject(i)
            val result=optimizer.optimize(floats(frame.getJSONArray("pose")),floats(frame.getJSONArray("velocity")))
            val expected=floats(frame.getJSONArray("expected"))
            assertArrayEquals("desktop reference frame $i",expected,result,0.001f)
        }
        assertEquals(0,optimizer.rejectedFrames)
        assertEquals(frames.length()-1,optimizer.optimizedFrames)
        optimizer.reset()
        val first=frames.getJSONObject(0)
        assertArrayEquals(floats(first.getJSONArray("expected")),
            optimizer.optimize(floats(first.getJSONArray("pose")),floats(first.getJSONArray("velocity"))),0.001f)
    }

    @Test fun originalDriftModelMatchesPythonFloat32Output() {
        val data=fixture().getJSONObject("drift")
        MocapDriftModel { File(root,"android/app/src/main/assets/mocap/TIC4Clothes_dense.onnx").readBytes() }.use { model ->
            val result=model.infer(floats(data.getJSONArray("history")))
            assertArrayEquals(floats(data.getJSONArray("prediction")),result,0.0001f)
            assertEquals(120,result.size)
        }
    }

    @Test fun boundedRuntimeAndTimeGapResetDoNotCreateNonfinitePoses() {
        val optimizer=MocapPhysics(); val pose=FloatArray(72); val velocity=FloatArray(72)
        val start=System.nanoTime()
        repeat(200) { frame ->
            pose[3]=(kotlin.math.sin(frame*.1)*.3).toFloat()
            pose[6]= -pose[3]
            val result=optimizer.optimize(pose,velocity)
            assertTrue(result.all{it.isFinite()})
        }
        println("physics mean ms="+(System.nanoTime()-start)/200.0/1e6)
        assertArrayEquals(MocapPhysics().optimize(pose,velocity),optimizer.optimize(pose,velocity,dt=1.0),0f)
    }
}
