package app.mirage.net

import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.os.ParcelFileDescriptor
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket

interface StreamConnection {
    val input: InputStream
    val output: OutputStream

    fun prepareRead() {}

    fun close()
}

class TcpStreamConnection(host: String, port: Int) : StreamConnection {
    private val socket = Socket().apply {
        connect(InetSocketAddress(host, port), 5_000)
        tcpNoDelay = true
    }

    override val input: InputStream = socket.getInputStream()
    override val output: OutputStream = socket.getOutputStream()

    override fun prepareRead() {
        socket.soTimeout = 1_000
    }

    override fun close() {
        try {
            socket.close()
        } catch (_: Exception) {
        }
    }
}

class UsbStreamConnection(
    private val usbManager: UsbManager,
    private val accessory: UsbAccessory
) : StreamConnection {
    private val descriptor: ParcelFileDescriptor =
        usbManager.openAccessory(accessory) ?: throw IOException("USB accessory 无权限")

    override val input: InputStream = FileInputStream(descriptor.fileDescriptor)
    override val output: OutputStream = FileOutputStream(descriptor.fileDescriptor)

    override fun close() {
        try {
            input.close()
        } catch (_: Exception) {
        }
        try {
            output.close()
        } catch (_: Exception) {
        }
        try {
            descriptor.close()
        } catch (_: Exception) {
        }
    }
}