package app.mirage.video

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AnnexBTest {
    private fun bytes(vararg values: Int): ByteArray = ByteArray(values.size) { values[it].toByte() }

    private fun start4(): ByteArray = bytes(0, 0, 0, 1)

    @Test
    fun extractsSpsAndPpsFromFourByteStartCodes() {
        val sps = bytes(0x67, 0x42, 0x00, 0x1f)
        val pps = bytes(0x68, 0xce, 0x3c)
        val idr = bytes(0x65, 0x88, 0x84)

        val stream = start4() + sps + start4() + pps + start4() + idr
        val (extractedSps, extractedPps) = AnnexB.parameterSets(stream)

        assertArrayEquals(sps, extractedSps)
        assertArrayEquals(pps, extractedPps)
    }

    @Test
    fun returnsNullsWhenNoParameterSets() {
        val stream = start4() + bytes(0x65, 0x88, 0x84)
        val (sps, pps) = AnnexB.parameterSets(stream)

        assertNull(sps)
        assertNull(pps)
    }
}