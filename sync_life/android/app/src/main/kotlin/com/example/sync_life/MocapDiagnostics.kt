package com.example.sync_life

import org.json.JSONObject
import java.io.File

/** USB/debug-only synthetic numerical smoke test. Never records or uploads data. */
internal object MocapDiagnostics {
    fun run(inference: MocapInference, drift: MocapDriftModel, output: File) {
        val report=JSONObject().put("synthetic_only",true)
        try {
            val prepareStart=System.nanoTime()
            inference.prepare(); drift.prepare(); inference.reset()
            report.put("prepare_ms",(System.nanoTime()-prepareStart)/1e6)
            val input=FloatArray(120)
            for(sensor in 0..9) for(axis in 0..2) input[30+sensor*9+axis*4]=1f
            val times=mutableListOf<Double>()
            repeat(23) { frame ->
                val start=System.nanoTime()
                val pose=inference.infer(input,optimize=true)
                check(pose.size==72 && pose.all{it.isFinite()})
                if(frame>=3) times.add((System.nanoTime()-start)/1e6)
            }
            val history=FloatArray(256*120) { input[it%120] }
            val start=System.nanoTime()
            val correction=drift.infer(history)
            report.put("drift_ms",(System.nanoTime()-start)/1e6)
            report.put("pipeline_mean_ms",times.average())
            report.put("pipeline_max_ms",times.maxOrNull())
            report.put("physics_optimized_frames",inference.physics.optimizedFrames)
            report.put("physics_rejected_frames",inference.physics.rejectedFrames)
            report.put("drift_values_finite",correction.all{it.isFinite()})
            check(inference.physics.rejectedFrames==0)
            report.put("passed",true)
        } catch(error: Throwable) {
            report.put("passed",false).put("error",error.javaClass.simpleName+": "+error.message)
        } finally {
            inference.reset()
            output.writeText(report.toString())
        }
    }
}
