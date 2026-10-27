#include <string.h>

#include "TracyTexture.hpp"
#include "../public/common/TracyForceInline.hpp"

#import <Metal/Metal.h>
#import <TargetConditionals.h>

namespace tracy
{

static id<MTLDevice> g_device = nil;

static tracy_force_inline ImTextureID StoreTexture( id<MTLTexture> texture )
{
    return (ImTextureID)(__bridge_retained void*)texture;
}

static tracy_force_inline void ReleaseTextureId( ImTextureID tex )
{
    if( tex == ImTextureID_Invalid ) return;
    id<MTLTexture> releaseTex = (__bridge_transfer id<MTLTexture>)(void*)(intptr_t)tex;
    (void)releaseTex;
}

static tracy_force_inline id<MTLTexture> GetTexture( ImTextureID tex )
{
    return tex == ImTextureID_Invalid ? nil : (__bridge id<MTLTexture>)(void*)(intptr_t)tex;
}

static tracy_force_inline MTLTextureDescriptor* CreateDescriptor( NSUInteger width, NSUInteger height, bool mipmapped )
{
    MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                     width:width
                                                                                    height:height
                                                                                 mipmapped:mipmapped];
    desc.usage = MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModeShared;
    return desc;
}

static tracy_force_inline id<MTLTexture> AcquireTexture( ImTextureID& tex, int w, int h, bool mipmapped )
{
    if( g_device == nil )
    {
        g_device = MTLCreateSystemDefaultDevice();
    }
    id<MTLTexture> texture = GetTexture( tex );
    if( texture )
    {
        const bool hasMips = texture.mipmapLevelCount > 1;
        if( texture.width != (NSUInteger)w || texture.height != (NSUInteger)h || hasMips != mipmapped )
        {
            ReleaseTextureId( tex );
            texture = nil;
            tex = ImTextureID_Invalid;
        }
    }
    if( !texture )
    {
        // 0 is not a valid texture size, so clamp to 1 to avoid creating an invalid texture.
        w = MAX( 1, w );
        h = MAX( 1, h );
        MTLTextureDescriptor* desc = CreateDescriptor( (NSUInteger)w, (NSUInteger)h, mipmapped );
        texture = [g_device newTextureWithDescriptor:desc];
        tex = StoreTexture( texture );
    }
    return texture;
}

void InitTexture()
{
    g_device = MTLCreateSystemDefaultDevice();
}

void FreeTexture( ImTextureID _tex, void(*runOnMainThread)(const std::function<void()>&, bool) )
{
    if( _tex == ImTextureID_Invalid ) return;
    runOnMainThread( [_tex] {
        id<MTLTexture> releaseTex = (__bridge_transfer id<MTLTexture>)(void*)(intptr_t)_tex;
        (void)releaseTex;
    }, false );
}

static tracy_force_inline void DecodeDxt1Part( uint64_t d, uint32_t* dst, uint32_t w )
{
    uint8_t* in = (uint8_t*)&d;
    uint16_t c0, c1;
    uint32_t idx;
    memcpy( &c0, in, 2 );
    memcpy( &c1, in+2, 2 );
    memcpy( &idx, in+4, 4 );

    uint8_t r0 = ( ( c0 & 0xF800 ) >> 8 ) | ( ( c0 & 0xF800 ) >> 13 );
    uint8_t g0 = ( ( c0 & 0x07E0 ) >> 3 ) | ( ( c0 & 0x07E0 ) >> 9 );
    uint8_t b0 = ( ( c0 & 0x001F ) << 3 ) | ( ( c0 & 0x001F ) >> 2 );

    uint8_t r1 = ( ( c1 & 0xF800 ) >> 8 ) | ( ( c1 & 0xF800 ) >> 13 );
    uint8_t g1 = ( ( c1 & 0x07E0 ) >> 3 ) | ( ( c1 & 0x07E0 ) >> 9 );
    uint8_t b1 = ( ( c1 & 0x001F ) << 3 ) | ( ( c1 & 0x001F ) >> 2 );

    uint32_t dict[4];

    dict[0] = 0xFF000000 | ( b0 << 16 ) | ( g0 << 8 ) | r0;
    dict[1] = 0xFF000000 | ( b1 << 16 ) | ( g1 << 8 ) | r1;

    uint32_t r, g, b;
    if( c0 > c1 )
    {
        r = (2*r0+r1)/3;
        g = (2*g0+g1)/3;
        b = (2*b0+b1)/3;
        dict[2] = 0xFF000000 | ( b << 16 ) | ( g << 8 ) | r;
        r = (2*r1+r0)/3;
        g = (2*g1+g0)/3;
        b = (2*b1+b0)/3;
        dict[3] = 0xFF000000 | ( b << 16 ) | ( g << 8 ) | r;
    }
    else
    {
        r = (int(r0)+r1)/2;
        g = (int(g0)+g1)/2;
        b = (int(b0)+b1)/2;
        dict[2] = 0xFF000000 | ( b << 16 ) | ( g << 8 ) | r;
        dict[3] = 0xFF000000;
    }

    memcpy( dst+0, dict + (idx & 0x3), 4 );
    idx >>= 2;
    memcpy( dst+1, dict + (idx & 0x3), 4 );
    idx >>= 2;
    memcpy( dst+2, dict + (idx & 0x3), 4 );
    idx >>= 2;
    memcpy( dst+3, dict + (idx & 0x3), 4 );
    idx >>= 2;
    dst += w;

    memcpy( dst+0, dict + (idx & 0x3), 4 );
    idx >>= 2;
    memcpy( dst+1, dict + (idx & 0x3), 4 );
    idx >>= 2;
    memcpy( dst+2, dict + (idx & 0x3), 4 );
    idx >>= 2;
    memcpy( dst+3, dict + (idx & 0x3), 4 );
    idx >>= 2;
    dst += w;

    memcpy( dst+0, dict + (idx & 0x3), 4 );
    idx >>= 2;
    memcpy( dst+1, dict + (idx & 0x3), 4 );
    idx >>= 2;
    memcpy( dst+2, dict + (idx & 0x3), 4 );
    idx >>= 2;
    memcpy( dst+3, dict + (idx & 0x3), 4 );
    idx >>= 2;
    dst += w;

    memcpy( dst+0, dict + (idx & 0x3), 4 );
    idx >>= 2;
    memcpy( dst+1, dict + (idx & 0x3), 4 );
    idx >>= 2;
    memcpy( dst+2, dict + (idx & 0x3), 4 );
    idx >>= 2;
    memcpy( dst+3, dict + (idx & 0x3), 4 );
}

ImTextureID UpdateTexture( ImTextureID _tex, const char* data, int w, int h )
{
    auto tex = _tex;
    id<MTLTexture> texture = AcquireTexture( tex, w, h, false );

    auto tmp = new uint32_t[w*h];
    auto src = (const uint64_t*)data;
    auto dst = tmp;
    for( int y=0; y<h/4; y++ )
    {
        for( int x=0; x<w/4; x++ )
        {
            uint64_t d = *src++;
            DecodeDxt1Part( d, dst, w );
            dst += 4;
        }
        dst += w*3;
    }

    [texture replaceRegion:MTLRegionMake2D( 0, 0, (NSUInteger)w, (NSUInteger)h )
               mipmapLevel:0
                 withBytes:tmp
               bytesPerRow:(NSUInteger)w * 4];
    delete[] tmp;

    return tex;
}

ImTextureID UpdateTextureRGBA( ImTextureID _tex, void* data, int w, int h )
{
    auto tex = _tex;
    id<MTLTexture> texture = AcquireTexture( tex, w, h, false );
    [texture replaceRegion:MTLRegionMake2D( 0, 0, (NSUInteger)w, (NSUInteger)h )
               mipmapLevel:0
                 withBytes:data
               bytesPerRow:(NSUInteger)w * 4];
    return tex;
}

ImTextureID UpdateTextureRGBAMips( ImTextureID _tex, void** data, int* w, int* h, size_t mips )
{
    auto tex = _tex;
    const bool mipmapped = mips > 1;
    id<MTLTexture> texture = AcquireTexture( tex, w[0], h[0], mipmapped );
    for( size_t i=0; i<mips; i++ )
    {
        [texture replaceRegion:MTLRegionMake2D( 0, 0, (NSUInteger)w[i], (NSUInteger)h[i] )
                   mipmapLevel:i
                     withBytes:data[i]
                   bytesPerRow:(NSUInteger)w[i] * 4];
    }
    return tex;
}

}
