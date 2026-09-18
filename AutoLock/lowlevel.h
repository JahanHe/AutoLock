#ifndef lowlevel_h
#define lowlevel_h
#include <stdbool.h>
#include <stdint.h>

int wakeDisplay(void);
int getDisplayBrightness(uint32_t display, float *value);
int setDisplayBrightness(uint32_t display, float value);
int SACLockScreenImmediate(void);

#endif /* lowlevel_h */
