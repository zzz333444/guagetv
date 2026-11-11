// Bridging header: exposes the CPython C API to Swift directly.
//
// Why not `import Python`: BeeWare's Python.framework ships its module
// map as Headers/module.modulemap declaring a plain (non-framework)
// module, which Swift's dependency scanner does not resolve through
// framework search paths (CI runs #29/#32 both failed there). The
// header route — HEADER_SEARCH_PATHS onto the framework's Headers
// directory — is the mechanism Kivy-style embeddings have always used
// and does not depend on module-map discovery at all.
#ifndef GuageTV_Bridging_Header_h
#define GuageTV_Bridging_Header_h

#include <Python.h>

#endif
