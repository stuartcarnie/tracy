#ifndef __TRACYTEXTURE_HPP__
#define __TRACYTEXTURE_HPP__

#include <functional>
#include <imgui.h>

namespace tracy
{

void InitTexture();
void FreeTexture( ImTextureID tex, void(*runOnMainThread)(const std::function<void()>&, bool) );
ImTextureID UpdateTexture( ImTextureID tex, const char* data, int w, int h );
ImTextureID UpdateTextureRGBA( ImTextureID tex, void* data, int w, int h );
ImTextureID UpdateTextureRGBAMips( ImTextureID tex, void** data, int* w, int* h, size_t mips );

}

#endif
