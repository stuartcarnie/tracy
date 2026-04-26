#include "../common/TracySystem.hpp"
#include "TracyDebug.hpp"
#include "TracyStringHelpers.hpp"
#include "TracySysTrace.hpp"

#ifdef TRACY_HAS_SYSTEM_TRACING

#  if defined __APPLE__

#    include <atomic>
#    include <chrono>
#    include <libproc.h>
#    include <mach/mach.h>
#    include <mach/mach_time.h>
#    include <mach/mach_vm.h>
#    include <mach/machine/thread_state.h>
#    include <mach/thread_act.h>
#    include <mach/thread_info.h>
#    include <mach/vm_map.h>
#    include <pthread.h>
#    include <stdlib.h>
#    include <string.h>
#    include <thread>
#    include <time.h>
#    include <unistd.h>

#    include "TracyProfiler.hpp"
#    include "TracyThread.hpp"

#    ifndef TRACY_SAMPLING_HZ
#      define TRACY_SAMPLING_HZ 10000
#    endif

namespace tracy
{

static int GetSamplingFrequency()
{
    int samplingHz = TRACY_SAMPLING_HZ;

    if( const char* env = GetEnvVar( "TRACY_SAMPLING_HZ" ) )
    {
        const int val = atoi( env );
        if( val > 0 )
        {
            samplingHz = val;
        }
    }

    if( samplingHz > 1000000 )
    {
        samplingHz = 1000000;
    }
    return samplingHz;
}

static int GetSamplingPeriod()
{
    return 1000000000 / GetSamplingFrequency();
}

struct ThreadRegisters
{
    uintptr_t fp;
    uintptr_t sp;
    uintptr_t ip;
};

static constexpr size_t MaxStackDepth = 256;
static constexpr uintptr_t MaxStackDistance = 128 * 1024;

static std::atomic<bool> traceActive{ false };
static int64_t s_samplingPeriod = 0;

static uint64_t MachTimeToNs( uint64_t value )
{
    static mach_timebase_info_data_t timebase = { 0, 0 };
    if( timebase.denom == 0 )
    {
        mach_timebase_info( &timebase );
    }
    __uint128_t scaled = static_cast<__uint128_t>( value ) * static_cast<__uint128_t>( timebase.numer );
    return static_cast<uint64_t>( scaled / timebase.denom );
}

static bool WaitForThreadSuspend( thread_t thread )
{
    thread_basic_info_data_t info = {};
    mach_msg_type_number_t count = THREAD_BASIC_INFO_COUNT;
    uint32_t sleepMicros = 1;
    const uint64_t startNs = MachTimeToNs( mach_absolute_time() );
    for( ;; )
    {
        count = THREAD_BASIC_INFO_COUNT;
        if( thread_info( thread, THREAD_BASIC_INFO, reinterpret_cast<thread_info_t>( &info ), &count ) != KERN_SUCCESS )
        {
            return false;
        }

        if( info.run_state == TH_STATE_WAITING )
        {
            return true;
        }

        if( info.run_state == TH_STATE_UNINTERRUPTIBLE )
        {
            thread_abort( thread );
            continue;
        }

        usleep( sleepMicros );

        const uint64_t nowNs = MachTimeToNs( mach_absolute_time() );
        if( nowNs - startNs > 1'000'000'000ull )
        {
            return false;
        }

        sleepMicros = ( sleepMicros * 13 ) / 10 + 1;
    }
}

static bool CaptureThreadState( thread_t thread, ThreadRegisters& outRegs )
{
#    if defined __x86_64__
    x86_thread_state64_t state;
    mach_msg_type_number_t count = x86_THREAD_STATE64_COUNT;
    if( thread_get_state( thread, x86_THREAD_STATE64, (thread_state_t)&state, &count ) != KERN_SUCCESS )
    {
        return false;
    }
    outRegs.fp = state.__rbp;
    outRegs.sp = state.__rsp;
    outRegs.ip = state.__rip;
    return true;
#    elif defined __aarch64__
    arm_thread_state64_t state;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    if( thread_get_state( thread, ARM_THREAD_STATE64, (thread_state_t)&state, &count ) != KERN_SUCCESS )
    {
        return false;
    }
    outRegs.fp = (uintptr_t)arm_thread_state64_get_fp( state );
    outRegs.sp = (uintptr_t)arm_thread_state64_get_sp( state );
    outRegs.ip = (uintptr_t)arm_thread_state64_get_pc( state );
    return true;
#    else
    (void)thread;
    (void)outRegs;
    return false;
#    endif
}

static uint64_t* BuildCallstack( const ThreadRegisters& regs )
{
    if( regs.ip == 0 ) return nullptr;

    uint64_t frames[MaxStackDepth];
    size_t depth = 0;
    frames[depth++] = regs.ip;

    uintptr_t cursorFp = regs.fp;
    while( depth < MaxStackDepth )
    {
        if( cursorFp == 0 || cursorFp < regs.sp || cursorFp - regs.sp > MaxStackDistance )
        {
            break;
        }

        uintptr_t const * const as_words = (uintptr_t *)cursorFp;
        cursorFp = as_words[0];
        frames[depth++] = as_words[1]; // instruction pointer
    }

#    if defined __x86_64__
    size_t writeIdx = 1;
    for( size_t i = 1; i < depth; i++ )
    {
        const auto val = static_cast<int64_t>( frames[i] );
        const auto m1 = val >> 63;
        const auto m2 = val >> 47;
        if( m1 == m2 )
        {
            frames[writeIdx++] = frames[i];
        }
    }
    depth = writeIdx;
#    endif

    auto trace = (uint64_t*)tracy_malloc_fast( ( 1 + depth ) * sizeof( uint64_t ) );
    memcpy( trace + 1, frames, depth * sizeof( uint64_t ) );
    trace[0] = depth;
    return trace;
}

static inline ThreadRegisters get_regs() {
    ThreadRegisters regs;
    regs.ip = (uintptr_t)__builtin_return_address(0);
    regs.fp = (uintptr_t)__builtin_frame_address(0);
#if defined(__aarch64__)
    __asm__ volatile("mov %0, sp" : "=r"(regs.sp));
#elif defined(__x86_64__)
    __asm__ volatile("mov %%rsp, %0" : "=r"(regs.sp));
#else
#   error "Unsupported architecture: need __aarch64__ or __x86_64__"
#endif
    return regs;
}

int CaptureCurrentThreadBacktrace( void** addresses, int max_depth )
{
#if !defined __x86_64__ && !defined __aarch64__
    (void)addresses;
    (void)depth;
    return 0;
#else
    ThreadRegisters regs = get_regs();

    if( regs.ip == 0 ) return 0;

    size_t depth = 0;
    addresses[depth++] = (void *)regs.ip;

    uintptr_t cursorFp = regs.fp;
    while( depth < max_depth )
    {
        if( cursorFp == 0 || cursorFp < regs.sp || cursorFp - regs.sp > MaxStackDistance )
        {
            break;
        }

        uintptr_t const * const as_words = (uintptr_t *)cursorFp;
        cursorFp = as_words[0];
        addresses[depth++] = (void *)as_words[1];
    }

#    if defined __x86_64__
    size_t writeIdx = 1;
    for( size_t i = 1; i < depth; i++ )
    {
        const auto val = static_cast<int64_t>( addresses[i] );
        const auto m1 = val >> 63;
        const auto m2 = val >> 47;
        if( m1 == m2 )
        {
            addresses[writeIdx++] = addresses[i];
        }
    }
    depth = writeIdx;
#    endif
#endif
    return depth;
}


static void ReleaseThreadList( thread_act_array_t threads, mach_msg_type_number_t count )
{
    if( !threads )
    {
        return;
    }

    for( mach_msg_type_number_t i = 0; i < count; i++ )
    {
        mach_port_deallocate( mach_task_self(), threads[i] );
    }
    vm_deallocate( mach_task_self(), reinterpret_cast<vm_address_t>( threads ), count * sizeof( thread_t ) );
}

static void SampleThreads( uint64_t workerThreadId )
{
    thread_act_array_t threads = nullptr;
    mach_msg_type_number_t threadCount = 0;
    kern_return_t kret = task_threads( mach_task_self(), &threads, &threadCount );
    if( kret != KERN_SUCCESS )
    {
        return;
    }

    for( mach_msg_type_number_t i = 0; i < threadCount; i++ )
    {
        auto thread = threads[i];

        thread_identifier_info_data_t idInfo = {};
        mach_msg_type_number_t infoCount = THREAD_IDENTIFIER_INFO_COUNT;
        kret = thread_info( thread, THREAD_IDENTIFIER_INFO, reinterpret_cast<thread_info_t>( &idInfo ), &infoCount );
        if( kret != KERN_SUCCESS || idInfo.thread_id == 0 || idInfo.thread_id == workerThreadId )
        {
            continue;
        }

        if( thread_suspend( thread ) != KERN_SUCCESS )
        {
            continue;
        }

        if( !WaitForThreadSuspend( thread ) )
        {
            continue;
        }

        ThreadRegisters regs;
        const bool captured = CaptureThreadState( thread, regs );
        uint64_t *trace = nullptr;
        if (captured)
        {
            trace = BuildCallstack( regs );
        }

        thread_resume( thread );

        if( !trace )
        {
            continue;
        }

        const uint64_t sampleTime = MachTimeToNs( mach_absolute_time() );
        TracyLfqPrepare( QueueType::CallstackSample );
        MemWrite( &item->callstackSampleFat.time, sampleTime );
        MemWrite( &item->callstackSampleFat.thread, idInfo.thread_id );
        MemWrite( &item->callstackSampleFat.ptr, (uint64_t)trace );
        TracyLfqCommit;
    }

    ReleaseThreadList( threads, threadCount );
}

static uint64_t GetCurrentThreadId()
{
    thread_identifier_info_data_t info = {};
    thread_t self = mach_thread_self();
    mach_msg_type_number_t count = THREAD_IDENTIFIER_INFO_COUNT;
    uint64_t tid = 0;
    if( thread_info( self, THREAD_IDENTIFIER_INFO, reinterpret_cast<thread_info_t>( &info ), &count ) == KERN_SUCCESS )
    {
        tid = info.thread_id;
    }
    mach_port_deallocate( mach_task_self(), self );
    return tid;
}

bool SysTraceStart( int64_t& samplingPeriod )
{
#    ifdef TRACY_NO_SAMPLING
    const bool noSampling = true;
#    else
    const char* noSamplingEnv = GetEnvVar( "TRACY_NO_SAMPLING" );
    const bool noSampling = noSamplingEnv && noSamplingEnv[0] == '1';
#    endif
    if( noSampling )
    {
        return false;
    }

    samplingPeriod = GetSamplingPeriod();
    s_samplingPeriod = samplingPeriod;
    traceActive.store( true, std::memory_order_relaxed );
    return true;
}

void SysTraceStop()
{
    traceActive.store( false, std::memory_order_relaxed );
}

void SysTraceWorker( void* ptr )
{
    (void)ptr;
    ThreadExitHandler threadExitHandler;
    SetThreadName( "Tracy Sampling" );
    InitRpmalloc();

    const uint64_t workerThreadId = GetCurrentThreadId();

    while( traceActive.load( std::memory_order_relaxed ) )
    {
#    if defined(TRACY_ON_DEMAND)
        if( !GetProfiler().IsConnected() )
        {
            std::this_thread::sleep_for( std::chrono::milliseconds( 10 ) );
            continue;
        }
#    endif
        SampleThreads( workerThreadId );

        if( !traceActive.load( std::memory_order_relaxed ) )
        {
            break;
        }

        if( s_samplingPeriod > 0 )
        {
            std::this_thread::sleep_for( std::chrono::nanoseconds( s_samplingPeriod ) );
        }
        else
        {
            std::this_thread::sleep_for( std::chrono::milliseconds( 1 ) );
        }
    }
}

void SysTraceGetExternalName( uint64_t thread, const char*& threadName, const char*& name )
{
    threadName = CopyString( "???", 3 );
    name = CopyStringFast( "???", 3 );

    thread_act_array_t threads = nullptr;
    mach_msg_type_number_t threadCount = 0;
    if( task_threads( mach_task_self(), &threads, &threadCount ) != KERN_SUCCESS )
    {
        return;
    }

    bool foundThread = false;
    for( mach_msg_type_number_t i = 0; i < threadCount; i++ )
    {
        thread_identifier_info_data_t idInfo = {};
        mach_msg_type_number_t infoCount = THREAD_IDENTIFIER_INFO_COUNT;
        if( thread_info( threads[i], THREAD_IDENTIFIER_INFO, reinterpret_cast<thread_info_t>( &idInfo ), &infoCount ) != KERN_SUCCESS )
        {
            continue;
        }

        if( idInfo.thread_id != thread )
        {
            continue;
        }

        pthread_t pthread = pthread_from_mach_thread_np( threads[i] );
        if( pthread )
        {
            char buf[64] = {};
            if( pthread_getname_np( pthread, buf, sizeof( buf ) ) == 0 && buf[0] != '\0' )
            {
                threadName = CopyString( buf );
            }
        }

        foundThread = true;
        break;
    }

    ReleaseThreadList( threads, threadCount );

    const pid_t pid = getpid();
    TracyLfqPrepare( QueueType::TidToPid );
    MemWrite( &item->tidToPid.tid, thread );
    MemWrite( &item->tidToPid.pid, uint64_t( pid ) );
    TracyLfqCommit;

    char procNameBuf[PROC_PIDPATHINFO_MAXSIZE] = {};
    const int procNameLen = proc_name( pid, procNameBuf, sizeof( procNameBuf ) );
    if( procNameLen > 0 )
    {
        name = CopyStringFast( procNameBuf, procNameLen );
    }
    else
    {
        name = CopyStringFast( "???", 3 );
    }

    if( !foundThread )
    {
        threadName = CopyString( "???", 3 );
    }
}

} // namespace tracy

#  endif // defined __APPLE__

#endif // TRACY_HAS_SYSTEM_TRACING
