#ifndef PRIVATE_API_H
#define PRIVATE_API_H

#include <ApplicationServices/ApplicationServices.h>

/// Returns the CGWindowID for an AXUIElement.
/// This is a private API from ApplicationServices — not in any public header.
/// Needed because AXUIElement object identity is unreliable across calls;
/// CGWindowID is the stable integer that uniquely identifies a window.
AXError _AXUIElementGetWindow(AXUIElementRef element, uint32_t *identifier);

#endif
