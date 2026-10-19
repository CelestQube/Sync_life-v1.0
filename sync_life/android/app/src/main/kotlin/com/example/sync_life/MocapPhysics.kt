package com.example.sync_life

import kotlin.math.*

/** Matrix operations use doubles; the model boundary remains float32. */
internal object MocapMath {
    fun eye() = doubleArrayOf(1.0,0.0,0.0,0.0,1.0,0.0,0.0,0.0,1.0)
    fun transpose(a: DoubleArray) = DoubleArray(9) { a[(it % 3) * 3 + it / 3] }
    fun mul(a: DoubleArray, b: DoubleArray) = DoubleArray(9) { i ->
        val r = i / 3; val c = i % 3
        a[r*3]*b[c] + a[r*3+1]*b[c+3] + a[r*3+2]*b[c+6]
    }
    fun rotate(a: DoubleArray, v: DoubleArray) = DoubleArray(3) { i ->
        a[i*3]*v[0] + a[i*3+1]*v[1] + a[i*3+2]*v[2]
    }
    fun cross(a: DoubleArray, b: DoubleArray) = doubleArrayOf(
        a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0])
    fun normalize(a: DoubleArray): DoubleArray {
        val n = sqrt(a.sumOf { it*it }); require(n > 1e-10 && n.isFinite())
        return DoubleArray(a.size) { a[it]/n }
    }
    fun r6(a: DoubleArray): DoubleArray {
        val x = normalize(a.copyOfRange(0,3)); val t = a.copyOfRange(3,6)
        val dot = (0..2).sumOf { x[it]*t[it] }
        val y = normalize(DoubleArray(3) { t[it]-dot*x[it] }); val z = cross(x,y)
        return doubleArrayOf(x[0],y[0],z[0],x[1],y[1],z[1],x[2],y[2],z[2])
    }
    fun axis(a: DoubleArray): DoubleArray {
        val angle = sqrt(a.sumOf { it*it }); if (angle < 1e-10) return eye()
        val x=a[0]/angle; val y=a[1]/angle; val z=a[2]/angle
        val c=cos(angle); val s=sin(angle); val v=1-c
        return doubleArrayOf(c+x*x*v,x*y*v-z*s,x*z*v+y*s,
            y*x*v+z*s,c+y*y*v,y*z*v-x*s,z*x*v-y*s,z*y*v+x*s,c+z*z*v)
    }
    fun toAxis(r: DoubleArray): DoubleArray {
        // Quaternion conversion is stable close to both zero and pi.
        val q = DoubleArray(4)
        val trace = r[0]+r[4]+r[8]
        if (trace > 0) {
            val s=sqrt(trace+1)*2; q[0]=s/4; q[1]=(r[7]-r[5])/s; q[2]=(r[2]-r[6])/s; q[3]=(r[3]-r[1])/s
        } else {
            val i=if(r[0]>r[4] && r[0]>r[8]) 0 else if(r[4]>r[8]) 1 else 2
            val j=(i+1)%3; val k=(i+2)%3
            val s=sqrt(max(1+r[i*3+i]-r[j*3+j]-r[k*3+k], 1e-15))*2
            q[i+1]=s/4; q[0]=(r[k*3+j]-r[j*3+k])/s
            q[j+1]=(r[j*3+i]+r[i*3+j])/s; q[k+1]=(r[k*3+i]+r[i*3+k])/s
        }
        if(q[0]<0) for(i in q.indices) q[i] = -q[i]
        val n=sqrt(q[1]*q[1]+q[2]*q[2]+q[3]*q[3])
        val scale=if(n<1e-10) 2.0 else 2*atan2(n,q[0])/n
        return doubleArrayOf(q[1]*scale,q[2]*scale,q[3]*scale)
    }
    fun euler(a: DoubleArray): DoubleArray {
        val cx=cos(a[0]); val sx=sin(a[0]); val cy=cos(a[1]); val sy=sin(a[1]); val cz=cos(a[2]); val sz=sin(a[2])
        return doubleArrayOf(cy*cz,-cy*sz,sy,cx*sz+sx*sy*cz,cx*cz-sx*sy*sz,-sx*cy,
            sx*sz-cx*sy*cz,sx*cz+cx*sy*sz,cx*cy)
    }
    fun toEuler(r: DoubleArray): DoubleArray {
        val b=asin(r[2].coerceIn(-1.0,1.0))
        return if(abs(cos(b)) > 1e-7) doubleArrayOf(atan2(-r[5],r[8]),b,atan2(-r[1],r[0]))
        else doubleArrayOf(atan2(r[7],r[4]),b,0.0)
    }
    fun wrap(value: Double) = ((value + PI) % (2*PI) + 2*PI) % (2*PI) - PI
}

/** Mobile port of mos/MotionOptimizer: anatomical-axis remapping, joint DOF
 * projection, Jacobian velocity fitting and 0.6/0.4 temporal integration.
 * Its QP has only a positive definite quadratic objective (no inequalities),
 * so Cholesky solves the same regularized system without a desktop QP library.
 * This is a kinematic optimizer, not a rigid-body collision/contact simulator.
 */
class MocapPhysics {
    private val parents=intArrayOf(-1,0,0,0,1,2,3,4,5,6,7,8,9,9,9,12,13,14,16,17,18,19,20,21)
    private val local = arrayOf(
        doubleArrayOf(0.0,0.0,0.0), doubleArrayOf(58.5813,-82.2800,-17.6641),doubleArrayOf(-60.3097,-90.5133,-13.5425),
        doubleArrayOf(4.4394,124.4036,-38.3852),doubleArrayOf(43.4514,-386.4695,8.0370),doubleArrayOf(-43.2566,-383.6879,-4.8430),
        doubleArrayOf(4.4884,137.9564,26.8203),doubleArrayOf(-14.7903,-426.8745,-37.4280),doubleArrayOf(19.0555,-420.0456,-34.5617),
        doubleArrayOf(-2.2646,56.0324,2.8550),doubleArrayOf(41.0544,-60.2859,122.0424),doubleArrayOf(-34.8399,-62.1055,130.3233),
        doubleArrayOf(-13.3902,211.6355,-33.4676),doubleArrayOf(71.7025,113.9997,-18.8982),doubleArrayOf(-82.9537,112.4724,-23.7074),
        doubleArrayOf(10.1132,88.9373,50.4099),doubleArrayOf(122.9214,45.2051,-19.0460),doubleArrayOf(-113.2283,46.8532,-8.4721),
        doubleArrayOf(255.3319,-15.6490,-22.9465),doubleArrayOf(-260.1275,-14.3692,-31.2687),
        doubleArrayOf(265.7092,12.6981,-7.3747),doubleArrayOf(-269.1084,6.7937,-6.0268),
        doubleArrayOf(86.6905,-10.6360,-15.5943),doubleArrayOf(-88.7537,-8.6516,-10.1071))
    private val a2w=Array(24) { MocapMath.eye() }
    private var q: DoubleArray?=null
    private var previousVelocity=DoubleArray(75)
    var optimizedFrames=0; private set
    var rejectedFrames=0; private set
    init {
        val rotations=arrayOf(doubleArrayOf(7.75,-3.24,6.71),doubleArrayOf(7.75,3.24,-6.71),
            doubleArrayOf(-5.69,-1.23,-.33),doubleArrayOf(-5.69,1.23,.33))
        intArrayOf(18,19,4,5).forEachIndexed { i,j -> a2w[j]=MocapMath.euler(DoubleArray(3) { rotations[i][it]*PI/180 }) }
        for(j in 0..23) local[j]=MocapMath.rotate(a2w[j],DoubleArray(3) { local[j][it]/1000 })
    }
    fun reset() { q=null; previousVelocity=DoubleArray(75); optimizedFrames=0; rejectedFrames=0 }
    private fun global(rot: Array<DoubleArray>): Array<DoubleArray> {
        val result=Array(24) { MocapMath.eye() }
        for(j in 0..23) result[j]=if(parents[j]<0) rot[j] else MocapMath.mul(result[parents[j]],rot[j])
        return result
    }
    private fun remap(rot: Array<DoubleArray>, toSmpl: Boolean): Array<DoubleArray> {
        val g=global(rot)
        val mapped=Array(24) { j -> MocapMath.mul(g[j],if(toSmpl) a2w[j] else MocapMath.transpose(a2w[j])) }
        return Array(24) { j -> if(parents[j]<0) mapped[j] else MocapMath.mul(MocapMath.transpose(mapped[parents[j]]),mapped[j]) }
    }
    fun optimize(pose: FloatArray, velocity: FloatArray, dt: Double=1.0/30): FloatArray {
        require(pose.size==72 && velocity.size==72 && pose.all{it.isFinite()} && velocity.all{it.isFinite()})
        try {
            val original=Array(24) { j -> MocapMath.axis(DoubleArray(3) { pose[j*3+it].toDouble() }) }
            val rotations=remap(original,false)
            // Match the Python half-transfer of removed knee/elbow twist.
            val constrained=rotations.map { it.copyOf() }.toTypedArray()
            intArrayOf(4,5,18,19).forEachIndexed { i,j ->
                val r=constrained[j]
                val fixed=MocapMath.r6(doubleArrayOf(r[0],0.0,r[6],r[1],r[4],r[7]))
                val half=MocapMath.toAxis(MocapMath.mul(r,MocapMath.transpose(fixed)))
                val parent=intArrayOf(1,2,16,17)[i]
                constrained[parent]=MocapMath.mul(constrained[parent],MocapMath.axis(DoubleArray(3) { half[it]/2 }))
                constrained[j]=fixed
            }
            val reference=DoubleArray(75)
            for(j in 0..23) { val angles=MocapMath.toEuler(constrained[j]); for(a in 0..2) reference[3+j*3+a]=angles[a] }
            val previous=q
            if(previous==null || dt !in .005..0.25) { q=reference; previousVelocity=DoubleArray(75); return output(constrained) }
            val g=global(constrained)
            val positions=Array(24) { DoubleArray(3) }
            for(j in 1..23) {
                val offset=MocapMath.rotate(g[parents[j]],local[j])
                positions[j]=DoubleArray(3) { positions[parents[j]][it]+offset[it] }
            }
            val jacobian=Array(72) { DoubleArray(75) }
            for(j in 0..23) {
                for(a in 0..2) jacobian[j*3+a][a]=1.0
                var ancestor=parents[j]
                while(ancestor>=0) {
                    val radius=DoubleArray(3) { positions[j][it]-positions[ancestor][it] }
                    for(a in 0..2) {
                        if(ancestor in intArrayOf(4,5,18,19) && a==2) continue
                        // Preserve the supplied SMPLight Jacobian axis convention.
                        val tangent=MocapMath.cross(g[j].copyOfRange(a*3,a*3+3),radius)
                        for(k in 0..2) jacobian[j*3+k][3+ancestor*3+a]=tangent[k]
                    }
                    ancestor=parents[ancestor]
                }
            }
            val matrix=Array(75) { DoubleArray(75) }; val rhs=DoubleArray(75)
            for(i in 0..74) {
                rhs[i]=(0..71).sumOf { jacobian[it][i]*velocity[it] }
                for(j in 0..i) {
                    var sum=(0..71).sumOf { jacobian[it][i]*jacobian[it][j] }
                    if(i==j) sum+=.01
                    matrix[i][j]=sum; matrix[j][i]=sum
                }
            }
            val nextVelocity=solvePositive(matrix,rhs)
            check(nextVelocity.all{it.isFinite()} && sqrt(nextVelocity.sumOf{it*it})<10000)
            val next=DoubleArray(75) { i ->
                val delta=if(i<3) reference[i]-previous[i] else MocapMath.wrap(reference[i]-previous[i])
                val value=previous[i]+(.6*previousVelocity[i]+.4*delta/dt)*dt
                if(i<3) value else MocapMath.wrap(value)
            }
            val output=output(Array(24) { j -> MocapMath.euler(next.copyOfRange(3+j*3,6+j*3)) })
            q=next; previousVelocity=nextVelocity; optimizedFrames++
            return output
        } catch (_: IllegalArgumentException) { rejectedFrames++; resetState(); return pose.copyOf() }
        catch (_: IllegalStateException) { rejectedFrames++; resetState(); return pose.copyOf() }
    }
    private fun output(rotations: Array<DoubleArray>): FloatArray {
        val result=remap(rotations,true)
        val output=FloatArray(72)
        for(j in 0..23) { val a=MocapMath.toAxis(result[j]); for(k in 0..2) output[j*3+k]=a[k].toFloat() }
        check(output.all{it.isFinite()})
        for(i in 21..26) output[i]=0f
        return output
    }
    private fun resetState() { q=null; previousVelocity=DoubleArray(75) }
    private fun solvePositive(a: Array<DoubleArray>, b: DoubleArray): DoubleArray {
        val n=b.size; val l=Array(n) { DoubleArray(n) }
        for(i in 0 until n) for(j in 0..i) {
            var sum=a[i][j]
            for(k in 0 until j) sum-=l[i][k]*l[j][k]
            if(i==j) { check(sum>1e-12); l[i][j]=sqrt(sum) } else l[i][j]=sum/l[j][j]
        }
        val y=DoubleArray(n); val x=DoubleArray(n)
        for(i in 0 until n) { var s=b[i]; for(k in 0 until i) s-=l[i][k]*y[k]; y[i]=s/l[i][i] }
        for(i in n-1 downTo 0) { var s=y[i]; for(k in i+1 until n) s-=l[k][i]*x[k]; x[i]=s/l[i][i] }
        return x
    }
}
