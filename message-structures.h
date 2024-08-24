#include <mach/mach.h>

typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t port_descriptors[2];
} MachIOSurfaceSetupMessage;

typedef struct {
    mach_msg_header_t header;
    int surfaceIndex;
} MachIOSurfaceSwapMessage;
