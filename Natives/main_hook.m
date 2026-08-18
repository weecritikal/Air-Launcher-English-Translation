#import <Foundation/Foundation.h>
#import "PLLogOutputView.h"
#import "SurfaceViewController.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "mach_excServer.h"

#include <dlfcn.h>
#include <libgen.h>
#include <pthread.h>
#include "external/fishhook/fishhook.h"

// Hardware breakpoint exception port (synced from upstream, used for dlopen redirection on non-TXM iOS 26+ devices)
mach_port_t excPort;
void *hooked_dlopen_26_ppl(const char *path, int mode);

void (*orig_abort)();
void (*orig_exit)(int code);
void* (*orig_dlopen)(const char* path, int mode);
void* (*orig_dlsym)(void* handle, const char* name);
int (*orig_open)(const char *path, int oflag, ...);

/// A dlsym that "bypasses the hook", provided for the zink stride fix
/// amethyst_vkGetInstanceProcAddr / amethyst_vkGetDeviceProcAddr must call this function when looking up
/// the real Vulkan function pointers, otherwise hooked_dlsym would intercept them (returning
/// our wrapper) and cause infinite recursion.
void *amethyst_orig_dlsym(void *handle, const char *name) {
    if (orig_dlsym) {
        return orig_dlsym(handle, name);
    }
    // Fallback: use plain dlsym if the hook has not been initialized yet (which should not happen)
    return dlsym(handle, name);
}

// Forward declaration: the zink stride fix state variable (defined later in the file in the Vulkan stride fix section,
// but hooked_dlopen earlier in the file needs to reference it to detect that libOSMesa has been loaded)
static BOOL g_zinkStrideFixActive = NO;

void handle_fatal_exit(int code) {
    if (NSThread.isMainThread) {
        return;
    }

    // Note: PLLogOutputView.handleExitCode: in this repository returns void (a project-specific
    // PLCrashView integration), so upstream's if (![PLLogOutputView handleExitCode:code]) return;
    // check cannot be copied verbatim. It is called directly here and PLCrashView decides internally whether to show the crash screen.
    [PLLogOutputView handleExitCode:code];

    if (fatalExitGroup != nil) {
        // Likely other threads are crashing, put them to sleep
        sleep(INT_MAX);
    }
    fatalExitGroup = dispatch_group_create();
    dispatch_group_enter(fatalExitGroup);
    dispatch_group_wait(fatalExitGroup, DISPATCH_TIME_FOREVER);
}

void hooked_abort() {
    NSLog(@"abort() called");
    handle_fatal_exit(SIGABRT);
    orig_abort();
}

void hooked___assert_rtn(const char* func, const char* file, int line, const char* failedexpr)
{
    if (func == NULL) {
        fprintf(stderr, "Assertion failed: (%s), file %s, line %d.\n", failedexpr, file, line);
    } else {
        fprintf(stderr, "Assertion failed: (%s), function %s, file %s, line %d.\n", failedexpr, func, file, line);
    }
    hooked_abort();
}

void hooked_exit(int code) {
    NSLog(@"exit(%d) called", code);
    if (code == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [UIApplication.sharedApplication performSelector:@selector(suspend)];
        });
        usleep(100*1000);
        orig_exit(0);
        return;
    }
    handle_fatal_exit(code);

    orig_exit(code);
}

void* hooked_dlopen(const char* path, int mode) {
    // Synced from upstream: non-TXM iOS 26+ devices need hardware breakpoint redirection (hooked_dlopen_26_ppl)
    BOOL shouldUseDyldBypass26PPL = NO;
    if (DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED)) {
        shouldUseDyldBypass26PPL = hwRedirectOrig[0] && !DeviceHasJITFlags(JIT_FLAG_HAS_TXM);
    }
    // Only patch Mach-O and use dyld bypass dylib is in the home dir
    // or tmp dir: LiveContainer makes a symlink to its own tmp dir so checking home dir alone would fail
    const char *home = getenv("HOME");
    const char *tmp = getenv("TMPDIR");
    char fullpath[PATH_MAX];
    BOOL shouldUseDyldBypass = path && realpath(path, fullpath) && (strstr(fullpath, home) || (tmp && strstr(fullpath, tmp)));
    shouldUseDyldBypass26PPL &= shouldUseDyldBypass;

    // Synced from upstream: call PLPatchMachOPlatformForFile uniformly before the branch
    // (the original implementation only called it in the shouldUseDyldBypass branch and missed the 26PPL path,
    //  which made the dyld bypass fail on non-TXM iOS 26+ devices)
    if (shouldUseDyldBypass) {
        PLPatchMachOPlatformForFile(path);
    }

    // Fork-specific feature: the zink stride fix - re-run fishhook after libOSMesa is loaded
    // to capture its symbol references to vkGetInstanceProcAddr / vkGetDeviceProcAddr
    // (installZinkStrideFix runs before libOSMesa is loaded, so the initial rebind cannot
    //  capture references inside the libOSMesa image; a second rebind after it loads is required)
    BOOL needsZinkRebind = path && strstr(path, "libOSMesa") && g_zinkStrideFixActive;

    void *handle;
    if (shouldUseDyldBypass26PPL) {
        if (needsZinkRebind) {
            handle = hooked_dlopen_26_ppl(path, mode);
        } else {
            __attribute__((musttail)) return hooked_dlopen_26_ppl(path, mode);
        }
    } else if (shouldUseDyldBypass) {
        // Special case for LiveContainer multitask mode where it hooks dlopen to hook mmap,
        // which will break this dyld bypass, so we redirect calls to the original dlopen.
        static void *(*sys_dlopen)(const char *, int);
        if(!sys_dlopen) sys_dlopen = dlsym(RTLD_NEXT, "dlopen");
        if (needsZinkRebind) {
            handle = sys_dlopen(path, mode);
        } else {
            __attribute__((musttail)) return sys_dlopen(path, mode);
        }
    } else {
        if (needsZinkRebind) {
            handle = orig_dlopen(path, mode);
        } else {
            __attribute__((musttail)) return orig_dlopen(path, mode);
        }
    }

    // Zink stride fix rebind (only performed when needsZinkRebind is set)
    if (handle && needsZinkRebind) {
        NSLog(@"[ZinkStrideFix] libOSMesa loaded via dlopen, re-rebinding Vulkan symbols");
        rebindZinkStrideFixForNewImage();
    }
    return handle;
}

// ============================================================================
// Hardware breakpoint dlopen redirection (synced from upstream, for non-TXM iOS 26+ devices)
// When redirectFunctionHWBreakpoint is chosen, dlopen must redirect the mmap/fcntl calls inside dyld
// using hardware breakpoints + Mach exceptions, because dyld's code section cannot be modified directly in that case.
// ============================================================================
void *exception_handler(void *unused) {
    mach_msg_server(mach_exc_server, sizeof(union __RequestUnion__catch_mach_exc_subsystem), excPort, MACH_MSG_OPTION_NONE);
    abort();
}

void *hooked_dlopen_26_ppl(const char *path, int mode) {
    if (!excPort) {
        mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &excPort);
        mach_port_insert_right(mach_task_self(), excPort, excPort, MACH_MSG_TYPE_MAKE_SEND);
        pthread_t thread;
        pthread_create(&thread, NULL, exception_handler, NULL);
    }

    // save old thread states
    exception_mask_t mask = EXC_MASK_BREAKPOINT;
    mach_msg_type_number_t masksCnt = 1;
    exception_handler_t handler = excPort;
    exception_behavior_t behavior = EXCEPTION_STATE | MACH_EXCEPTION_CODES;
    thread_state_flavor_t flavor = ARM_THREAD_STATE64;
    arm_debug_state64_t origDebugState;
    mach_port_t thread = mach_thread_self();
    thread_get_state(thread, ARM_DEBUG_STATE64, (thread_state_t)&origDebugState, &(mach_msg_type_number_t){ARM_DEBUG_STATE64_COUNT});
    thread_swap_exception_ports(thread, mask, handler, behavior, flavor, &mask, &masksCnt, &handler, &behavior, &flavor);
    if (masksCnt != 1) {
        NSLog(@"main_hook: Expected 1 exception port, got %d. HW breakpoint hook may fail.", masksCnt);
    }

    // hook stuff. this will overwrite LiveContainer private container multitask's hook, we will load __TEXT using JIT inside
    arm_debug_state64_t hookDebugState = {0};
    for(int i = 0; i < 6 && hwRedirectOrig[i]; i++) {
        hookDebugState.__bvr[i] = (uint64_t)hwRedirectOrig[i];
        hookDebugState.__bcr[i] = 0x1e5;
    }
    thread_set_state(thread, ARM_DEBUG_STATE64, (thread_state_t)&hookDebugState, ARM_DEBUG_STATE64_COUNT);

    // fixup @loader_path since we cannot use musttail here
    void *result;
    void *callerAddr = __builtin_return_address(0);
    struct dl_info info;
    if (path && !strncmp(path, "@loader_path/", 13) && dladdr(callerAddr, &info)) {
        char resolvedPath[PATH_MAX];
        snprintf(resolvedPath, sizeof(resolvedPath), "%s/%s", dirname((char *)info.dli_fname), path + 13);
        result = orig_dlopen(resolvedPath, mode);
    } else {
        result = orig_dlopen(path, mode);
    }

    // restore old thread states
    thread_set_state(thread, ARM_DEBUG_STATE64, (thread_state_t)&origDebugState, ARM_DEBUG_STATE64_COUNT);
    thread_swap_exception_ports(thread, mask, handler, behavior, flavor, &mask, &masksCnt, &handler, &behavior, &flavor);

    return result;
}

kern_return_t catch_mach_exception_raise_state(mach_port_t exception_port, exception_type_t exception, const mach_exception_data_t code, mach_msg_type_number_t codeCnt, int *flavor, const thread_state_t old_state, mach_msg_type_number_t old_stateCnt, thread_state_t new_state, mach_msg_type_number_t *new_stateCnt) {
    arm_thread_state64_t *old = (arm_thread_state64_t *)old_state;
    arm_thread_state64_t *new = (arm_thread_state64_t *)new_state;
    uint64_t pc = arm_thread_state64_get_pc(*old);

    for(int i = 0; i < 6 && hwRedirectOrig[i]; i++) {
        if(pc == (uint64_t)hwRedirectOrig[i]) {
            *new = *old;
            *new_stateCnt = old_stateCnt;
            arm_thread_state64_set_pc_fptr(*new, hwRedirectTarget[i]);
            return KERN_SUCCESS;
        }
    }
    NSLog(@"[DyldLVBypass] Unknown breakpoint at pc: %p", (void*)pc);
    return KERN_FAILURE;
}

kern_return_t catch_mach_exception_raise(mach_port_t exception_port, mach_port_t thread, mach_port_t task, exception_type_t exception, mach_exception_data_t code, mach_msg_type_number_t codeCnt) {
    abort();
}

kern_return_t catch_mach_exception_raise_state_identity(mach_port_t exception_port, mach_port_t thread, mach_port_t task, exception_type_t exception, mach_exception_data_t code, mach_msg_type_number_t codeCnt, int *flavor, thread_state_t old_state, mach_msg_type_number_t old_stateCnt, thread_state_t new_state, mach_msg_type_number_t *new_stateCnt) {
    abort();
}

// ============================================================================
// Vulkan vertex stride alignment fix（zink + MoltenVK + Mesa 25.0.7）
// ============================================================================
// The problem:
//   The Metal API strictly requires the vertex attribute binding stride to be 4-byte aligned.
//   Mesa 25.0.7 zink removed the stride alignment workaround that existed in Mesa 21.0.0.
//   When a shader pack (such as BSL) triggers a pipeline rebuild with a stride that is not 4-aligned, MoltenVK returns
//   VK_ERROR_INITIALIZATION_FAILED; zink's update_gfx_pipeline does not handle that
//   error and uses a NULL pipeline handle, causing a SIGSEGV.
//
// The solution:
//   Hook vkGetInstanceProcAddr / vkGetDeviceProcAddr through the dual mechanism of dlsym interception
//   plus fishhook. When zink asks for vkCreateGraphicsPipelines, our wrapper is returned instead.
//   Before calling the real function, the wrapper rounds the vertex binding stride up
//   to a 4-byte boundary.
//
//   This fix is only active when the zink renderer (libOSMesa) is selected.

// Minimal Vulkan type definitions (the layout matches vulkan_core.h exactly on 64-bit platforms)
typedef int32_t VkZResult;
typedef struct VkZInstance_T* VkZInstance;
typedef struct VkZDevice_T* VkZDevice;
typedef struct VkZCommandBuffer_T* VkZCommandBuffer;
typedef struct VkZPipelineCache_T* VkZPipelineCache;
typedef struct VkZPipeline_T* VkZPipeline;
typedef struct VkZPipelineLayout_T* VkZPipelineLayout;
typedef struct VkZRenderPass_T* VkZRenderPass;

#define VK_Z_SUCCESS 0
#define VK_Z_ERROR_INITIALIZATION_FAILED (-3)

// VkPipelineBindPoint
typedef enum {
    VK_Z_PIPELINE_BIND_POINT_GRAPHICS = 0,
    VK_Z_PIPELINE_BIND_POINT_COMPUTE = 1,
} VkZPipelineBindPoint;

typedef enum {
    VK_Z_VERTEX_INPUT_RATE_VERTEX = 0,
    VK_Z_VERTEX_INPUT_RATE_INSTANCE = 1,
} VkZVertexInputRate;

typedef struct {
    uint32_t binding;
    uint32_t stride;
    VkZVertexInputRate inputRate;
} VkZVertexInputBindingDescription;

typedef struct {
    uint32_t location;
    uint32_t binding;
    int32_t format;
    uint32_t offset;
} VkZVertexInputAttributeDescription;

typedef struct {
    int32_t sType;                   // VkStructureType
    const void* pNext;
    uint32_t flags;
    uint32_t vertexBindingDescriptionCount;
    const VkZVertexInputBindingDescription* pVertexBindingDescriptions;
    uint32_t vertexAttributeDescriptionCount;
    const VkZVertexInputAttributeDescription* pVertexAttributeDescriptions;
} VkZPipelineVertexInputStateCreateInfo;

// Full VkGraphicsPipelineCreateInfo layout (matching vulkan_core.h, 64-bit)
typedef struct {
    int32_t sType;                   // VkStructureType
    const void* pNext;
    uint32_t flags;
    uint32_t stageCount;
    const void* pStages;             // const VkPipelineShaderStageCreateInfo*
    const VkZPipelineVertexInputStateCreateInfo* pVertexInputState;
    const void* pInputAssemblyState;
    const void* pTessellationState;
    const void* pViewportState;
    const void* pRasterizationState;
    const void* pMultisampleState;
    const void* pDepthStencilState;
    const void* pColorBlendState;
    const void* pDynamicState;
    VkZPipelineLayout layout;
    VkZRenderPass renderPass;
    uint32_t subpass;
    VkZPipeline basePipelineHandle;
    int32_t basePipelineIndex;
} VkZGraphicsPipelineCreateInfo;

typedef VkZResult (*PFN_zkCreateGraphicsPipelines)(
    VkZDevice, VkZPipelineCache, uint32_t,
    const VkZGraphicsPipelineCreateInfo*, const void*, VkZPipeline*);
typedef void* (*PFN_zkGetInstanceProcAddr)(VkZInstance, const char*);
typedef void* (*PFN_zkGetDeviceProcAddr)(VkZDevice, const char*);

// vkCmd* function pointer types (used to skip draws for dummy pipelines)
// The parameter counts match the standard Vulkan signatures (vulkan_core.h) exactly, to avoid disagreeing with the function implementations
typedef void (*PFN_zkCmdBindPipeline)(VkZCommandBuffer, VkZPipelineBindPoint, VkZPipeline);
typedef void (*PFN_zkCmdDraw)(VkZCommandBuffer, uint32_t, uint32_t, uint32_t, uint32_t);
typedef void (*PFN_zkCmdDrawIndexed)(VkZCommandBuffer, uint32_t, uint32_t, uint32_t, int32_t, uint32_t);
// vkCmdDrawIndirect(cmd, buffer, offset, drawCount, stride) - 5 parameters
typedef void (*PFN_zkCmdDrawIndirect)(VkZCommandBuffer, uint64_t, uint64_t, uint32_t, uint32_t);
typedef void (*PFN_zkCmdDrawIndexedIndirect)(VkZCommandBuffer, uint64_t, uint64_t, uint32_t, uint32_t);
// vkCmdDrawIndirectCount(cmd, buffer, offset, countBuffer, countBufferOffset, maxDrawCount, stride) - 7 parameters
typedef void (*PFN_zkCmdDrawIndirectCount)(VkZCommandBuffer, uint64_t, uint64_t, uint64_t, uint64_t, uint32_t, uint32_t);
typedef void (*PFN_zkCmdDrawIndexedIndirectCount)(VkZCommandBuffer, uint64_t, uint64_t, uint64_t, uint64_t, uint32_t, uint32_t);
// vkDestroyPipeline(device, pipeline, pAllocator) - 3 parameters
// Must be hooked: when zink destroys a dummy pipeline, MoltenVK dereferences the magic handle and crashes
typedef void (*PFN_zkDestroyPipeline)(VkZDevice, VkZPipeline, const void*);

// Stride fix state (g_zinkStrideFixActive is forward declared earlier in the file)
static PFN_zkGetInstanceProcAddr g_real_vkGetInstanceProcAddr = NULL;
static PFN_zkGetDeviceProcAddr g_real_vkGetDeviceProcAddr = NULL;
static PFN_zkCreateGraphicsPipelines g_real_vkCreateGraphicsPipelines = NULL;

// Real vkCmd* function pointers (needed to skip draws for dummy pipelines)
static PFN_zkCmdBindPipeline g_real_vkCmdBindPipeline = NULL;
static PFN_zkCmdDraw g_real_vkCmdDraw = NULL;
static PFN_zkCmdDrawIndexed g_real_vkCmdDrawIndexed = NULL;
static PFN_zkCmdDrawIndirect g_real_vkCmdDrawIndirect = NULL;
static PFN_zkCmdDrawIndexedIndirect g_real_vkCmdDrawIndexedIndirect = NULL;
static PFN_zkCmdDrawIndirectCount g_real_vkCmdDrawIndirectCount = NULL;
static PFN_zkCmdDrawIndexedIndirectCount g_real_vkCmdDrawIndexedIndirectCount = NULL;
// Real vkDestroyPipeline function pointer (needed to destroy dummy pipelines)
static PFN_zkDestroyPipeline g_real_vkDestroyPipeline = NULL;

// ============================================================================
// The dummy pipeline mechanism (fixes the zink + Mesa 25.0.7 shader SIGSEGV)
// ============================================================================
// The problem:
//   Mesa 25.0.7 zink validates the SPIR-V shader interface more strictly than 21.0.0 did.
//   When the fragment shader of a shader pack (such as BSL or Mellow Shader) declares an input the vertex shader
//   never writes (such as user(locn1_2)), MoltenVK returns VK_ERROR_INITIALIZATION_FAILED from
//   vkCreateGraphicsPipelines.
//
//   zink's update_gfx_pipeline does not handle that failure correctly:
//   the Vulkan spec says pPipelines[i] is set to VK_NULL_HANDLE when vkCreateGraphicsPipelines fails,
//   and zink then uses the NULL pipeline handle, causing a SIGSEGV.
//
// The solution (dummy pipeline + skipped draws):
//   1. When vkCreateGraphicsPipelines fails, do not report failure: return VK_SUCCESS
//      and hand out a dummy handle (a non-NULL magic value) for each failed pipeline.
//   2. Maintain a set of dummy pipelines.
//   3. Hook vkCmdBindPipeline: track the currently bound pipeline and skip the bind if it is a dummy.
//   4. Hook vkCmdDraw*: skip the draw if the currently bound pipeline is a dummy.
//
//   This way zink believes pipeline creation succeeded and does not SIGSEGV,
//   and the geometry belonging to the failed pipeline is simply not drawn (black/missing, but no crash).
//   Pipelines that were created successfully render normally and the shader effects are preserved.

#define ZINK_DUMMY_PIPELINE_MAGIC 0xDEAD0000ULL
#define ZINK_DUMMY_PIPELINE_MAX 4096

// The dummy pipeline set (a simple array with a linear search; the number of dummy pipelines is usually very small)
static uintptr_t g_dummyPipelines[ZINK_DUMMY_PIPELINE_MAX];
static uint32_t g_dummyPipelineCount = 0;
// The currently bound graphics pipeline (used to decide whether a draw should be skipped)
// Note: there may be several VkCommandBuffers, but zink renders single-threaded so a global variable is sufficient
static VkZPipeline g_currentBoundGraphicsPipeline = NULL;

/// Determine whether a pipeline is a dummy
static BOOL isDummyPipeline(VkZPipeline pipeline) {
    if (!pipeline) return NO;
    uintptr_t val = (uintptr_t)pipeline;
    if ((val & 0xFFFF0000ULL) != ZINK_DUMMY_PIPELINE_MAGIC) return NO;
    // Binary or linear search (there are usually <100 dummy pipelines, so a linear search is enough)
    for (uint32_t i = 0; i < g_dummyPipelineCount; i++) {
        if (g_dummyPipelines[i] == val) return YES;
    }
    return NO;
}

/// Allocate a new dummy pipeline handle
static VkZPipeline allocDummyPipeline(void) {
    if (g_dummyPipelineCount >= ZINK_DUMMY_PIPELINE_MAX) {
        // Overflow: reuse the first one (an extreme case that almost never happens)
        NSLog(@"[ZinkStrideFix] WARNING: dummy pipeline pool exhausted, reusing slot 0");
        return (VkZPipeline)g_dummyPipelines[0];
    }
    uintptr_t handle = ZINK_DUMMY_PIPELINE_MAGIC | (g_dummyPipelineCount + 1);
    g_dummyPipelines[g_dummyPipelineCount++] = handle;
    return (VkZPipeline)handle;
}

// Forward declaration (used by zinkStrideFixRebind)
static void* amethyst_vkGetInstanceProcAddr(VkZInstance instance, const char* pName);
static void* amethyst_vkGetDeviceProcAddr(VkZDevice device, const char* pName);
static VkZResult amethyst_vkCreateGraphicsPipelines(
    VkZDevice device, VkZPipelineCache pipelineCache, uint32_t createInfoCount,
    const VkZGraphicsPipelineCreateInfo* pCreateInfos, const void* pAllocator,
    VkZPipeline* pPipelines);
static void amethyst_vkCmdBindPipeline(VkZCommandBuffer cmd, VkZPipelineBindPoint bp, VkZPipeline pipeline);
static void amethyst_vkCmdDraw(VkZCommandBuffer cmd, uint32_t vertexCount, uint32_t instanceCount, uint32_t firstVertex, uint32_t firstInstance);
static void amethyst_vkCmdDrawIndexed(VkZCommandBuffer cmd, uint32_t indexCount, uint32_t instanceCount, uint32_t firstIndex, int32_t vertexOffset, uint32_t firstInstance);
static void amethyst_vkCmdDrawIndirect(VkZCommandBuffer cmd, uint64_t buffer, uint64_t offset, uint32_t drawCount, uint32_t stride);
static void amethyst_vkCmdDrawIndexedIndirect(VkZCommandBuffer cmd, uint64_t buffer, uint64_t offset, uint32_t drawCount, uint32_t stride);
static void amethyst_vkCmdDrawIndirectCount(VkZCommandBuffer cmd, uint64_t buffer, uint64_t offset, uint64_t countBuffer, uint64_t countBufferOffset, uint32_t maxDrawCount, uint32_t stride);
static void amethyst_vkCmdDrawIndexedIndirectCount(VkZCommandBuffer cmd, uint64_t buffer, uint64_t offset, uint64_t countBuffer, uint64_t countBufferOffset, uint32_t maxDrawCount, uint32_t stride);
static void amethyst_vkDestroyPipeline(VkZDevice device, VkZPipeline pipeline, const void* pAllocator);

// ============================================================================
// UINT→SINT vertex attribute format conversion (fixes MTLAttributeFormatUShort3 conversion failures)
// ============================================================================
// The problem:
//   When MoltenVK compiles a pipeline, if a vertex attribute uses a UINT format (such as
//   VK_FORMAT_R16G16B16_UINT → MTLAttributeFormatUShort3) while the input declared by the shader
//   is a signed integer type (int/ivec3), Metal cannot convert the format automatically and returns an error.
//   VK_ERROR_INITIALIZATION_FAILED：
//   "Cannot convert attribute from MTLAttributeFormatUShort3 to a signed integer type."
//
//   This happens frequently with Iris shaders + Mesa 25.0.7 zink, making entity rendering pipeline creation
//   fail; after the dummy pipeline fallback replaces it, entities are not rendered (black/missing).
//
// The solution:
//   When pipeline creation fails the first time, it is retried once with every UINT vertex attribute
//   converted to the matching SINT format (e.g. R16G16B16_UINT → R16G16B16_SINT).
//   Metal then parses the bytes as signed, matching what the shader expects.
//   For most vertex attributes (bone indices, coordinates and so on) the values are small, so signed and unsigned parsing
//   give the same result and no rendering errors are introduced.

/// Determine whether a Vulkan format is a UINT type
/// The Vulkan format enum values come from vulkan_core.h:
///   R8_UINT=9, R8G8_UINT=11, R8G8B8_UINT=13, R8G8B8A8_UINT=42
///   R16_UINT=76, R16G16_UINT=78, R16G16B16_UINT=80, R16G16B16A16_UINT=82
///   R32_UINT=96, R32G32_UINT=98, R32G32B32_UINT=100, R32G32B32A32_UINT=102
static BOOL isVkUIntFormat(int32_t format) {
    switch (format) {
        case 9:   // VK_FORMAT_R8_UINT
        case 11:  // VK_FORMAT_R8G8_UINT
        case 13:  // VK_FORMAT_R8G8B8_UINT
        case 42:  // VK_FORMAT_R8G8B8A8_UINT
        case 76:  // VK_FORMAT_R16_UINT
        case 78:  // VK_FORMAT_R16G16_UINT
        case 80:  // VK_FORMAT_R16G16B16_UINT
        case 82:  // VK_FORMAT_R16G16B16A16_UINT
        case 96:  // VK_FORMAT_R32_UINT
        case 98:  // VK_FORMAT_R32G32_UINT
        case 100: // VK_FORMAT_R32G32B32_UINT
        case 102: // VK_FORMAT_R32G32B32A32_UINT
            return YES;
        default:
            return NO;
    }
}

/// Convert a UINT format to the matching SINT format
/// In the Vulkan format enum, UINT and SINT are adjacent (UINT+1 = SINT):
///   R8_UINT(9) → R8_SINT(10), R8G8_UINT(11) → R8G8_SINT(12), ...
static int32_t convertVkUIntToSIntFormat(int32_t format) {
    switch (format) {
        case 9:   return 10;   // R8_UINT → R8_SINT
        case 11:  return 12;   // R8G8_UINT → R8G8_SINT
        case 13:  return 14;   // R8G8B8_UINT → R8G8B8_SINT
        case 42:  return 43;   // R8G8B8A8_UINT → R8G8B8A8_SINT
        case 76:  return 77;   // R16_UINT → R16_SINT
        case 78:  return 79;   // R16G16_UINT → R16G16_SINT
        case 80:  return 81;   // R16G16B16_UINT → R16G16B16_SINT
        case 82:  return 83;   // R16G16B16A16_UINT → R16G16B16A16_SINT
        case 96:  return 97;   // R32_UINT → R32_SINT
        case 98:  return 99;   // R32G32_UINT → R32G32_SINT
        case 100: return 101;  // R32G32B32_UINT → R32G32B32_SINT
        case 102: return 103;  // R32G32B32A32_UINT → R32G32B32A32_SINT
        default:  return format;
    }
}

/// Check whether the pipeline create infos contain any vertex attribute with a UINT format
static BOOL pipelineCreateInfosHaveUIntFormat(
    uint32_t createInfoCount,
    const VkZGraphicsPipelineCreateInfo* pCreateInfos)
{
    for (uint32_t i = 0; i < createInfoCount; i++) {
        const VkZPipelineVertexInputStateCreateInfo* vis = pCreateInfos[i].pVertexInputState;
        if (!vis || !vis->pVertexAttributeDescriptions) continue;
        for (uint32_t j = 0; j < vis->vertexAttributeDescriptionCount; j++) {
            if (isVkUIntFormat(vis->pVertexAttributeDescriptions[j].format)) {
                return YES;
            }
        }
    }
    return NO;
}

/// Retry pipeline creation with the UINT vertex attribute formats converted to SINT
/// Optionally align the stride as well (for use in combination with the stride alignment fix)
/// Returns the result of calling the real function
static VkZResult retryPipelineWithSIntFormats(
    VkZDevice device, VkZPipelineCache pipelineCache, uint32_t createInfoCount,
    const VkZGraphicsPipelineCreateInfo* pCreateInfos, const void* pAllocator,
    VkZPipeline* pPipelines,
    BOOL alsoAlignStrides)
{
    if (!g_real_vkCreateGraphicsPipelines) {
        return VK_Z_ERROR_INITIALIZATION_FAILED;
    }

    // Retrying is pointless if there is no UINT format
    if (!pipelineCreateInfosHaveUIntFormat(createInfoCount, pCreateInfos)) {
        return VK_Z_ERROR_INITIALIZATION_FAILED;
    }

    NSLog(@"[ZinkStrideFix] Retrying pipeline creation with UINT→SINT format conversion%s",
          alsoAlignStrides ? " + stride alignment" : "");

    // Deep copy and apply the format conversion (plus optional stride alignment)
    VkZGraphicsPipelineCreateInfo* newCreateInfos = malloc(sizeof(VkZGraphicsPipelineCreateInfo) * createInfoCount);
    VkZPipelineVertexInputStateCreateInfo* newVIS = malloc(sizeof(VkZPipelineVertexInputStateCreateInfo) * createInfoCount);
    VkZVertexInputBindingDescription** allocedBindings = calloc(createInfoCount, sizeof(VkZVertexInputBindingDescription*));
    VkZVertexInputAttributeDescription** allocedAttrs = calloc(createInfoCount, sizeof(VkZVertexInputAttributeDescription*));

    memcpy(newCreateInfos, pCreateInfos, sizeof(VkZGraphicsPipelineCreateInfo) * createInfoCount);

    for (uint32_t i = 0; i < createInfoCount; i++) {
        const VkZPipelineVertexInputStateCreateInfo* vis = pCreateInfos[i].pVertexInputState;
        if (!vis) continue;

        newVIS[i] = *vis;

        // Format conversion: UINT → SINT
        if (vis->pVertexAttributeDescriptions && vis->vertexAttributeDescriptionCount > 0) {
            uint32_t attrCount = vis->vertexAttributeDescriptionCount;
            VkZVertexInputAttributeDescription* newAttrs = malloc(sizeof(VkZVertexInputAttributeDescription) * attrCount);
            memcpy(newAttrs, vis->pVertexAttributeDescriptions, sizeof(VkZVertexInputAttributeDescription) * attrCount);
            for (uint32_t j = 0; j < attrCount; j++) {
                if (isVkUIntFormat(newAttrs[j].format)) {
                    int32_t oldFmt = newAttrs[j].format;
                    newAttrs[j].format = convertVkUIntToSIntFormat(newAttrs[j].format);
                    NSLog(@"[ZinkStrideFix] Pipeline %u attr %u: format %d -> %d (UINT→SINT)",
                          i, j, oldFmt, newAttrs[j].format);
                }
            }
            allocedAttrs[i] = newAttrs;
            newVIS[i].pVertexAttributeDescriptions = newAttrs;
        }

        // Optional: stride alignment
        if (alsoAlignStrides && vis->pVertexBindingDescriptions) {
            BOOL pipelineNeedsAlignment = NO;
            for (uint32_t j = 0; j < vis->vertexBindingDescriptionCount; j++) {
                if (vis->pVertexBindingDescriptions[j].stride & 3) {
                    pipelineNeedsAlignment = YES;
                    break;
                }
            }
            if (pipelineNeedsAlignment) {
                uint32_t bindingCount = vis->vertexBindingDescriptionCount;
                VkZVertexInputBindingDescription* newBindings = malloc(sizeof(VkZVertexInputBindingDescription) * bindingCount);
                memcpy(newBindings, vis->pVertexBindingDescriptions, sizeof(VkZVertexInputBindingDescription) * bindingCount);
                for (uint32_t j = 0; j < bindingCount; j++) {
                    uint32_t oldStride = newBindings[j].stride;
                    uint32_t newStride = (oldStride + 3) & ~3u;
                    if (newStride != oldStride) {
                        NSLog(@"[ZinkStrideFix] Pipeline %u binding %u: stride %u -> %u",
                              i, j, oldStride, newStride);
                        newBindings[j].stride = newStride;
                    }
                }
                allocedBindings[i] = newBindings;
                newVIS[i].pVertexBindingDescriptions = newBindings;
            }
        }

        newCreateInfos[i].pVertexInputState = &newVIS[i];
    }

    VkZResult result = g_real_vkCreateGraphicsPipelines(device, pipelineCache, createInfoCount, newCreateInfos, pAllocator, pPipelines);

    for (uint32_t i = 0; i < createInfoCount; i++) {
        if (allocedBindings[i]) free(allocedBindings[i]);
        if (allocedAttrs[i]) free(allocedAttrs[i]);
    }
    free(allocedAttrs);
    free(allocedBindings);
    free(newVIS);
    free(newCreateInfos);

    return result;
}

/// Only align the vertex binding stride to 4 bytes (without converting formats) and call the real function
/// Used by amethyst_vkCreateGraphicsPipelines in strategy 3
static VkZResult createPipelinesWithAlignedStrides(
    VkZDevice device, VkZPipelineCache pipelineCache, uint32_t createInfoCount,
    const VkZGraphicsPipelineCreateInfo* pCreateInfos, const void* pAllocator,
    VkZPipeline* pPipelines)
{
    if (!g_real_vkCreateGraphicsPipelines) {
        return VK_Z_ERROR_INITIALIZATION_FAILED;
    }

    NSLog(@"[ZinkStrideFix] Aligning vertex binding strides for %u pipelines", createInfoCount);

    VkZGraphicsPipelineCreateInfo* newCreateInfos = malloc(sizeof(VkZGraphicsPipelineCreateInfo) * createInfoCount);
    VkZPipelineVertexInputStateCreateInfo* newVIS = malloc(sizeof(VkZPipelineVertexInputStateCreateInfo) * createInfoCount);
    VkZVertexInputBindingDescription** allocedBindings = calloc(createInfoCount, sizeof(VkZVertexInputBindingDescription*));

    memcpy(newCreateInfos, pCreateInfos, sizeof(VkZGraphicsPipelineCreateInfo) * createInfoCount);

    for (uint32_t i = 0; i < createInfoCount; i++) {
        const VkZPipelineVertexInputStateCreateInfo* vis = pCreateInfos[i].pVertexInputState;
        if (!vis || !vis->pVertexBindingDescriptions) continue;

        BOOL pipelineNeedsAlignment = NO;
        for (uint32_t j = 0; j < vis->vertexBindingDescriptionCount; j++) {
            if (vis->pVertexBindingDescriptions[j].stride & 3) {
                pipelineNeedsAlignment = YES;
                break;
            }
        }
        if (!pipelineNeedsAlignment) continue;

        uint32_t bindingCount = vis->vertexBindingDescriptionCount;
        VkZVertexInputBindingDescription* newBindings = malloc(sizeof(VkZVertexInputBindingDescription) * bindingCount);
        memcpy(newBindings, vis->pVertexBindingDescriptions, sizeof(VkZVertexInputBindingDescription) * bindingCount);
        for (uint32_t j = 0; j < bindingCount; j++) {
            uint32_t oldStride = newBindings[j].stride;
            uint32_t newStride = (oldStride + 3) & ~3u;
            if (newStride != oldStride) {
                NSLog(@"[ZinkStrideFix] Pipeline %u binding %u: stride %u -> %u", i, j, oldStride, newStride);
                newBindings[j].stride = newStride;
            }
        }
        allocedBindings[i] = newBindings;

        newVIS[i] = *vis;
        newVIS[i].pVertexBindingDescriptions = newBindings;
        newCreateInfos[i].pVertexInputState = &newVIS[i];
    }

    VkZResult result = g_real_vkCreateGraphicsPipelines(device, pipelineCache, createInfoCount, newCreateInfos, pAllocator, pPipelines);

    for (uint32_t i = 0; i < createInfoCount; i++) {
        if (allocedBindings[i]) free(allocedBindings[i]);
    }
    free(allocedBindings);
    free(newVIS);
    free(newCreateInfos);

    return result;
}

/// vkCreateGraphicsPipelines wrapper: tries several fix strategies to make pipeline creation succeed
///
/// Fix strategies (tried in order):
///   1. Create with the original stride (MoltenVK 1.2.9+ may already support unaligned strides)
///   2. UINT→SINT format conversion + the original stride (fixes MTLAttributeFormatUShort3 conversion errors)
///   3. 4-byte stride alignment (satisfies the strict Metal API requirement)
///   4. UINT→SINT format conversion + stride alignment (combined fix)
///   5. Dummy pipeline fallback (avoids the SIGSEGV a NULL pipeline would cause)
///
/// Key fix (garbled entity rendering):
///   The previous implementation always aligned the stride first (54→56), but the vertex buffer data was still laid out
///   with the original stride of 54, so MoltenVK read the data with the aligned stride of 56 while the data layout did not match,
///   producing garbled entity rendering.
///   The new implementation tries the original stride first and only falls back to stride alignment when MoltenVK
///   rejects the unaligned stride. That way, on MoltenVK versions that support unaligned strides, the stride matches the data
///   layout and rendering is correct.
static VkZResult amethyst_vkCreateGraphicsPipelines(
    VkZDevice device, VkZPipelineCache pipelineCache, uint32_t createInfoCount,
    const VkZGraphicsPipelineCreateInfo* pCreateInfos, const void* pAllocator,
    VkZPipeline* pPipelines)
{
    // Resolve the real function pointers on the first call
    if (!g_real_vkCreateGraphicsPipelines) {
        if (g_real_vkGetDeviceProcAddr) {
            g_real_vkCreateGraphicsPipelines = (PFN_zkCreateGraphicsPipelines)
                g_real_vkGetDeviceProcAddr(device, "vkCreateGraphicsPipelines");
        }
        if (!g_real_vkCreateGraphicsPipelines && g_real_vkGetInstanceProcAddr) {
            g_real_vkCreateGraphicsPipelines = (PFN_zkCreateGraphicsPipelines)
                g_real_vkGetInstanceProcAddr((VkZInstance)NULL, "vkCreateGraphicsPipelines");
        }
        if (!g_real_vkCreateGraphicsPipelines) {
            // Use amethyst_orig_dlsym to bypass the hook (hooked_dlsym does not intercept this function name,
            // but keeping it consistent avoids introducing recursion if the hook list is extended in the future)
            g_real_vkCreateGraphicsPipelines = (PFN_zkCreateGraphicsPipelines)
                amethyst_orig_dlsym(RTLD_DEFAULT, "vkCreateGraphicsPipelines");
        }
        NSLog(@"[ZinkStrideFix] real vkCreateGraphicsPipelines = %p", (void*)g_real_vkCreateGraphicsPipelines);
    }

    if (!g_real_vkCreateGraphicsPipelines) {
        NSLog(@"[ZinkStrideFix] FATAL: real vkCreateGraphicsPipelines is NULL");
        return VK_Z_ERROR_INITIALIZATION_FAILED;
    }

    // Pre-check: is stride alignment needed / is there a UINT format
    BOOL needsAlignment = NO;
    for (uint32_t i = 0; i < createInfoCount; i++) {
        const VkZPipelineVertexInputStateCreateInfo* vis = pCreateInfos[i].pVertexInputState;
        if (!vis || !vis->pVertexBindingDescriptions) continue;
        for (uint32_t j = 0; j < vis->vertexBindingDescriptionCount; j++) {
            if (vis->pVertexBindingDescriptions[j].stride & 3) {
                needsAlignment = YES;
                break;
            }
        }
        if (needsAlignment) break;
    }
    BOOL hasUIntFormat = pipelineCreateInfosHaveUIntFormat(createInfoCount, pCreateInfos);

    // ===== Strategy 1: create with the original stride =====
    // Try the original stride first, keeping the stride matched to the vertex buffer data layout.
    // MoltenVK 1.2.9+ may support unaligned strides through setVertexBuffer:offset:attributeStride:atIndex:
    // or another mechanism. This is the key to fixing the garbled entity rendering.
    {
        VkZResult result = g_real_vkCreateGraphicsPipelines(device, pipelineCache, createInfoCount, pCreateInfos, pAllocator, pPipelines);
        if (result == VK_Z_SUCCESS) {
            if (needsAlignment) {
                NSLog(@"[ZinkStrideFix] Pipeline created with original (unaligned) stride - MoltenVK accepted");
            }
            return result;
        }
        NSLog(@"[ZinkStrideFix] Strategy 1 (original stride) failed: %d", result);
        // Clear pPipelines (MoltenVK may have partially populated it on failure)
        for (uint32_t i = 0; i < createInfoCount; i++) pPipelines[i] = NULL;
    }

    // ===== Strategy 2: UINT→SINT format conversion + the original stride =====
    // Fixes MTLAttributeFormatUShort3 conversion errors while keeping the original stride
    if (hasUIntFormat) {
        NSLog(@"[ZinkStrideFix] Strategy 2: UINT→SINT format conversion (original stride)");
        VkZResult retryResult = retryPipelineWithSIntFormats(
            device, pipelineCache, createInfoCount, pCreateInfos, pAllocator, pPipelines, NO);
        if (retryResult == VK_Z_SUCCESS) {
            NSLog(@"[ZinkStrideFix] Strategy 2 succeeded (UINT→SINT, original stride)");
            return retryResult;
        }
        NSLog(@"[ZinkStrideFix] Strategy 2 failed: %d", retryResult);
        for (uint32_t i = 0; i < createInfoCount; i++) pPipelines[i] = NULL;
    }

    // ===== Strategy 3: 4-byte stride alignment =====
    // When MoltenVK rejects the unaligned stride, fall back to stride alignment.
    // Note: this can leave the stride mismatched with the vertex buffer data layout and garble the rendering,
    // but it avoids the SIGSEGV caused by pipeline creation failure.
    NSLog(@"[ZinkStrideFix] Strategy 3: stride 4-byte alignment");
    {
        VkZResult result = createPipelinesWithAlignedStrides(
            device, pipelineCache, createInfoCount, pCreateInfos, pAllocator, pPipelines);
        if (result == VK_Z_SUCCESS) {
            NSLog(@"[ZinkStrideFix] Strategy 3 succeeded (stride alignment)");
            return result;
        }
        NSLog(@"[ZinkStrideFix] Strategy 3 failed: %d", result);
        for (uint32_t i = 0; i < createInfoCount; i++) pPipelines[i] = NULL;
    }

    // ===== Strategy 4: UINT→SINT format conversion + stride alignment =====
    if (hasUIntFormat) {
        NSLog(@"[ZinkStrideFix] Strategy 4: UINT→SINT + stride alignment");
        VkZResult retryResult = retryPipelineWithSIntFormats(
            device, pipelineCache, createInfoCount, pCreateInfos, pAllocator, pPipelines, YES);
        if (retryResult == VK_Z_SUCCESS) {
            NSLog(@"[ZinkStrideFix] Strategy 4 succeeded (UINT→SINT + stride alignment)");
            return retryResult;
        }
        NSLog(@"[ZinkStrideFix] Strategy 4 failed: %d", retryResult);
        for (uint32_t i = 0; i < createInfoCount; i++) pPipelines[i] = NULL;
    }

    // ===== Strategy 5: dummy pipeline fallback =====
    // Every fix strategy failed, so hand out a dummy pipeline to avoid the SIGSEGV a NULL pipeline would cause.
    // Draw calls for a dummy pipeline are skipped by our hooks (entities are not rendered, but nothing crashes).
    NSLog(@"[ZinkStrideFix] All strategies failed, applying dummy pipeline fallback");
    for (uint32_t i = 0; i < createInfoCount; i++) {
        if (!pPipelines[i]) {
            pPipelines[i] = allocDummyPipeline();
            NSLog(@"[ZinkStrideFix] Pipeline %u: allocated dummy handle %p", i, (void*)pPipelines[i]);
        }
    }
    return VK_Z_SUCCESS;
}

/// vkGetInstanceProcAddr wrapper
/// Intercepts vkGetDeviceProcAddr, vkCreateGraphicsPipelines and vkCmd* requests and returns our hooks
static void* amethyst_vkGetInstanceProcAddr(VkZInstance instance, const char* pName) {
    if (pName) {
        if (strcmp(pName, "vkGetDeviceProcAddr") == 0) {
            if (!g_real_vkGetDeviceProcAddr && g_real_vkGetInstanceProcAddr) {
                g_real_vkGetDeviceProcAddr = (PFN_zkGetDeviceProcAddr)
                    g_real_vkGetInstanceProcAddr(instance, pName);
            }
            return (void*)amethyst_vkGetDeviceProcAddr;
        }
        if (strcmp(pName, "vkCreateGraphicsPipelines") == 0) {
            if (!g_real_vkCreateGraphicsPipelines && g_real_vkGetInstanceProcAddr) {
                g_real_vkCreateGraphicsPipelines = (PFN_zkCreateGraphicsPipelines)
                    g_real_vkGetInstanceProcAddr(instance, pName);
            }
            return (void*)amethyst_vkCreateGraphicsPipelines;
        }
        // vkCmd* hooks（dummy pipeline skip draws）
        if (strcmp(pName, "vkCmdBindPipeline") == 0) {
            if (!g_real_vkCmdBindPipeline && g_real_vkGetInstanceProcAddr) {
                g_real_vkCmdBindPipeline = (PFN_zkCmdBindPipeline)
                    g_real_vkGetInstanceProcAddr(instance, pName);
            }
            return (void*)amethyst_vkCmdBindPipeline;
        }
        if (strcmp(pName, "vkCmdDraw") == 0) {
            if (!g_real_vkCmdDraw && g_real_vkGetInstanceProcAddr) {
                g_real_vkCmdDraw = (PFN_zkCmdDraw)
                    g_real_vkGetInstanceProcAddr(instance, pName);
            }
            return (void*)amethyst_vkCmdDraw;
        }
        if (strcmp(pName, "vkCmdDrawIndexed") == 0) {
            if (!g_real_vkCmdDrawIndexed && g_real_vkGetInstanceProcAddr) {
                g_real_vkCmdDrawIndexed = (PFN_zkCmdDrawIndexed)
                    g_real_vkGetInstanceProcAddr(instance, pName);
            }
            return (void*)amethyst_vkCmdDrawIndexed;
        }
        if (strcmp(pName, "vkCmdDrawIndirect") == 0) {
            if (!g_real_vkCmdDrawIndirect && g_real_vkGetInstanceProcAddr) {
                g_real_vkCmdDrawIndirect = (PFN_zkCmdDrawIndirect)
                    g_real_vkGetInstanceProcAddr(instance, pName);
            }
            return (void*)amethyst_vkCmdDrawIndirect;
        }
        if (strcmp(pName, "vkCmdDrawIndexedIndirect") == 0) {
            if (!g_real_vkCmdDrawIndexedIndirect && g_real_vkGetInstanceProcAddr) {
                g_real_vkCmdDrawIndexedIndirect = (PFN_zkCmdDrawIndexedIndirect)
                    g_real_vkGetInstanceProcAddr(instance, pName);
            }
            return (void*)amethyst_vkCmdDrawIndexedIndirect;
        }
        if (strcmp(pName, "vkCmdDrawIndirectCount") == 0) {
            if (!g_real_vkCmdDrawIndirectCount && g_real_vkGetInstanceProcAddr) {
                g_real_vkCmdDrawIndirectCount = (PFN_zkCmdDrawIndirectCount)
                    g_real_vkGetInstanceProcAddr(instance, pName);
            }
            return (void*)amethyst_vkCmdDrawIndirectCount;
        }
        if (strcmp(pName, "vkCmdDrawIndexedIndirectCount") == 0) {
            if (!g_real_vkCmdDrawIndexedIndirectCount && g_real_vkGetInstanceProcAddr) {
                g_real_vkCmdDrawIndexedIndirectCount = (PFN_zkCmdDrawIndexedIndirectCount)
                    g_real_vkGetInstanceProcAddr(instance, pName);
            }
            return (void*)amethyst_vkCmdDrawIndexedIndirectCount;
        }
        // vkDestroyPipeline hook: skip destruction of dummy pipelines to avoid crashing MoltenVK
        if (strcmp(pName, "vkDestroyPipeline") == 0) {
            if (!g_real_vkDestroyPipeline && g_real_vkGetInstanceProcAddr) {
                g_real_vkDestroyPipeline = (PFN_zkDestroyPipeline)
                    g_real_vkGetInstanceProcAddr(instance, pName);
            }
            return (void*)amethyst_vkDestroyPipeline;
        }
    }
    if (!g_real_vkGetInstanceProcAddr) {
        // Key point: amethyst_orig_dlsym must be used to bypass hooked_dlsym, otherwise a pName
        // that happens to be "vkGetInstanceProcAddr" would trigger infinite recursion
        return amethyst_orig_dlsym(RTLD_DEFAULT, pName);
    }
    return g_real_vkGetInstanceProcAddr(instance, pName);
}

/// vkGetDeviceProcAddr wrapper
/// Intercepts vkCreateGraphicsPipelines and vkCmd* requests and returns our hooks
static void* amethyst_vkGetDeviceProcAddr(VkZDevice device, const char* pName) {
    if (pName) {
        if (strcmp(pName, "vkCreateGraphicsPipelines") == 0) {
            if (!g_real_vkCreateGraphicsPipelines && g_real_vkGetDeviceProcAddr) {
                g_real_vkCreateGraphicsPipelines = (PFN_zkCreateGraphicsPipelines)
                    g_real_vkGetDeviceProcAddr(device, pName);
            }
            return (void*)amethyst_vkCreateGraphicsPipelines;
        }
        // vkCmd* hooks（dummy pipeline skip draws）
        if (strcmp(pName, "vkCmdBindPipeline") == 0) {
            if (!g_real_vkCmdBindPipeline && g_real_vkGetDeviceProcAddr) {
                g_real_vkCmdBindPipeline = (PFN_zkCmdBindPipeline)
                    g_real_vkGetDeviceProcAddr(device, pName);
            }
            return (void*)amethyst_vkCmdBindPipeline;
        }
        if (strcmp(pName, "vkCmdDraw") == 0) {
            if (!g_real_vkCmdDraw && g_real_vkGetDeviceProcAddr) {
                g_real_vkCmdDraw = (PFN_zkCmdDraw)
                    g_real_vkGetDeviceProcAddr(device, pName);
            }
            return (void*)amethyst_vkCmdDraw;
        }
        if (strcmp(pName, "vkCmdDrawIndexed") == 0) {
            if (!g_real_vkCmdDrawIndexed && g_real_vkGetDeviceProcAddr) {
                g_real_vkCmdDrawIndexed = (PFN_zkCmdDrawIndexed)
                    g_real_vkGetDeviceProcAddr(device, pName);
            }
            return (void*)amethyst_vkCmdDrawIndexed;
        }
        if (strcmp(pName, "vkCmdDrawIndirect") == 0) {
            if (!g_real_vkCmdDrawIndirect && g_real_vkGetDeviceProcAddr) {
                g_real_vkCmdDrawIndirect = (PFN_zkCmdDrawIndirect)
                    g_real_vkGetDeviceProcAddr(device, pName);
            }
            return (void*)amethyst_vkCmdDrawIndirect;
        }
        if (strcmp(pName, "vkCmdDrawIndexedIndirect") == 0) {
            if (!g_real_vkCmdDrawIndexedIndirect && g_real_vkGetDeviceProcAddr) {
                g_real_vkCmdDrawIndexedIndirect = (PFN_zkCmdDrawIndexedIndirect)
                    g_real_vkGetDeviceProcAddr(device, pName);
            }
            return (void*)amethyst_vkCmdDrawIndexedIndirect;
        }
        if (strcmp(pName, "vkCmdDrawIndirectCount") == 0) {
            if (!g_real_vkCmdDrawIndirectCount && g_real_vkGetDeviceProcAddr) {
                g_real_vkCmdDrawIndirectCount = (PFN_zkCmdDrawIndirectCount)
                    g_real_vkGetDeviceProcAddr(device, pName);
            }
            return (void*)amethyst_vkCmdDrawIndirectCount;
        }
        if (strcmp(pName, "vkCmdDrawIndexedIndirectCount") == 0) {
            if (!g_real_vkCmdDrawIndexedIndirectCount && g_real_vkGetDeviceProcAddr) {
                g_real_vkCmdDrawIndexedIndirectCount = (PFN_zkCmdDrawIndexedIndirectCount)
                    g_real_vkGetDeviceProcAddr(device, pName);
            }
            return (void*)amethyst_vkCmdDrawIndexedIndirectCount;
        }
        // vkDestroyPipeline hook: skip destruction of dummy pipelines to avoid crashing MoltenVK
        if (strcmp(pName, "vkDestroyPipeline") == 0) {
            if (!g_real_vkDestroyPipeline && g_real_vkGetDeviceProcAddr) {
                g_real_vkDestroyPipeline = (PFN_zkDestroyPipeline)
                    g_real_vkGetDeviceProcAddr(device, pName);
            }
            return (void*)amethyst_vkDestroyPipeline;
        }
    }
    if (!g_real_vkGetDeviceProcAddr) {
        // Key point: amethyst_orig_dlsym must be used to bypass hooked_dlsym, otherwise a pName
        // that happens to be "vkGetDeviceProcAddr" would trigger infinite recursion
        return amethyst_orig_dlsym(RTLD_DEFAULT, pName);
    }
    return g_real_vkGetDeviceProcAddr(device, pName);
}

/// vkCmdBindPipeline hook
/// Tracks the currently bound graphics pipeline and skips the actual bind for dummy pipelines
static void amethyst_vkCmdBindPipeline(VkZCommandBuffer cmd, VkZPipelineBindPoint bp, VkZPipeline pipeline) {
    if (bp == VK_Z_PIPELINE_BIND_POINT_GRAPHICS) {
        g_currentBoundGraphicsPipeline = pipeline;
        if (isDummyPipeline(pipeline)) {
            // Dummy pipeline: skip the actual bind so MoltenVK does not crash on the invalid handle
            return;
        }
    }
    if (g_real_vkCmdBindPipeline) {
        g_real_vkCmdBindPipeline(cmd, bp, pipeline);
    }
}

/// vkCmdDraw hook: skip the draw when a dummy pipeline is currently bound
static void amethyst_vkCmdDraw(VkZCommandBuffer cmd, uint32_t vertexCount, uint32_t instanceCount, uint32_t firstVertex, uint32_t firstInstance) {
    if (isDummyPipeline(g_currentBoundGraphicsPipeline)) return;
    if (g_real_vkCmdDraw) g_real_vkCmdDraw(cmd, vertexCount, instanceCount, firstVertex, firstInstance);
}

/// vkCmdDrawIndexed hook: skip the draw when a dummy pipeline is currently bound
static void amethyst_vkCmdDrawIndexed(VkZCommandBuffer cmd, uint32_t indexCount, uint32_t instanceCount, uint32_t firstIndex, int32_t vertexOffset, uint32_t firstInstance) {
    if (isDummyPipeline(g_currentBoundGraphicsPipeline)) return;
    if (g_real_vkCmdDrawIndexed) g_real_vkCmdDrawIndexed(cmd, indexCount, instanceCount, firstIndex, vertexOffset, firstInstance);
}

/// vkCmdDrawIndirect hook: skip the draw when a dummy pipeline is currently bound
static void amethyst_vkCmdDrawIndirect(VkZCommandBuffer cmd, uint64_t buffer, uint64_t offset, uint32_t drawCount, uint32_t stride) {
    if (isDummyPipeline(g_currentBoundGraphicsPipeline)) return;
    if (g_real_vkCmdDrawIndirect) g_real_vkCmdDrawIndirect(cmd, buffer, offset, drawCount, stride);
}

/// vkCmdDrawIndexedIndirect hook: skip the draw when a dummy pipeline is currently bound
static void amethyst_vkCmdDrawIndexedIndirect(VkZCommandBuffer cmd, uint64_t buffer, uint64_t offset, uint32_t drawCount, uint32_t stride) {
    if (isDummyPipeline(g_currentBoundGraphicsPipeline)) return;
    if (g_real_vkCmdDrawIndexedIndirect) g_real_vkCmdDrawIndexedIndirect(cmd, buffer, offset, drawCount, stride);
}

/// vkCmdDrawIndirectCount hook: skip the draw when a dummy pipeline is currently bound
static void amethyst_vkCmdDrawIndirectCount(VkZCommandBuffer cmd, uint64_t buffer, uint64_t offset, uint64_t countBuffer, uint64_t countBufferOffset, uint32_t maxDrawCount, uint32_t stride) {
    if (isDummyPipeline(g_currentBoundGraphicsPipeline)) return;
    if (g_real_vkCmdDrawIndirectCount) g_real_vkCmdDrawIndirectCount(cmd, buffer, offset, countBuffer, countBufferOffset, maxDrawCount, stride);
}

/// vkCmdDrawIndexedIndirectCount hook: skip the draw when a dummy pipeline is currently bound
static void amethyst_vkCmdDrawIndexedIndirectCount(VkZCommandBuffer cmd, uint64_t buffer, uint64_t offset, uint64_t countBuffer, uint64_t countBufferOffset, uint32_t maxDrawCount, uint32_t stride) {
    if (isDummyPipeline(g_currentBoundGraphicsPipeline)) return;
    if (g_real_vkCmdDrawIndexedIndirectCount) g_real_vkCmdDrawIndexedIndirectCount(cmd, buffer, offset, countBuffer, countBufferOffset, maxDrawCount, stride);
}

/// vkDestroyPipeline hook: skip destroying dummy pipelines so MoltenVK does not crash dereferencing the magic handle
/// Key fix: when switching shader packs, zink destroys every old pipeline, including the dummy pipeline
/// handles (0xDEAD0001 and friends). MoltenVK's vkDestroyPipeline dereferences the pipeline pointer
/// to find internal resources, and a dummy handle is an invalid pointer, causing a SIGSEGV.
static void amethyst_vkDestroyPipeline(VkZDevice device, VkZPipeline pipeline, const void* pAllocator) {
    if (isDummyPipeline(pipeline)) {
        // Dummy pipeline: skip the destruction so MoltenVK does not crash
        // Also remove it from the dummy pipeline set (to keep the set from growing forever)
        uintptr_t val = (uintptr_t)pipeline;
        for (uint32_t i = 0; i < g_dummyPipelineCount; i++) {
            if (g_dummyPipelines[i] == val) {
                // Fill the hole with the last element (the order does not matter, the array is only used for lookups)
                g_dummyPipelines[i] = g_dummyPipelines[g_dummyPipelineCount - 1];
                g_dummyPipelineCount--;
                break;
            }
        }
        // If the dummy pipeline being destroyed happens to be the currently bound one, clear the bound state
        if (g_currentBoundGraphicsPipeline == pipeline) {
            g_currentBoundGraphicsPipeline = NULL;
        }
        return;
    }
    if (g_real_vkDestroyPipeline) g_real_vkDestroyPipeline(device, pipeline, pAllocator);
}

/// Internal: perform the fishhook rebinding (can be called again after a new image is loaded, to capture new references)
/// fishhook's rebind_symbols is idempotent - it walks every loaded image and rebinds
/// references to vkGetInstanceProcAddr / vkGetDeviceProcAddr to our wrappers.
/// A statically stored rebindings array is used (to avoid a use-after-free of a stack local when a future image loads:
/// fishhook keeps the rebindings around for images loaded by later dlopen calls).
static void zinkStrideFixRebind(void) {
    static struct rebinding rebindings[] = {
        {"vkGetInstanceProcAddr", (void*)amethyst_vkGetInstanceProcAddr, (void**)&g_real_vkGetInstanceProcAddr},
        {"vkGetDeviceProcAddr", (void*)amethyst_vkGetDeviceProcAddr, (void**)&g_real_vkGetDeviceProcAddr},
    };
    rebind_symbols(rebindings, sizeof(rebindings)/sizeof(struct rebinding));
}

/// Install the zink vertex stride alignment fix
/// Only active when the zink renderer is selected. It rebinds symbol references with fishhook
/// and intercepts dlsym lookups through hooked_dlsym (a dual mechanism that covers every call path).
void installZinkStrideFix(void) {
    if (g_zinkStrideFixActive) return;

    const char* renderer = getenv("AMETHYST_RENDERER");
    if (!renderer || !strstr(renderer, "libOSMesa")) {
        NSLog(@"[ZinkStrideFix] Skipped (zink not selected, AMETHYST_RENDERER=%s)",
              renderer ? renderer : "(null)");
        return;
    }

    g_zinkStrideFixActive = YES;

    // Initial rebind (captures references from the currently loaded images, mainly the launcher's main binary)
    zinkStrideFixRebind();

    NSLog(@"[ZinkStrideFix] Installed vertex stride alignment hooks for zink (Mesa 25.0.7 + MoltenVK)");
}

/// Called after a new image (particularly libOSMesa / libMoltenVK) is loaded, to run fishhook again
/// and capture that image's symbol references to vkGetInstanceProcAddr / vkGetDeviceProcAddr.
/// It is called by hooked_dlopen when it detects that libOSMesa has been loaded.
void rebindZinkStrideFixForNewImage(void) {
    if (!g_zinkStrideFixActive) return;
    zinkStrideFixRebind();
    NSLog(@"[ZinkStrideFix] Re-rebound Vulkan symbols for newly loaded image");
}

/// dlsym hook: intercepts Vulkan loader function requests and returns our wrappers
///
/// Only functions related to the zink stride fix are intercepted:
///   - vkGetInstanceProcAddr → returns amethyst_vkGetInstanceProcAddr
///     (intercepting vkCreateGraphicsPipelines calls to force 4-byte stride alignment)
///   - vkGetDeviceProcAddr → returns amethyst_vkGetDeviceProcAddr
///     (intercepting vkCmd* / vkDestroyPipeline calls to track dummy pipelines)
///
/// Every other function returns the orig_dlsym result as usual, to avoid flooding the log.
void* hooked_dlsym(void* handle, const char* name) {
    if (name != NULL && g_zinkStrideFixActive) {
        if (strcmp(name, "vkGetInstanceProcAddr") == 0) {
            if (!g_real_vkGetInstanceProcAddr) {
                g_real_vkGetInstanceProcAddr = (PFN_zkGetInstanceProcAddr)orig_dlsym(handle, name);
            }
            NSLog(@"[ZinkStrideFix] dlsym intercepted: vkGetInstanceProcAddr -> hook");
            return (void*)amethyst_vkGetInstanceProcAddr;
        }
        if (strcmp(name, "vkGetDeviceProcAddr") == 0) {
            if (!g_real_vkGetDeviceProcAddr) {
                g_real_vkGetDeviceProcAddr = (PFN_zkGetDeviceProcAddr)orig_dlsym(handle, name);
            }
            NSLog(@"[ZinkStrideFix] dlsym intercepted: vkGetDeviceProcAddr -> hook");
            return (void*)amethyst_vkGetDeviceProcAddr;
        }
    }
    return orig_dlsym(handle, name);
}

int hooked_open(const char *path, int oflag, ...) {
    va_list args;
    va_start(args, oflag);
    mode_t mode = va_arg(args, int);
    va_end(args);
    if (path && !strcmp(path, "/etc/resolv.conf")) {
        return orig_open([NSString stringWithFormat:@"%s/resolv.conf", getenv("POJAV_HOME")].UTF8String, oflag, mode);
    }

    return orig_open(path, oflag, mode);
}

void init_hookFunctions() {
    struct rebinding rebindings[] = (struct rebinding[]){
        {"abort", hooked_abort, (void *)&orig_abort},
        {"__assert_rtn", hooked___assert_rtn, NULL},
        {"exit", hooked_exit, (void *)&orig_exit},
        {"dlopen", hooked_dlopen, (void *)&orig_dlopen},
        {"dlsym", hooked_dlsym, (void *)&orig_dlsym},
        {"open", hooked_open, (void *)&orig_open},
    };
    rebind_symbols(rebindings, sizeof(rebindings)/sizeof(struct rebinding));
}
