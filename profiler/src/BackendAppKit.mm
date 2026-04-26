#include "profiler/TracyConfig.hpp"
#include "profiler/TracyImGui.hpp"

#include "Backend.hpp"
#include "RunQueue.hpp"

#import <Cocoa/Cocoa.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

#include <backends/imgui_impl_metal.h>
#include <backends/imgui_impl_osx.h>
#include <imgui.h>
@interface AppViewController : NSViewController <NSWindowDelegate>
@end

@interface AppViewController () <MTKViewDelegate>
@property( nonatomic, readonly ) MTKView* mtkView;
@property( nonatomic, strong ) id<MTLDevice> device;
@property( nonatomic, strong ) id<MTLCommandQueue> commandQueue;
@end

//-----------------------------------------------------------------------------------
// AppViewController
//-----------------------------------------------------------------------------------

//-----------------------------------------------------------------------------------
// AppDelegate
//-----------------------------------------------------------------------------------

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property( nonatomic, strong ) NSWindow* window;
@end

@implementation AppDelegate

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender
{
    return YES;
}

// Convert AppKit's exit()-based termination into a clean run-loop return so
// main() can join its worker threads. Without this, statics (joinable
// std::threads, the View shared_ptr) are torn down by __cxa_finalize while
// still active, tripping ~thread() -> std::terminate().
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)sender
{
    [NSApp stop:nil];
    return NSTerminateCancel;
}

- (instancetype)init
{
    self = [super init];
    if( self )
    {
        NSViewController* rootViewController = [[AppViewController alloc] initWithNibName:nil bundle:nil];
        self.window = [[NSWindow alloc] initWithContentRect:NSZeroRect
                                                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
        self.window.contentViewController = rootViewController;
        [self.window center];
        [self.window makeKeyAndOrderFront:self];
    }
    return self;
}

@end

static void BuildMainMenu()
{
    NSString* appName = [[NSProcessInfo processInfo] processName];
    NSMenu* mainMenu = [[NSMenu alloc] init];

    NSMenuItem* appMenuItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:appMenuItem];

    NSMenu* appMenu = [[NSMenu alloc] initWithTitle:appName];
    [appMenu addItemWithTitle:[@"About " stringByAppendingString:appName]
                       action:@selector(orderFrontStandardAboutPanel:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:[@"Hide " stringByAppendingString:appName]
                       action:@selector(hide:)
                keyEquivalent:@"h"];
    NSMenuItem* hideOthers = [appMenu addItemWithTitle:@"Hide Others"
                                                action:@selector(hideOtherApplications:)
                                         keyEquivalent:@"h"];
    hideOthers.keyEquivalentModifierMask = NSEventModifierFlagOption | NSEventModifierFlagCommand;
    [appMenu addItemWithTitle:@"Show All"
                       action:@selector(unhideAllApplications:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:[@"Quit " stringByAppendingString:appName]
                       action:@selector(terminate:)
                keyEquivalent:@"q"];
    appMenuItem.submenu = appMenu;

    NSApp.mainMenu = mainMenu;
}

static std::function<void()> s_redraw;
static std::function<void( float )> s_scaleChanged;
static RunQueue* s_mainThreadTasks;
static AppDelegate* s_app_delegate;
static float s_prevScale = -1;

Backend::Backend( const char* title, const std::function<void()>& redraw,
                  const std::function<void( float )>& scaleChanged, const std::function<int()>& isBusy,
                  RunQueue* mainThreadTasks )
{
    s_redraw = redraw;
    s_scaleChanged = scaleChanged;
    s_mainThreadTasks = mainThreadTasks;

    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

    BuildMainMenu();

    s_app_delegate = [[AppDelegate alloc] init];   // creates window
    [NSApp setDelegate:s_app_delegate];

    [NSApp activateIgnoringOtherApps:YES];
}

Backend::~Backend()
{
}

void Backend::Show()
{
    NSLog( @"Show called" );
}

void Backend::Run()
{
    NSLog( @"Run called" );

    @autoreleasepool
    {
        [NSApp run];

        // Tear down the ImGui platform/renderer backends here — the single
        // point where every quit path (window close, menu Quit, Cmd+Q)
        // converges — so ImGui::DestroyContext() in main()'s RAII cleanup
        // doesn't trip its "forgot to shutdown backend" assert.
        ImGui_ImplMetal_Shutdown();
        ImGui_ImplOSX_Shutdown();
    }
}
void Backend::Attention()
{
    NSLog(@"NOT IMPLEMENTED: Backend::Attention()");
}

static MTKView* _current_view = nil;
static id<MTLCommandBuffer> _current_command_buffer = nil;
static MTLRenderPassDescriptor* _current_rpd = nil;

static enum {
    NO_FRAME,
    FRAME_STARTED,
    FRAME_ENDED,
} g_frameState = NO_FRAME;

void Backend::NewFrame( int& w, int& h )
{
    const auto scale = GetDpiScale();
    if( scale != s_prevScale )
    {
        s_prevScale = scale;
        s_scaleChanged( scale );
    }

    CGSize size = _current_view.bounds.size;
    w = (int)size.width;
    h = (int)size.height;

    // Start the Dear ImGui frame
    ImGui_ImplMetal_NewFrame( _current_rpd );
    ImGui_ImplOSX_NewFrame( _current_view );

    g_frameState = FRAME_STARTED;
}

void Backend::EndFrame()
{
    static ImVec4 clear_color = ImVec4( 0.45f, 0.55f, 0.60f, 1.00f );

    ImGui::Render();

    if ([_current_view.window occlusionState] & NSWindowOcclusionStateVisible) {
        _current_rpd.colorAttachments[0].clearColor = MTLClearColorMake(clear_color.x * clear_color.w,
                                                                        clear_color.y * clear_color.w,
                                                                        clear_color.z * clear_color.w, clear_color.w);
        id <MTLRenderCommandEncoder> renderEncoder = [_current_command_buffer renderCommandEncoderWithDescriptor:_current_rpd];
        [renderEncoder pushDebugGroup:@"Dear ImGui rendering"];
        ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), _current_command_buffer, renderEncoder);
        [renderEncoder popDebugGroup];
        [renderEncoder endEncoding];

        // Present
        [_current_command_buffer presentDrawable:_current_view.currentDrawable];
    }

    [_current_command_buffer commit];
    _current_rpd = nil;
    _current_command_buffer = nil;
    _current_view = nil;

    g_frameState = FRAME_ENDED;
}

void Backend::SetIcon( uint8_t* data, int w, int h )
{
}
void Backend::SetTitle( const char* title )
{
}
float Backend::GetDpiScale()
{
    return 2.0;
}

@implementation AppViewController

- (instancetype)initWithNibName:(nullable NSString*)nibNameOrNil bundle:(nullable NSBundle*)nibBundleOrNil
{
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];

    _device = MTLCreateSystemDefaultDevice();
    _commandQueue = [_device newCommandQueue];

    if( !self.device )
    {
        NSLog( @"Metal is not supported" );
        abort();
    }

    // Setup Dear ImGui context
    // FIXME: This example doesn't have proper cleanup...
    IMGUI_CHECKVERSION();
    // ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    (void)io;
    //io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;     // Enable Keyboard Controls
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableGamepad;      // Enable Gamepad Controls
    io.ConfigFlags |= ImGuiConfigFlags_ViewportsEnable;       // Enable Multi-Viewport / Platform Windows

    // Setup Dear ImGui style
    ImGui::StyleColorsDark();
    // ImGui::StyleColorsLight();

    // When viewports are enabled we tweak WindowRounding/WindowBg so platform windows can look identical to regular ones.
    ImGuiStyle& style = ImGui::GetStyle();
    if( io.ConfigFlags & ImGuiConfigFlags_ViewportsEnable )
    {
        style.WindowRounding = 0.0f;
        style.Colors[ImGuiCol_WindowBg].w = 1.0f;
    }

    // Setup Renderer backend
    ImGui_ImplMetal_Init( _device );

    // Load Fonts
    // - If no fonts are loaded, dear imgui will use the default font. You can also load multiple fonts and use ImGui::PushFont()/PopFont() to select them.
    // - AddFontFromFileTTF() will return the ImFont* so you can store it if you need to select the font among multiple.
    // - If the file cannot be loaded, the function will return a nullptr. Please handle those errors in your application (e.g. use an assertion, or display an error and quit).
    // - Use '#define IMGUI_ENABLE_FREETYPE' in your imconfig file to use Freetype for higher quality font rendering.
    // - Read 'docs/FONTS.md' for more instructions and details.
    // - Remember that in C/C++ if you want to include a backslash \ in a string literal you need to write a double backslash \\ !
    // style.FontSizeBase = 20.0f;
    // io.Fonts->AddFontDefault();
    // io.Fonts->AddFontFromFileTTF("c:\\Windows\\Fonts\\segoeui.ttf");
    // io.Fonts->AddFontFromFileTTF("../../misc/fonts/DroidSans.ttf");
    // io.Fonts->AddFontFromFileTTF("../../misc/fonts/Roboto-Medium.ttf");
    // io.Fonts->AddFontFromFileTTF("../../misc/fonts/Cousine-Regular.ttf");
    // ImFont* font = io.Fonts->AddFontFromFileTTF("c:\\Windows\\Fonts\\ArialUni.ttf");
    // IM_ASSERT(font != nullptr);

    return self;
}

- (MTKView*)mtkView
{
    return (MTKView*)self.view;
}

- (void)loadView
{
    self.view = [[MTKView alloc] initWithFrame:CGRectMake( 0, 0, 1200, 720 )];
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.mtkView.device = self.device;
    self.mtkView.delegate = self;

    self.mtkView.preferredFramesPerSecond = 240;

    ImGui_ImplOSX_Init( self.view );
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)drawInMTKView:(MTKView*)view
{
    ImGuiIO& io = ImGui::GetIO();
    io.DisplaySize.x = view.bounds.size.width;
    io.DisplaySize.y = view.bounds.size.height;

    CGFloat framebufferScale = view.window.screen.backingScaleFactor ?: NSScreen.mainScreen.backingScaleFactor;
    io.DisplayFramebufferScale = ImVec2( framebufferScale, framebufferScale );

    _current_view = view;
    _current_command_buffer = [self.commandQueue commandBuffer];
    _current_rpd = view.currentRenderPassDescriptor;

    MTLRenderPassDescriptor* renderPassDescriptor = view.currentRenderPassDescriptor;
    if( _current_rpd == nil )
    {
        [_current_command_buffer commit];
        _current_command_buffer = nil;
        _current_view = nil;
        return;
    }

    IM_ASSERT(g_frameState == NO_FRAME);

    s_redraw();
    s_mainThreadTasks->Run();

    // Update and Render additional Platform Windows
    if( g_frameState == FRAME_ENDED && io.ConfigFlags & ImGuiConfigFlags_ViewportsEnable )
    {
        ImGui::UpdatePlatformWindows();
        ImGui::RenderPlatformWindowsDefault();
    }

    g_frameState = NO_FRAME;
}

- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size
{
}

//-----------------------------------------------------------------------------------
// Input processing
//-----------------------------------------------------------------------------------

- (void)viewWillAppear
{
    [super viewWillAppear];
    self.view.window.delegate = self;
}

- (void)windowWillClose:(NSNotification*)notification
{
    // ImGui platform/renderer + context teardown lives at app-lifecycle scope
    // (Backend::Run after [NSApp run] returns; ImGuiTracyContext dtor in main),
    // not at window-lifecycle scope.
}

@end
