#include "lowlevel.h"
#include <IOKit/pwr_mgt/IOPMLib.h>

int wakeDisplay(void)
{
    static IOPMAssertionID assertionID;
    return IOPMAssertionDeclareUserActivity(CFSTR("AutoLock"), kIOPMUserActiveLocal, &assertionID);
}
