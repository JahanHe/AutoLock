#include "lowlevel.h"
#include <IOKit/pwr_mgt/IOPMLib.h>

int wakeDisplay(void)
{
    static IOPMAssertionID assertionID;
    return IOPMAssertionDeclareUserActivity(CFSTR("AutoLock"), kIOPMUserActiveLocal, &assertionID);
}

// 系统亮度服务支持内置及部分 Apple 显示器；不支持的外接屏明确返回错误。
// 动态查找避免私有接口缺失时整个应用无法启动。
#include <dlfcn.h>
static void *brightnessService(void) {
    static void *service;
    if (!service) service = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL);
    return service;
}
int getDisplayBrightness(uint32_t display, float *value) {
    void *service = brightnessService();
    int (*get)(uint32_t, float *) = service ? dlsym(service, "DisplayServicesGetBrightness") : NULL;
    return get ? get(display, value) : kIOReturnUnsupported;
}
int setDisplayBrightness(uint32_t display, float value) {
    if (!(value >= 0 && value <= 1)) return kIOReturnBadArgument;
    void *service = brightnessService();
    int (*set)(uint32_t, float) = service ? dlsym(service, "DisplayServicesSetBrightness") : NULL;
    return set ? set(display, value) : kIOReturnUnsupported;
}
