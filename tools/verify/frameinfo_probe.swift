// 验证 SCStreamFrameInfo 是否提供脏矩形等信息（决定静止画面如何跳过编码）。
import ScreenCaptureKit

print("dirtyRects:", SCStreamFrameInfo.dirtyRects.rawValue)
print("contentRect:", SCStreamFrameInfo.contentRect.rawValue)
print("boundingRect:", SCStreamFrameInfo.boundingRect.rawValue)
print("status:", SCStreamFrameInfo.status.rawValue)
print("RESULT=OK")