package app.mirage.video

object AnnexB {
    /** Returns (SPS, PPS) without start codes, or null when absent. */
    fun parameterSets(annexB: ByteArray): Pair<ByteArray?, ByteArray?> {
        var sps: ByteArray? = null
        var pps: ByteArray? = null
        var cursor = 0

        while (true) {
            val start = findStartCode(annexB, cursor) ?: break
            val nalStart = start + 3
            val nextStart = findStartCode(annexB, nalStart)
            var end = nextStart ?: annexB.size
            while (end > nalStart && annexB[end - 1] == 0.toByte()) {
                end--
            }
            if (nalStart < end) {
                when (annexB[nalStart].toInt() and 0x1F) {
                    7 -> sps = annexB.copyOfRange(nalStart, end)
                    8 -> pps = annexB.copyOfRange(nalStart, end)
                }
            }
            if (nextStart == null) break
            cursor = nextStart
        }

        return sps to pps
    }

    private fun findStartCode(data: ByteArray, from: Int): Int? {
        var index = from
        while (index + 2 < data.size) {
            if (data[index] == 0.toByte() &&
                data[index + 1] == 0.toByte() &&
                data[index + 2] == 1.toByte()
            ) {
                return index
            }
            index++
        }
        return null
    }
}