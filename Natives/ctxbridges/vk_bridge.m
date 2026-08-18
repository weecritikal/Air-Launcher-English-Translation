#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "bridge_tbl.h"
#include "vk_bridge.h"
#include "utils.h"

// Basic Vulkan type definitions (modeled on vulkan_core.h)
// To avoid pulling in the full vulkan_core.h dependency chain, the minimal set of types needed is defined here.
// These types match the definitions in the Vulkan/MoltenVK headers exactly.
typedef uint32_t VkFlags;
typedef uint32_t VkBool32;
typedef int32_t VkResult;
typedef uintptr_t VkInstance;

#define VK_SUCCESS 0
#define VK_INCOMPLETE 5
#define VK_NULL_HANDLE 0

// MoltenVK configuration API type definitions (modeled on vk_mvk_moltenvk.h)
// vkGetMoltenVKConfigurationMVK and vkSetMoltenVKConfigurationMVK can be called before a VkInstance is created
// (by passing VK_NULL_HANDLE), to read/modify MoltenVK's runtime configuration.
// These two APIs are MoltenVK extension functions (VK_MVK_moltenvk) rather than standard Vulkan functions,
// so their symbols must be obtained straight from libMoltenVK.dylib with dlsym.
//
// Note: the vk_mvk_moltenvk.h header in this repository is an old version (1.1.2, spec 30),
// but the libMoltenVK.dylib actually in use is already 1.2.9 (confirmed from the binary with strings).
// MoltenVK 1.2.9 supports the MVK_CONFIG_SWAPCHAIN_PRESENT_MODE environment variable (0=IMMEDIATE, 2=FIFO),
// and JavaLauncher.m already sets MVK_CONFIG_SWAPCHAIN_PRESENT_MODE=0.
// MoltenVK 1.2.9 reads that environment variable in vkCreateSwapchainKHR and overrides the application's presentMode,
// which is the key mechanism for unlocking the frame rate in Vulkan mode.
//
// The member order below follows the MVKConfiguration struct definition in vk_mvk_moltenvk.h exactly.
// Even if the struct size does not exactly match the MoltenVK version in use, vkGetMoltenVKConfigurationMVK
// limits how much it writes via the configSize parameter, so no out-of-bounds access occurs.
typedef struct {
    VkBool32 debugMode;                              // line 112
    VkBool32 shaderConversionFlipVertexY;            // line 132
    VkBool32 synchronousQueueSubmits;                // line 151
    VkBool32 prefillMetalCommandBuffers;             // line 198
    uint32_t maxActiveMetalCommandBuffersPerQueue;   // line 216
    VkBool32 supportLargeQueryPools;                 // line 236
    VkBool32 presentWithCommandBuffer;               // line 239 (deprecated)
    VkBool32 swapchainMagFilterUseNearest;           // line 257
    uint64_t metalCompileTimeout;                    // line 273 (uint64_t!)
    VkBool32 performanceTracking;                    // line 290
    uint32_t performanceLoggingFrameCount;           // line 306
    VkBool32 displayWatermark;                       // line 320
    VkBool32 specializedQueueFamilies;               // line 347
    VkBool32 switchSystemGPU;                        // line 379
    VkBool32 fullImageViewSwizzle;                   // line 432
    uint32_t defaultGPUCaptureScopeQueueFamilyIndex; // line 446
    uint32_t defaultGPUCaptureScopeQueueIndex;       // line 461
    VkBool32 fastMathEnabled;                        // line 475
    uint32_t logLevel;                               // line 491
    uint32_t traceVulkanCalls;                       // line 512
    VkBool32 forceLowPowerGPU;                       // line 526
    VkBool32 semaphoreUseMTLFence;                   // line 549
    VkBool32 semaphoreUseMTLEvent;                   // line 572
    uint32_t autoGPUCaptureScope;                    // line 596
    char* autoGPUCaptureOutputFilepath;              // line 616
    VkBool32 texture1DAs2D;                          // line 632
    VkBool32 preallocateDescriptors;                 // line 652
    VkBool32 useCommandPooling;                      // line 671
    VkBool32 useMTLHeap;                             // line 694
    VkBool32 logActivityPerformanceInline;           // line 711
} MVKConfigurationLocal;

typedef VkResult (*PFN_vkGetMoltenVKConfigurationMVKLocal)(VkInstance ignored, MVKConfigurationLocal* pConfiguration, size_t* pConfigurationSize);
typedef VkResult (*PFN_vkSetMoltenVKConfigurationMVKLocal)(VkInstance ignored, MVKConfigurationLocal* pConfiguration, size_t* pConfigurationSize);

// Vulkan rendering bypass bridge layer: Minecraft manages the swapchain and queue itself and submits straight through libMoltenVK.
// These stubs exist so that pojavInitOpenGL() can install a non-NULL bridge table,
// preventing a crash if any GL-shaped GLFW call reaches the dispatcher before or after the Vulkan path takes over.

static vk_render_window_t g_dummy;

// MoltenVK configuration API function pointers (loaded with dlsym in vk_init)
static PFN_vkGetMoltenVKConfigurationMVKLocal s_vkGetMoltenVKConfigurationMVK = NULL;
static PFN_vkSetMoltenVKConfigurationMVKLocal s_vkSetMoltenVKConfigurationMVK = NULL;

// VSync state: records whether vertical sync is currently disabled
static BOOL s_vsyncDisabled = NO;

/// Load the MoltenVK configuration API from libMoltenVK.dylib
/// These two APIs can be called before a VkInstance is created, to read and modify MoltenVK's runtime configuration.
static void loadMoltenVKConfigAPIs(void* dl_handle) {
    if (!dl_handle) {
        NSLog(@"[VKBridge] loadMoltenVKConfigAPIs: dl_handle is NULL, skipping");
        return;
    }

    // Clear any earlier error state
    dlerror();

    // Load vkGetMoltenVKConfigurationMVK
    s_vkGetMoltenVKConfigurationMVK = (PFN_vkGetMoltenVKConfigurationMVKLocal)dlsym(dl_handle, "vkGetMoltenVKConfigurationMVK");
    const char* getError = dlerror();
    if (getError || !s_vkGetMoltenVKConfigurationMVK) {
        NSLog(@"[VKBridge] Failed to load vkGetMoltenVKConfigurationMVK: %s", getError ?: "symbol not found");
        s_vkGetMoltenVKConfigurationMVK = NULL;
    } else {
        NSLog(@"[VKBridge] Successfully loaded vkGetMoltenVKConfigurationMVK");
    }

    // Load vkSetMoltenVKConfigurationMVK
    dlerror();
    s_vkSetMoltenVKConfigurationMVK = (PFN_vkSetMoltenVKConfigurationMVKLocal)dlsym(dl_handle, "vkSetMoltenVKConfigurationMVK");
    const char* setError = dlerror();
    if (setError || !s_vkSetMoltenVKConfigurationMVK) {
        NSLog(@"[VKBridge] Failed to load vkSetMoltenVKConfigurationMVK: %s", setError ?: "symbol not found");
        s_vkSetMoltenVKConfigurationMVK = NULL;
    } else {
        NSLog(@"[VKBridge] Successfully loaded vkSetMoltenVKConfigurationMVK");
    }
}

/// Read and log the current MoltenVK configuration
/// Reads the configuration with vkGetMoltenVKConfigurationMVK and prints the key parameters,
/// to help diagnose frame rate limits with the Vulkan renderer.
static void logMoltenVKConfiguration() {
    if (!s_vkGetMoltenVKConfigurationMVK) {
        NSLog(@"[VKBridge] vkGetMoltenVKConfigurationMVK not available, skipping config logging");
        return;
    }

    MVKConfigurationLocal config;
    memset(&config, 0, sizeof(config));
    size_t configSize = sizeof(config);

    // Passing VK_NULL_HANDLE (the first parameter is ignored) allows this to be called before a VkInstance is created
    VkResult result = s_vkGetMoltenVKConfigurationMVK(VK_NULL_HANDLE, &config, &configSize);
    if (result == VK_SUCCESS || result == VK_INCOMPLETE) {
        NSLog(@"[VKBridge] MoltenVK Configuration (configSize=%zu, result=%d):", configSize, result);
        NSLog(@"[VKBridge]   debugMode=%u", config.debugMode);
        NSLog(@"[VKBridge]   synchronousQueueSubmits=%u", config.synchronousQueueSubmits);
        NSLog(@"[VKBridge]   prefillMetalCommandBuffers=%u", config.prefillMetalCommandBuffers);
        NSLog(@"[VKBridge]   maxActiveMetalCommandBuffersPerQueue=%u", config.maxActiveMetalCommandBuffersPerQueue);
        NSLog(@"[VKBridge]   swapchainMagFilterUseNearest=%u", config.swapchainMagFilterUseNearest);
        NSLog(@"[VKBridge]   metalCompileTimeout=%llu", config.metalCompileTimeout);
        NSLog(@"[VKBridge]   performanceTracking=%u", config.performanceTracking);
        NSLog(@"[VKBridge]   performanceLoggingFrameCount=%u", config.performanceLoggingFrameCount);
        NSLog(@"[VKBridge]   forceLowPowerGPU=%u", config.forceLowPowerGPU);
        NSLog(@"[VKBridge]   fastMathEnabled=%u", config.fastMathEnabled);
        NSLog(@"[VKBridge]   logLevel=%u", config.logLevel);
        NSLog(@"[VKBridge]   useCommandPooling=%u", config.useCommandPooling);
        NSLog(@"[VKBridge]   useMTLHeap=%u", config.useMTLHeap);
    } else {
        NSLog(@"[VKBridge] vkGetMoltenVKConfigurationMVK failed with result=%d", result);
    }
}

/// Check and log the state of the VSync-related environment variables
/// These environment variables affect how the Vulkan renderer limits the frame rate:
/// - POJAV_DISABLE_VSYNC: the launcher preference controlling whether vertical sync is disabled
/// - MVK_CONFIG_SWAPCHAIN_PRESENT_MODE: an environment variable supported by MoltenVK 1.2.5+ that
///   forces the swapchain present mode (0=IMMEDIATE, 1=MAILBOX, 2=FIFO)
///
/// The MoltenVK version actually in use is 1.2.9 (confirmed from the libMoltenVK.dylib binary),
/// which supports the MVK_CONFIG_SWAPCHAIN_PRESENT_MODE environment variable.
/// MoltenVK 1.2.9 reads that environment variable in vkCreateSwapchainKHR and overrides the application's presentMode.
/// Whether the device supports the IMMEDIATE present mode is detected automatically through
/// MVKPhysicalDeviceMetalFeatures.presentModeImmediate (most iOS devices do).
static void logVSyncEnvironment() {
    const char* pojavDisableVsync = getenv("POJAV_DISABLE_VSYNC");
    const char* renderer = getenv("AMETHYST_RENDERER");
    const char* mvkPresentMode = getenv("MVK_CONFIG_SWAPCHAIN_PRESENT_MODE");

    NSLog(@"[VKBridge] VSync Environment Check:");
    NSLog(@"[VKBridge]   AMETHYST_RENDERER=%s", renderer ?: "<unset>");
    NSLog(@"[VKBridge]   POJAV_DISABLE_VSYNC=%s", pojavDisableVsync ?: "<unset>");
    NSLog(@"[VKBridge]   MVK_CONFIG_SWAPCHAIN_PRESENT_MODE=%s", mvkPresentMode ?: "<unset>");

    // Decide whether VSync should be disabled
    if (pojavDisableVsync && strcmp(pojavDisableVsync, "1") == 0) {
        s_vsyncDisabled = YES;
        NSLog(@"[VKBridge]   -> VSync is DISABLED (POJAV_DISABLE_VSYNC=1)");
        if (mvkPresentMode && strcmp(mvkPresentMode, "0") == 0) {
            NSLog(@"[VKBridge]   -> MoltenVK present mode forced to IMMEDIATE (MVK_CONFIG_SWAPCHAIN_PRESENT_MODE=0)");
        }
    } else {
        s_vsyncDisabled = NO;
        NSLog(@"[VKBridge]   -> VSync is ENABLED (POJAV_DISABLE_VSYNC!=1)");
    }
}

static bool vk_init(void) {
    NSLog(@"[VKBridge] vk_init: loading libMoltenVK.dylib");

    void* h = dlopen("@rpath/" RENDERER_NAME_VULKAN, RTLD_GLOBAL);
    if (!h) {
        NSLog(@"[VKBridge] dlopen %s failed: %s", RENDERER_NAME_VULKAN, dlerror());
        return false;
    }

    NSLog(@"[VKBridge] Successfully loaded %s", RENDERER_NAME_VULKAN);

    // Load the MoltenVK configuration API
    loadMoltenVKConfigAPIs(h);

    // Log the state of the VSync environment variables
    logVSyncEnvironment();

    // Read and log the current MoltenVK configuration
    logMoltenVKConfiguration();

    return true;
}

static vk_render_window_t* vk_init_context(vk_render_window_t* share) {
    return &g_dummy;
}

static void vk_make_current(vk_render_window_t* bundle) {
    // With the Vulkan renderer, Minecraft/LWJGL manage the Vulkan context directly,
    // so the bridge layer has nothing to do.
}

static void vk_swap_buffers(void) {
    // With the Vulkan renderer, Minecraft/LWJGL call vkQueuePresentKHR directly,
    // so the bridge layer's swap_buffers is never called (unless some leftover GL-shaped call arrives).
    // If it is called, log it to help with diagnosis.
    static int s_swapBufferWarnCount = 0;
    if (s_swapBufferWarnCount < 3) {
        s_swapBufferWarnCount++;
        NSLog(@"[VKBridge] vk_swap_buffers called (unexpected for Vulkan renderer, count=%d)", s_swapBufferWarnCount);
    }
}

static void vk_swap_interval(int interval) {
    // With the Vulkan renderer, Minecraft/LWJGL manage the swapchain present mode directly,
    // so the bridge layer's swap_interval has no direct effect on Vulkan's VSync behavior.
    //
    // It is logged here anyway, to help diagnose VSync requests:
    // - interval=0 means a request to disable VSync (unlocking the frame rate)
    // - interval=1 means a request to enable VSync (locking to the screen refresh rate)
    //
    // For the Vulkan renderer, VSync is controlled through the following mechanisms:
    // 1. PojavLauncher.java writes enableVsync=false into options.txt (so MC does not request VSync)
    // 2. LWJGL selects VK_PRESENT_MODE_IMMEDIATE_KHR in vkCreateSwapchainKHR
    // (whether the device supports IMMEDIATE is detected automatically by MoltenVK, with no environment variable needed)

    // Intercept the VSync request: force interval=0 when POJAV_DISABLE_VSYNC=1
    // This has no direct effect on the Vulkan renderer (Minecraft manages the swapchain itself),
    // but logging the interception helps with diagnosis.
    if (getenv("POJAV_DISABLE_VSYNC") && strcmp(getenv("POJAV_DISABLE_VSYNC"), "1") == 0) {
        if (interval != 0) {
            NSLog(@"[VKBridge] vk_swap_interval: intercepted VSync request interval=%d -> 0 (POJAV_DISABLE_VSYNC=1)", interval);
        }
        interval = 0;
        s_vsyncDisabled = YES;
    } else {
        s_vsyncDisabled = NO;
    }

    // Log the first few swap_interval calls, to help with diagnosis
    static int s_swapIntervalLogCount = 0;
    if (s_swapIntervalLogCount < 5) {
        s_swapIntervalLogCount++;
        NSLog(@"[VKBridge] vk_swap_interval(%d) called (count=%d, vsyncDisabled=%d)", interval, s_swapIntervalLogCount, s_vsyncDisabled);
    }
}

static void vk_terminate(void) {
    NSLog(@"[VKBridge] vk_terminate: cleaning up Vulkan bridge");
    // Clear the configuration API function pointers
    s_vkGetMoltenVKConfigurationMVK = NULL;
    s_vkSetMoltenVKConfigurationMVK = NULL;
    s_vsyncDisabled = NO;
}

void set_vk_bridge_tbl(void) {
    br_init = vk_init;
    br_init_context = (br_init_context_t) vk_init_context;
    br_make_current = (br_make_current_t) vk_make_current;
    br_swap_buffers = vk_swap_buffers;
    br_swap_interval = vk_swap_interval;
    br_terminate = vk_terminate;
}
