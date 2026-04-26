//
//          Tracy profiler
//         ----------------
//
// For fast integration, compile and
// link with this source file (and none
// other) in your executable (or in the
// main DLL / shared object on multi-DLL
// projects).
//

// Define TRACY_ENABLE to enable profiler.

#include "common/TracySystem.cpp"

#ifdef TRACY_ENABLE

#ifdef _MSC_VER
#  pragma warning(push, 0)
#endif

#include "common/tracy_lz4.cpp"
#include "client/TracyProfiler.cpp"
#if defined __APPLE__
#  include "client/TracyCallstack_darwin.mm"
#else
#  include "client/TracyCallstack.cpp"
#endif
#include "client/TracySysPower.cpp"
#include "client/TracySysTime.cpp"
#if defined __APPLE__
#  include "client/TracySysTrace_darwin.cpp"
#else
#  include "client/TracySysTrace.cpp"
#endif
#include "common/TracySocket.cpp"
#include "client/tracy_rpmalloc.cpp"
#include "client/TracyDxt1.cpp"
#include "client/TracyAlloc.cpp"
#include "client/TracyOverride.cpp"
#include "client/TracyKCore.cpp"

#ifdef TRACY_ROCPROF
#  include "client/TracyRocprof.cpp"
#endif
#ifdef _MSC_VER
#  pragma comment(lib, "ws2_32.lib")
#  pragma comment(lib, "advapi32.lib")
#  pragma comment(lib, "user32.lib")
#  pragma warning(pop)
#endif

#endif
