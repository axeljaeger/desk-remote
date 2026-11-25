#include <sys/ioctl.h>
#include "ExclusivePort.h"

int tab5_serial_exclusive(int descriptor)
{
    return ioctl(descriptor, TIOCEXCL);
}
