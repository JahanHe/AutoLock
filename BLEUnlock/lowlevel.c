#include "lowlevel.h"
#include <IOKit/pwr_mgt/IOPMLib.h>

void wakeDisplay(void)
{
    static IOPMAssertionID assertionID;
    IOPMAssertionDeclareUserActivity(CFSTR("BLEUnlock"), kIOPMUserActiveLocal, &assertionID);
}
