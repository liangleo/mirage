package app.mirage.net

/** Debug-only stand-in for AOA on an emulator, backed by adb reverse to port 7777. */
class FakeUsbStreamConnection : StreamConnection {
    private val tcp = TcpStreamConnection("127.0.0.1", 7777)

    override val input = tcp.input
    override val output = tcp.output

    override fun prepareRead() = tcp.prepareRead()

    override fun close() = tcp.close()
}