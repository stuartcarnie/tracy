#include "../common/TracyAlloc.hpp"
#include "../common/TracySystem.hpp"
#include "TracyCallstack.hpp"
#include "TracyDebug.hpp"
#include "TracyStringHelpers.hpp"

#ifdef TRACY_HAS_CALLSTACK
#  if TRACY_HAS_CALLSTACK == 4

#    import <Block.h>

#    include <cxxabi.h>
#    include <dlfcn.h>
#    include <mach-o/dyld.h>
#    include <mach-o/loader.h>
#    include <mach/mach.h>
#    include <mach/mach_time.h>
#    include <mach/machine.h>
#    include <pthread.h>

#    include <algorithm>
#    include <atomic>
#    include <cstring>
#    include <memory>
#    include <mutex>
#    include <string>
#    include <unordered_map>
#    include <vector>

namespace tracy
{

extern "C" const char* ___tracy_demangle( const char* mangled );

#    ifndef TRACY_DEMANGLE
constexpr size_t ___tracy_demangle_buffer_len = 1024 * 1024;
static char* ___tracy_demangle_buffer = nullptr;

void ___tracy_init_demangle_buffer()
{
    ___tracy_demangle_buffer = (char*)tracy_malloc( ___tracy_demangle_buffer_len );
}

void ___tracy_free_demangle_buffer()
{
    tracy_free( ___tracy_demangle_buffer );
    ___tracy_demangle_buffer = nullptr;
}

extern "C" const char* ___tracy_demangle( const char* mangled )
{
    if( !mangled || mangled[0] != '_' ) return nullptr;
    if( !___tracy_demangle_buffer ) return nullptr;
    if( strlen( mangled ) > ___tracy_demangle_buffer_len ) return nullptr;
    int status;
    size_t len = ___tracy_demangle_buffer_len;
    return abi::__cxa_demangle( mangled, ___tracy_demangle_buffer, &len, &status );
}
#    endif

namespace
{

struct CSTypeRef
{
    uintptr_t opaque1;
    uintptr_t opaque2;
};

typedef CSTypeRef CSSymbolicatorRef;
typedef CSTypeRef CSSymbolOwnerRef;
typedef CSTypeRef CSSymbolRef;
typedef CSTypeRef CSSourceInfoRef;

static const CSTypeRef kCSNull = { 0, 0 };

struct CSArchitecture
{
    cpu_type_t cpuType;
    cpu_subtype_t cpuSubtype;
};

struct CSRange
{
    vm_address_t location;
    vm_size_t length;
};

using CSSymbolOwnerIterator = void ( ^)( CSSymbolOwnerRef owner );

typedef uint64_t CSMachineTime;
static const CSMachineTime kCSBeginningOfTime = 0;
static const CSMachineTime kCSAllTimes = ( 1ull << 63 ) + 1;

struct CoreSymbolicationApi
{
    void* coreSymbolHandle = nullptr;
    void* crashReporterHandle = nullptr;
    bool loaded = false;

    CSArchitecture ( *CSArchitectureGetArchitectureForName )( const char* ) = nullptr;
    CSSymbolicatorRef ( *CSSymbolicatorCreateWithPathAndArchitecture )( const char*, CSArchitecture ) = nullptr;
    CSMachineTime ( *CSSymbolicatorForeachSymbolOwnerAtTime )( CSSymbolicatorRef, CSMachineTime, CSSymbolOwnerIterator ) = nullptr;
    CSSymbolRef ( *CSSymbolicatorGetSymbolWithAddressAtTime )( CSSymbolicatorRef, vm_address_t, CSMachineTime ) = nullptr;
    CSSymbolOwnerRef ( *CSSymbolicatorGetSymbolOwnerWithAddressAtTime )( CSSymbolicatorRef, vm_address_t, CSMachineTime ) = nullptr;
    CSSymbolRef ( *CSSymbolOwnerGetSymbolWithAddress )( CSSymbolOwnerRef, vm_address_t ) = nullptr;
    CSSymbolOwnerRef ( *CSSymbolicatorGetSymbolOwner )( CSSymbolicatorRef ) = nullptr;
    vm_address_t ( *CSSymbolOwnerGetBaseAddress )( CSSymbolOwnerRef ) = nullptr;
    CSSourceInfoRef ( *CSSymbolOwnerGetSourceInfoWithAddress )( CSSymbolOwnerRef, vm_address_t ) = nullptr;
    const char* ( *CSSymbolGetName )( CSSymbolRef ) = nullptr;
    const char* ( *CSSymbolGetMangledName )( CSSymbolRef ) = nullptr;
    CSRange ( *CSSymbolGetRange )( CSSymbolRef ) = nullptr;
    const char* ( *CSSourceInfoGetPath )( CSSourceInfoRef ) = nullptr;
    uint32_t ( *CSSourceInfoGetLineNumber )( CSSourceInfoRef ) = nullptr;
    CSTypeRef ( *CSRetain )( CSTypeRef ) = nullptr;
    void ( *CSRelease )( CSTypeRef ) = nullptr;
    bool ( *CSIsNull )( CSTypeRef ) = nullptr;
};

static CoreSymbolicationApi g_cs;
static std::mutex g_symbolicatorMutex;

template<typename T>
static T LoadSymbol( void* handle, const char* name )
{
    return handle ? reinterpret_cast<T>( dlsym( handle, name ) ) : nullptr;
}

static bool LoadCoreSymbolication()
{
    if( g_cs.loaded ) return true;

    g_cs.coreSymbolHandle = dlopen( "/System/Library/PrivateFrameworks/CoreSymbolication.framework/CoreSymbolication", RTLD_LAZY );
    g_cs.crashReporterHandle = dlopen( "/System/Library/PrivateFrameworks/CrashReporterSupport.framework/CrashReporterSupport", RTLD_LAZY );
    if( !g_cs.coreSymbolHandle )
    {
        return false;
    }

    g_cs.CSArchitectureGetArchitectureForName = LoadSymbol<CSArchitecture ( * )( const char* )>( g_cs.coreSymbolHandle, "CSArchitectureGetArchitectureForName" );
    g_cs.CSSymbolicatorCreateWithPathAndArchitecture = LoadSymbol<CSSymbolicatorRef ( * )( const char*, CSArchitecture )>( g_cs.coreSymbolHandle, "CSSymbolicatorCreateWithPathAndArchitecture" );
    g_cs.CSSymbolicatorForeachSymbolOwnerAtTime = LoadSymbol<CSMachineTime ( * )( CSSymbolicatorRef, CSMachineTime, CSSymbolOwnerIterator )>( g_cs.coreSymbolHandle, "CSSymbolicatorForeachSymbolOwnerAtTime" );
    g_cs.CSSymbolicatorGetSymbolWithAddressAtTime = LoadSymbol<CSSymbolRef ( * )( CSSymbolicatorRef, vm_address_t, CSMachineTime )>( g_cs.coreSymbolHandle, "CSSymbolicatorGetSymbolWithAddressAtTime" );
    g_cs.CSSymbolOwnerGetSymbolWithAddress = LoadSymbol<CSSymbolRef ( * )( CSSymbolOwnerRef, vm_address_t )>( g_cs.coreSymbolHandle, "CSSymbolOwnerGetSymbolWithAddress" );
    g_cs.CSSymbolicatorGetSymbolOwnerWithAddressAtTime = LoadSymbol<CSSymbolOwnerRef ( * )( CSSymbolicatorRef, vm_address_t, CSMachineTime )>( g_cs.coreSymbolHandle, "CSSymbolicatorGetSymbolOwnerWithAddressAtTime" );
    g_cs.CSSymbolicatorGetSymbolOwner = LoadSymbol<CSSymbolOwnerRef ( * )( CSSymbolicatorRef )>( g_cs.coreSymbolHandle, "CSSymbolicatorGetSymbolOwner" );
    g_cs.CSSymbolOwnerGetBaseAddress = LoadSymbol<vm_address_t ( * )( CSSymbolOwnerRef )>( g_cs.coreSymbolHandle, "CSSymbolOwnerGetBaseAddress" );
    g_cs.CSSymbolOwnerGetSourceInfoWithAddress = LoadSymbol<CSSourceInfoRef ( * )( CSSymbolOwnerRef, vm_address_t )>( g_cs.coreSymbolHandle, "CSSymbolOwnerGetSourceInfoWithAddress" );
    g_cs.CSSymbolGetName = LoadSymbol<const char* (*)( CSSymbolRef )>( g_cs.coreSymbolHandle, "CSSymbolGetName" );
    g_cs.CSSymbolGetMangledName = LoadSymbol<const char* (*)( CSSymbolRef )>( g_cs.coreSymbolHandle, "CSSymbolGetMangledName" );
    g_cs.CSSymbolGetRange = LoadSymbol<CSRange ( * )( CSSymbolRef )>( g_cs.coreSymbolHandle, "CSSymbolGetRange" );
    g_cs.CSSourceInfoGetPath = LoadSymbol<const char* (*)( CSSourceInfoRef )>( g_cs.coreSymbolHandle, "CSSourceInfoGetPath" );
    g_cs.CSSourceInfoGetLineNumber = LoadSymbol<uint32_t ( * )( CSSourceInfoRef )>( g_cs.coreSymbolHandle, "CSSourceInfoGetLineNumber" );
    g_cs.CSRetain = LoadSymbol<CSTypeRef ( * )( CSTypeRef )>( g_cs.coreSymbolHandle, "CSRetain" );
    g_cs.CSRelease = LoadSymbol<void ( * )( CSTypeRef )>( g_cs.coreSymbolHandle, "CSRelease" );
    g_cs.CSIsNull = LoadSymbol<bool ( * )( CSTypeRef )>( g_cs.coreSymbolHandle, "CSIsNull" );

    g_cs.loaded = g_cs.CSArchitectureGetArchitectureForName && g_cs.CSSymbolicatorCreateWithPathAndArchitecture &&
                  g_cs.CSSymbolicatorGetSymbolWithAddressAtTime && g_cs.CSSymbolOwnerGetBaseAddress &&
                  g_cs.CSSymbolGetName && g_cs.CSSymbolGetMangledName && g_cs.CSRetain && g_cs.CSRelease && g_cs.CSIsNull;

    return g_cs.loaded;
}

static bool CSIsNull( CSTypeRef value )
{
    if( g_cs.CSIsNull )
    {
        return g_cs.CSIsNull( value );
    }
    return value.opaque1 == 0 && value.opaque2 == 0;
}

struct DarwinImageEntry
{
    uint64_t startAddress = 0;
    uint64_t endAddress = 0;
    uint64_t slide = 0;
    char* path = nullptr;
    char* name = nullptr;
    std::string arch;
    CSSymbolicatorRef symbolicator = kCSNull;

    ~DarwinImageEntry()
    {
        tracy_free( path );
        tracy_free( name );
        if( !CSIsNull( symbolicator ) && g_cs.CSRelease )
        {
            g_cs.CSRelease( symbolicator );
            symbolicator = kCSNull;
        }
    }
};

static std::mutex s_imageMutex;
static std::vector<std::shared_ptr<DarwinImageEntry>> s_images;
static bool s_shouldResolveSymbolsOffline = false;

enum
{
    MaxCbTrace = 64
};
static CallstackEntry cb_data[MaxCbTrace];

static char* CopyStringOwned( const char* src )
{
    if( !src ) return nullptr;
    return CopyStringFast( src );
}

static std::string DetectArchitecture( const mach_header* header )
{
    switch( header->cputype )
    {
    case CPU_TYPE_X86:
        return "i386";
    case CPU_TYPE_X86_64:
        return "x86_64";
    case CPU_TYPE_ARM:
        return "arm";
    case CPU_TYPE_ARM64:
        if( header->cpusubtype == CPU_SUBTYPE_ARM64E )
        {
            return "arm64e";
        }
        return "arm64";
    default:
        return "unknown";
    }
}

static bool ExtractTextSegment( const mach_header* header, intptr_t slide, uint64_t& start, uint64_t& end )
{
    bool is64 = header->magic == MH_MAGIC_64 || header->magic == MH_CIGAM_64;
    const uint8_t* cmdPtr = reinterpret_cast<const uint8_t*>( header ) + ( is64 ? sizeof( mach_header_64 ) : sizeof( mach_header ) );
    for( uint32_t i = 0; i < header->ncmds; i++ )
    {
        const load_command* cmd = reinterpret_cast<const load_command*>( cmdPtr );
        if( ( cmd->cmd == LC_SEGMENT_64 && is64 ) || ( cmd->cmd == LC_SEGMENT && !is64 ) )
        {
            if( is64 )
            {
                const auto* seg = reinterpret_cast<const segment_command_64*>( cmd );
                if( strcmp( seg->segname, "__TEXT" ) == 0 )
                {
                    start = uint64_t( seg->vmaddr ) + uint64_t( slide );
                    end = start + seg->vmsize;
                    return true;
                }
            }
            else
            {
                const auto* seg = reinterpret_cast<const segment_command*>( cmd );
                if( strcmp( seg->segname, "__TEXT" ) == 0 )
                {
                    start = uint64_t( seg->vmaddr ) + uint64_t( slide );
                    end = start + seg->vmsize;
                    return true;
                }
            }
        }
        cmdPtr += cmd->cmdsize;
    }
    return false;
}

static void ScanImagesLocked()
{
    const uint32_t imageCount = _dyld_image_count();
    for( uint32_t i = 0; i < imageCount; i++ )
    {
        const mach_header* header = _dyld_get_image_header( i );
        if( !header ) continue;
        const intptr_t slide = _dyld_get_image_vmaddr_slide( i );
        uint64_t start = 0;
        uint64_t end = 0;
        if( !ExtractTextSegment( header, slide, start, end ) )
        {
            continue;
        }
        bool known = false;
        for( const auto& entry : s_images )
        {
            if( entry->startAddress == start )
            {
                known = true;
                break;
            }
        }
        if( known ) continue;

        auto entry = std::make_shared<DarwinImageEntry>();
        entry->startAddress = start;
        entry->endAddress = end;
        entry->slide = uint64_t( slide );
        entry->arch = DetectArchitecture( header );
        const char* path = _dyld_get_image_name( i );
        entry->path = CopyStringOwned( path ? path : "[unknown]" );
        if( path )
        {
            const char* base = strrchr( path, '/' );
            entry->name = CopyStringOwned( base ? base + 1 : path );
        }
        else
        {
            entry->name = CopyStringOwned( "[unknown]" );
        }

        s_images.emplace_back( std::move( entry ) );
    }
}

static std::shared_ptr<DarwinImageEntry> FindImageLocked( uint64_t addr )
{
    for( auto& entry : s_images )
    {
        if( addr >= entry->startAddress && addr < entry->endAddress )
        {
            return entry;
        }
    }
    return {};
}

static std::shared_ptr<DarwinImageEntry> FindImage( uint64_t addr )
{
    std::lock_guard<std::mutex> lock( s_imageMutex );
    auto hit = FindImageLocked( addr );
    if( hit ) return hit;
    ScanImagesLocked();
    return FindImageLocked( addr );
}

static CSSymbolicatorRef EnsureSymbolicator( const std::shared_ptr<DarwinImageEntry>& image )
{
    if( CSIsNull( image->symbolicator ) )
    {
        std::lock_guard<std::mutex> lock( g_symbolicatorMutex );
        if( CSIsNull( image->symbolicator ) )
        {
            if( !LoadCoreSymbolication() || !g_cs.CSSymbolicatorCreateWithPathAndArchitecture )
            {
                return kCSNull;
            }
            CSArchitecture arch = { 0, 0 };
            if( g_cs.CSArchitectureGetArchitectureForName )
            {
                arch = g_cs.CSArchitectureGetArchitectureForName( image->arch.c_str() );
            }
            image->symbolicator = g_cs.CSSymbolicatorCreateWithPathAndArchitecture( image->path, arch );
        }
    }
    return image->symbolicator;
}

static CSSymbolOwnerRef GetSymbolOwner( CSSymbolicatorRef symbolicator )
{
    if( !g_cs.CSSymbolicatorForeachSymbolOwnerAtTime )
    {
        return kCSNull;
    }
    __block CSSymbolOwnerRef owner = kCSNull;
    const auto count = g_cs.CSSymbolicatorForeachSymbolOwnerAtTime( symbolicator, kCSAllTimes, ^( CSSymbolOwnerRef symOwner ) {
      owner = symOwner;
    } );
    if( count == 1 )
    {
        return owner;
    }
    return kCSNull;
}

struct SymbolCacheEntry
{
    char* name = nullptr;
    char* file = nullptr;
    const char* imageName = nullptr;
    uint32_t line = 0;
    uint64_t symAddr = 0;
    uint64_t symLen = 0;
};

static std::mutex s_symbolCacheMutex;
static std::unordered_map<uint64_t, SymbolCacheEntry> s_symbolCache;

static bool ResolveWithCoreSymbolication( uint64_t addr, SymbolCacheEntry& out )
{
    if( !LoadCoreSymbolication() )
    {
        return false;
    }
    auto image = FindImage( addr );
    if( !image )
    {
        return false;
    }
    auto symbolicator = EnsureSymbolicator( image );
    if( CSIsNull( symbolicator ) )
    {
        return false;
    }
    CSSymbolOwnerRef owner = GetSymbolOwner( symbolicator );
    if( CSIsNull( owner ) && g_cs.CSSymbolicatorGetSymbolOwnerWithAddressAtTime )
    {
        owner = g_cs.CSSymbolicatorGetSymbolOwnerWithAddressAtTime( symbolicator, vm_address_t( addr ), kCSBeginningOfTime );
    }
    if( CSIsNull( owner ) )
    {
        return false;
    }

    const vm_address_t base = g_cs.CSSymbolOwnerGetBaseAddress ? g_cs.CSSymbolOwnerGetBaseAddress( owner ) : 0;
    const uint64_t fileVirtualAddress = addr - image->slide;
    const uint64_t offset = fileVirtualAddress + image->slide - image->startAddress;
    const vm_address_t expectedIP = base + vm_address_t( offset );

    CSSymbolRef symbol = g_cs.CSSymbolicatorGetSymbolWithAddressAtTime ? g_cs.CSSymbolicatorGetSymbolWithAddressAtTime( symbolicator, expectedIP, kCSBeginningOfTime ) : kCSNull;
    if( CSIsNull( symbol ) && g_cs.CSSymbolOwnerGetSymbolWithAddress )
    {
        symbol = g_cs.CSSymbolOwnerGetSymbolWithAddress( owner, expectedIP );
    }
    if( CSIsNull( symbol ) )
    {
        return false;
    }

    const char* name = nullptr;
    if( g_cs.CSSymbolGetName )
    {
        name = g_cs.CSSymbolGetName( symbol );
    }
    if( !name && g_cs.CSSymbolGetMangledName )
    {
        name = g_cs.CSSymbolGetMangledName( symbol );
    }
    if( !name )
    {
        name = "[unknown]";
    }
    if( const char* demangled = ___tracy_demangle( name ) )
    {
        name = demangled;
    }

    const char* filePath = image->path ? image->path : "[unknown]";
    uint32_t line = 0;
    if( g_cs.CSSymbolOwnerGetSourceInfoWithAddress && g_cs.CSSourceInfoGetPath )
    {
        CSSourceInfoRef info = g_cs.CSSymbolOwnerGetSourceInfoWithAddress( owner, expectedIP );
        if( !CSIsNull( info ) )
        {
            if( const char* path = g_cs.CSSourceInfoGetPath( info ) )
            {
                filePath = path;
            }
            if( g_cs.CSSourceInfoGetLineNumber )
            {
                line = g_cs.CSSourceInfoGetLineNumber( info );
            }
        }
    }

    out.name = CopyStringFast( name );
    out.file = CopyStringFast( filePath );
    out.line = line;
    out.imageName = image->name ? image->name : ( image->path ? image->path : "[unknown]" );
    out.symAddr = 0;
    if( g_cs.CSSymbolGetRange )
    {
        CSRange range = g_cs.CSSymbolGetRange( symbol );
        out.symAddr = range.location + image->slide;
        out.symLen = range.length;
    }
    return true;
}

static bool ResolveWithDladdr( uint64_t addr, SymbolCacheEntry& out )
{
    Dl_info info;
    if( dladdr( reinterpret_cast<void*>( addr ), &info ) == 0 )
    {
        return false;
    }
    const char* name = info.dli_sname ? info.dli_sname : "[unknown]";
    if( const char* demangled = ___tracy_demangle( name ) )
    {
        name = demangled;
    }
    out.name = CopyStringFast( name );
    out.file = CopyStringFast( info.dli_fname ? info.dli_fname : "[unknown]" );
    out.line = 0;
    out.imageName = out.file;
    out.symAddr = info.dli_saddr ? reinterpret_cast<uint64_t>( info.dli_saddr ) : 0;
    return true;
}

static const SymbolCacheEntry* ResolveSymbol( uint64_t addr )
{
    {
        std::lock_guard<std::mutex> lock( s_symbolCacheMutex );
        auto it = s_symbolCache.find( addr );
        if( it != s_symbolCache.end() )
        {
            return &it->second;
        }
    }

    SymbolCacheEntry entry;
    bool resolved = ResolveWithCoreSymbolication( addr, entry );
    if( !resolved )
    {
        resolved = ResolveWithDladdr( addr, entry );
    }
    if( !resolved )
    {
        entry.name = CopyStringFast( "[unknown]" );
        entry.file = CopyStringFast( "[unknown]" );
        entry.line = 0;
        entry.imageName = entry.file;
        entry.symAddr = addr;
    }

    std::lock_guard<std::mutex> lock( s_symbolCacheMutex );
    auto res = s_symbolCache.emplace( addr, entry );
    if( !res.second )
    {
        tracy_free_fast( entry.name );
        tracy_free_fast( entry.file );
        return &res.first->second;
    }
    return &res.first->second;
}

} // namespace

void InitCallstack()
{
    ___tracy_init_demangle_buffer();
    std::lock_guard<std::mutex> lock( s_imageMutex );
    ScanImagesLocked();
}

void InitCallstackCritical()
{
    InitCallstack();
}

void EndCallstack()
{
    {
        std::lock_guard<std::mutex> lock( s_symbolCacheMutex );
        for( auto& kv : s_symbolCache )
        {
            tracy_free_fast( kv.second.name );
            tracy_free_fast( kv.second.file );
        }
        s_symbolCache.clear();
    }
    {
        std::lock_guard<std::mutex> lock( s_imageMutex );
        s_images.clear();
    }
    ___tracy_free_demangle_buffer();
}

CallstackSymbolData DecodeSymbolAddress( uint64_t ptr )
{
    CallstackSymbolData sym;
    const auto* entry = ResolveSymbol( ptr );
    if( entry )
    {
        sym.file = CopyString( entry->file ? entry->file : "[unknown]" );
        sym.line = entry->line;
        sym.needFree = true;
        sym.symAddr = entry->symAddr;
    }
    else
    {
        sym.file = "[unknown]";
        sym.line = 0;
        sym.needFree = false;
        sym.symAddr = ptr;
    }
    return sym;
}

const char* DecodeCallstackPtrFast( uint64_t ptr )
{
    static thread_local char ret[1024];
    const auto* entry = ResolveSymbol( ptr );
    if( entry && entry->name )
    {
        strncpy( ret, entry->name, sizeof( ret ) - 1 );
        ret[sizeof( ret ) - 1] = '\0';
    }
    else
    {
        *ret = '\0';
    }
    return ret;
}

CallstackEntryData DecodeCallstackPtr( uint64_t ptr )
{
    InitRpmalloc();

    const auto* entry = ResolveSymbol( ptr );
    cb_data[0].line = 0;
    cb_data[0].symLen = 0;
    cb_data[0].symAddr = ptr;
    const char* imageName = "[unknown]";

    if( entry )
    {
        cb_data[0].name = CopyStringFast( entry->name ? entry->name : "[unknown]" );
        cb_data[0].file = CopyStringFast( entry->file ? entry->file : "[unknown]" );
        cb_data[0].line = entry->line;
        cb_data[0].symAddr = entry->symAddr;
        cb_data[0].symLen = entry->symLen;
        if( entry->imageName ) imageName = entry->imageName;
    }
    else
    {
        cb_data[0].name = CopyStringFast( "[unknown]" );
        cb_data[0].file = CopyStringFast( "[unknown]" );
    }

    return { cb_data, 1, imageName };
}

const char* GetKernelModulePath( uint64_t )
{
    return nullptr;
}

} // namespace tracy

#  endif
#endif
