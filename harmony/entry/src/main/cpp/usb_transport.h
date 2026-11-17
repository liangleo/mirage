#ifndef MIRAGE_USB_TRANSPORT_H
#define MIRAGE_USB_TRANSPORT_H

#include <napi/native_api.h>

napi_value StartUsb(napi_env env, napi_callback_info info);
napi_value StopUsb(napi_env env, napi_callback_info info);
napi_value UsbWrite(napi_env env, napi_callback_info info);

#endif  // MIRAGE_USB_TRANSPORT_H