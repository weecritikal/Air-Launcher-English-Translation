cmake_minimum_required(VERSION 3.6)
project(AngelAuraAmethyst)

# Read the CurseForge API key from an environment variable
# It cannot be passed through the Makefile with -D, because Make expands environment variable values recursively,
# so $2, $1 and $Q inside a bcrypt hash ($2a$10$...) are interpreted as variable references and replaced with nothing,
# producing a corrupted key (a06bVFEP... instead of $2a$10$Q6bVFEP...)
if(DEFINED ENV{CONFIG_CURSEFORGE_API_KEY})
    set(CONFIG_CURSEFORGE_API_KEY "$ENV{CONFIG_CURSEFORGE_API_KEY}")
endif()

configure_file(${CMAKE_CURRENT_LIST_DIR}/config.h.in ${CMAKE_CURRENT_LIST_DIR}/config.h)

set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -target arm64-apple-ios -mcpu=apple-a8 -fcommon -fobjc-arc -ObjC -F'${CMAKE_OSX_SYSROOT}/System/Cryptexes/OS/System/Library/Frameworks'")
set(CMAKE_C_FLAGS_DEBUG "-funwind-tables -g")

if("${CMAKE_HOST_SYSTEM_NAME}" MATCHES "Linux|^GNU$|Android")
  set(GLOBAL_LDFLAGS "-isysroot ${CMAKE_OSX_SYSROOT} -Wl,-syslibroot,${CMAKE_OSX_SYSROOT} -fuse-ld=lld")
  set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} ${GLOBAL_LDFLAGS}")
  set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} ${GLOBAL_LDFLAGS}")
endif()

include_directories(
  "."
  "external/AFNetworking/AFNetworking"
  "external/AFNetworking/UIKit+AFNetworking"
  "external/DBNumberedSlider/Classes"
  "external/NRFileManager"
  "external/UnzipKit"
  "external/fishhook"
  "external/lzma"
  "external/mesa"
  "external/AltKit"
  "external/Apple"
  "external/ballpa1n"
  "external/ballpa1n/wrapped"
  "external/mach"
  # "external/ZeroTierFramework/ios-example-app/zt.framework/Headers"  # ZeroTier temporarily removed
)

# ============================================================================
# ZeroTier Apple Framework integration - temporarily removed (commented out while investigating a launch crash)
# ============================================================================
# set(ZT_FRAMEWORK_DIR "${CMAKE_CURRENT_LIST_DIR}/external/ZeroTierFramework/ios-example-app")
# set(ZT_FRAMEWORK_LIB "${ZT_FRAMEWORK_DIR}/zt.framework/zt")
# if(EXISTS "${ZT_FRAMEWORK_LIB}")
#   message(STATUS "Found ZeroTier framework binary: ${ZT_FRAMEWORK_LIB}")
#   set(ZT_FRAMEWORK_SEARCH_PATH "-F'${ZT_FRAMEWORK_DIR}'")
#   set(ZT_FRAMEWORK_LINK "-framework zt")
#   set(ZT_CXX_LIB "-lc++")
# else()
#   message(FATAL_ERROR "ZeroTier framework not found at ${ZT_FRAMEWORK_LIB}. Please run: git submodule update --init --recursive")
# endif()
set(ZT_FRAMEWORK_SEARCH_PATH "")
set(ZT_FRAMEWORK_LINK "")
set(ZT_CXX_LIB "")

# ============================================================================
# libterracotta.xcframework integration (Terracotta multiplayer) - temporarily removed (commented out while investigating a launch crash)
# ============================================================================
# set(TERRACOTTA_LIB_DIR "${CMAKE_CURRENT_LIST_DIR}/terracotta")
# set(TERRACOTTA_XCFW "${TERRACOTTA_LIB_DIR}/libterracotta.xcframework")
# set(TERRACOTTA_LIB "")
# set(TERRACOTTA_AVAILABLE OFF)
# if(EXISTS "${TERRACOTTA_XCFW}/ios-arm64/libterracotta.a")
#   set(_TC_LIB_PATH "${TERRACOTTA_XCFW}/ios-arm64/libterracotta.a")
#   set(TERRACOTTA_LIB "-Wl,-force_load,${_TC_LIB_PATH}")
#   set(TERRACOTTA_AVAILABLE ON)
# elseif(EXISTS "${TERRACOTTA_LIB_DIR}/libterracotta.a")
#   set(_TC_LIB_PATH "${TERRACOTTA_LIB_DIR}/libterracotta.a")
#   set(TERRACOTTA_LIB "-Wl,-force_load,${_TC_LIB_PATH}")
#   set(TERRACOTTA_AVAILABLE ON)
# endif()
set(TERRACOTTA_LIB "")
set(TERRACOTTA_AVAILABLE OFF)

# For cacio support library
set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -rpath @loader_path -rpath @executable_path/java_runtimes/java-8-openjdk/lib -rpath /usr/lib/jvm/java-8-openjdk/lib")

# EXT: stub library, delete after compile awt_xawt
add_library(awt_headless SHARED
  awt_xawt/empty.m
)
target_link_libraries(awt_headless)

# EXT: cacio support library
add_library(awt_xawt SHARED
  awt_xawt/xawt_fake.m
)
target_link_libraries(awt_xawt
  "-L'${CMAKE_CURRENT_LIST_DIR}/build'"
  awt_headless
)

# TouchController iOS native library
# Provides JNI / C API for touch control communication between Minecraft mod and launcher
#
# Three-level fallback detection logic (highest priority first):
#   Level 1 - prebuilt XCFramework: detects TouchController.xcframework/ and links the device static library
#             from the ios-arm64 subdirectory (produced by build_xcframework.sh)
#   Level 2 - prebuilt standalone .a: detects libproxy_server_ios.a (device) or
#             libproxy_server_ios_simulator.a (simulator), for backward compatibility
#   Level 3 - source build fallback: detects the ios_transport.c source file and lets CMake compile it into an object library
#   Disabled - when none of the above exist, TOUCHCONTROLLER_LIB is left empty and a warning is printed
#
# Important: TouchControllerBridge.m looks the symbols up at runtime with dlsym(RTLD_DEFAULT, "touchcontroller_ios_*")
# and has no direct references at compile time. Apple ld loads static libraries (.a) on demand and only
# extracts the object files that are referenced directly - unreferenced object files are dropped, so dlsym cannot find the symbols.
# Therefore:
#   - Level 1/2 (prebuilt .a): -Wl,-force_load,<path> must be used to load the whole static library
#   - Level 3 (built from source): an OBJECT library is used instead, so the object files link straight into the executable
#     and every symbol is preserved automatically, with no need for -force_load
set(TOUCHCONTROLLER_LIB_DIR "${CMAKE_CURRENT_LIST_DIR}/TouchController")
set(TOUCHCONTROLLER_XCFW "${TOUCHCONTROLLER_LIB_DIR}/TouchController.xcframework")
set(TOUCHCONTROLLER_LIB "")

# Level 1: prebuilt XCFramework (highest priority)
if(EXISTS "${TOUCHCONTROLLER_XCFW}/ios-arm64/libproxy_server_ios.a")
  set(_TC_LIB_PATH "${TOUCHCONTROLLER_XCFW}/ios-arm64/libproxy_server_ios.a")
  message(STATUS "Found TouchController XCFramework (Level 1: prebuilt xcframework) at ${_TC_LIB_PATH}")
  # Force the whole static library to load, so dlsym can find every touchcontroller_ios_* symbol
  set(TOUCHCONTROLLER_LIB "-Wl,-force_load,${_TC_LIB_PATH}")
# Level 2: prebuilt standalone .a (kept for compatibility)
elseif(EXISTS "${TOUCHCONTROLLER_LIB_DIR}/libproxy_server_ios.a")
  set(_TC_LIB_PATH "${TOUCHCONTROLLER_LIB_DIR}/libproxy_server_ios.a")
  message(STATUS "Found TouchController device library (Level 2: prebuilt .a) at ${_TC_LIB_PATH}")
  set(TOUCHCONTROLLER_LIB "-Wl,-force_load,${_TC_LIB_PATH}")
elseif(EXISTS "${TOUCHCONTROLLER_LIB_DIR}/libproxy_server_ios_simulator.a")
  set(_TC_LIB_PATH "${TOUCHCONTROLLER_LIB_DIR}/libproxy_server_ios_simulator.a")
  message(STATUS "Found TouchController simulator library (Level 2: prebuilt .a) at ${_TC_LIB_PATH}")
  set(TOUCHCONTROLLER_LIB "-Wl,-force_load,${_TC_LIB_PATH}")
# Level 3: source build fallback (an OBJECT library is used so every symbol is preserved)
elseif(EXISTS "${TOUCHCONTROLLER_LIB_DIR}/ios_transport.c")
  message(STATUS "Building TouchController from source (Level 3: source compilation)")
  # An OBJECT library is used rather than a STATIC one: the object files link straight into the executable
  # and every symbol is preserved automatically, avoiding the problem of dlsym not finding the symbols
  add_library(proxy_server_ios OBJECT
    ${TOUCHCONTROLLER_LIB_DIR}/ios_transport.c
    ${TOUCHCONTROLLER_LIB_DIR}/ring_buffer.c
  )
  target_include_directories(proxy_server_ios PRIVATE ${TOUCHCONTROLLER_LIB_DIR})
  set(TOUCHCONTROLLER_LIB proxy_server_ios)
# Nothing matched: TouchController support is disabled
else()
  message(STATUS "TouchController library not found, TouchController support will be disabled")
  set(TOUCHCONTROLLER_LIB "")
endif()

set(CMAKE_FRAMEWORK_PATH "${CMAKE_CURRENT_LIST_DIR}/resources/Frameworks")

set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -rpath @executable_path/Frameworks -rpath @loader_path/Frameworks")
set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -rpath @executable_path/Frameworks -rpath @loader_path/Frameworks")

# ANGLE wrapper for 1.17+
add_library(tinygl4angle SHARED
  external/gl4es/string_utils.c
  external/gl4es/tinygl4angle.c
)
target_link_libraries(tinygl4angle
  "${GLOBAL_LDFLAGS}"
  "-F'${CMAKE_CURRENT_LIST_DIR}/resources/Frameworks'"
  "-framework libEGL"
  "-framework libGLESv2"
)

# LTW (Large Thin Wrapper) - an OpenGL Core 3.3 → OpenGL ES 3 translation layer
# Ported from the official MojoLauncher/LTW repository (the master branch), with these iOS porting changes:
#   - proc.c: loads eglGetProcAddress from libtinygl4angle.dylib (instead of libEGL.so)
#   - egl.c/egl.h: thread_local → pthread_key_t (more reliable TLS)
#   - shader_wrapper.c: fixes a bug where offset was not incremented (which corrupted the shader source when count > 1)
#   - ltw_compat/threads.h: provides C11 <threads.h> compatibility (the iOS SDK does not ship it)
# What it does:
#   - Pretends to be an OpenGL 3.3 Core Profile so MC 1.17+ runs correctly
#   - Proactively advertises ARB extensions such as GL_ARB_buffer_storage / GL_ARB_texture_buffer_object
#     so Sodium's persistent mapped buffers / texture buffers work
#   - Proactively advertises GL_ARB_draw_buffers_blend (required by Iris)
#   - Proactively advertises GL_ARB_timer_query (Blaze3D TimerQuery)
#   - Ignores fragment shader compilation errors (the HACK in shader_wrapper.c),
#     so shader packs such as BSL/Mellow Shader can run on ES
set(LTW_DIR "${CMAKE_CURRENT_LIST_DIR}/external/LTW/ltw/src/main/tinywrapper")
set(LTW_INCLUDES
  "${LTW_DIR}"
  "${LTW_DIR}/GL"
  "${CMAKE_CURRENT_LIST_DIR}/cmake/ltw_compat"
  "${LTW_DIR}/glsl_optimizer/include"
  "${LTW_DIR}/glsl_optimizer/src"
  "${LTW_DIR}/vgpu_shaderconv"
  "${LTW_DIR}/unordered_map"
  "${CMAKE_CURRENT_LIST_DIR}/external/MobileGlues/src/main/cpp/include"
)

include(cmake/ltw_sources.cmake)

add_library(glsl_optimizer STATIC ${GLSL_OPTIMIZER_SRC})
target_include_directories(glsl_optimizer PRIVATE ${LTW_INCLUDES})
set_target_properties(glsl_optimizer PROPERTIES
  POSITION_INDEPENDENT_CODE ON
  CXX_STANDARD 17
  C_STANDARD 11
)
target_compile_definitions(glsl_optimizer PRIVATE
  _LIB NOMINMAX _USE_MATH_DEFINES __STDC_NO_THREADS__
  __STDC_LIMIT_MACROS __STDC_FORMAT_MACROS __STDC_CONSTANT_MACROS
  UTL_ARCH_LITTLE_ENDIAN UNIX
  HAVE_OPENGL HAVE_OPENGL_ES_1 HAVE_OPENGL_ES_2
  HAVE_TIMESPEC_GET HAVE_STRUCT_TIMESPEC
  VK_DESCRIPTOR_TYPE_INLINE_UNIFORM_BLOCK=VK_DESCRIPTOR_TYPE_INLINE_UNIFORM_BLOCK_EXT
)

add_library(ltw SHARED ${LTW_CORE_SRC})
target_include_directories(ltw PRIVATE ${LTW_INCLUDES})
target_link_libraries(ltw
  "${GLOBAL_LDFLAGS}"
  glsl_optimizer
  "-F'${CMAKE_CURRENT_LIST_DIR}/resources/Frameworks'"
  "-framework libEGL"
  "-framework libGLESv2"
)
set_target_properties(ltw PROPERTIES
  C_STANDARD 11
  C_STANDARD_REQUIRED ON
)
target_compile_definitions(ltw PRIVATE
  _LIB NOMINMAX _USE_MATH_DEFINES __STDC_NO_THREADS__
  __STDC_LIMIT_MACROS __STDC_FORMAT_MACROS __STDC_CONSTANT_MACROS
  UTL_ARCH_LITTLE_ENDIAN UNIX
  HAVE_OPENGL HAVE_OPENGL_ES_1 HAVE_OPENGL_ES_2
  HAVE_TIMESPEC_GET HAVE_STRUCT_TIMESPEC
)

# AFNetworking
add_library(AFNetworking SHARED
  external/AFNetworking/AFNetworking/AFSecurityPolicy.m
  external/AFNetworking/AFNetworking/AFHTTPSessionManager.m
  external/AFNetworking/AFNetworking/AFURLRequestSerialization.m
  external/AFNetworking/AFNetworking/AFURLSessionManager.m
  external/AFNetworking/AFNetworking/AFNetworkReachabilityManager.m
  external/AFNetworking/AFNetworking/AFURLResponseSerialization.m
  external/AFNetworking/UIKit+AFNetworking/AFNetworkActivityIndicatorManager.m
  external/AFNetworking/UIKit+AFNetworking/AFAutoPurgingImageCache.m
  external/AFNetworking/UIKit+AFNetworking/AFImageDownloader.m
  external/AFNetworking/UIKit+AFNetworking/UIButton+AFNetworking.m
  external/AFNetworking/UIKit+AFNetworking/UIImageView+AFNetworking.m
)
target_link_libraries(AFNetworking
  "-framework CoreGraphics"
  "-framework CoreServices"
  "-framework Security"
  "-framework SystemConfiguration"
  "-framework UIKit"
)

# MinecraftAccount JNI
add_library(AmethystAccountJNI SHARED
  authenticator/MinecraftAccountJNI.m
)
target_link_libraries(AmethystAccountJNI)

# Audio capture JNI bridge (SimpleVoiceChat Mod support)
add_library(audio_capture SHARED
  audio_capture_bridge.m
)
target_link_libraries(audio_capture
  "-framework AVFoundation"
)

# Angel Aura Amethyst
add_executable(AngelAuraAmethyst
  dyld_bypass_validation.m
  dyld_patch_platform.m
  main.m
  main_hook.m
  JavaLauncher.m
  external/fishhook/fishhook.c
  UIKit+hook.m
  ScreenUtils.m

  authenticator/BaseAuthenticator.m
  authenticator/LocalAuthenticator.m
  authenticator/MicrosoftAuthenticator.m
  authenticator/ThirdPartyAuthenticator.m

  ctxbridges/gl_bridge.m
  ctxbridges/osm_bridge.m
  ctxbridges/vk_bridge.m

  customcontrols/ControlButton.m
  customcontrols/ControlDrawer.m
  customcontrols/ControlJoystick.m
  customcontrols/ControlLayout.m
  customcontrols/ControlSubButton.m
  customcontrols/CustomControlsUtils.m
  customcontrols/NSPredicateUtilitiesExternal.m

  external/DBNumberedSlider/Classes/DBNumberedSlider.m
  external/NRFileManager/NSFileManager+NRFileManager.m
  external/ballpa1n/HostManager.c
  external/ballpa1n/wrapped/HostManagerBridge.m
  external/mach/mach_excServer.c

  installer/FabricInstallViewController.m
  installer/ForgeInstallViewController.m
  installer/ForgeInstallSchemeViewController.m
  installer/ForgeDirectInstaller.m
  installer/NeoForgeDirectInstaller.m
  installer/ModpackInstallViewController.m
  installer/ModLoaderInstallViewController.m
  installer/FabricUtils.m
  installer/NeoForgeVersionFetcher.m
  installer/modpack/ModpackUtils.m
  installer/modpack/ModpackConfiguration.m
  installer/modpack/ModpackAPI.m
  installer/modpack/ModrinthAPI.m
	installer/modpack/CurseForgeAPI.m

  input/ControllerInput.m
  input/GyroInput.m
  input/KeyboardInput.m

  AccountListViewController.m
  AccountLoginViewController.m
  ThirdPartyLoginViewController.m
  GameMenuOverlayView.m
  InlineMessageView.m
  DownloadTaskItem.m
  DownloadTaskManager.m
  DownloadTasksViewController.m
  AppDelegate.m
  CustomControlsViewController.m
  CustomControlsViewController+UndoManager.m
  DownloadProgressViewController.m
  DownloadProgressCardView.m
  FileListViewController.m
  GameSurfaceView.m
  JavaGUIViewController.m
  # ZeroTier multiplayer temporarily removed (while investigating a launch crash)
  # MultiplayerManager.m
  # MultiplayerViewController.m
  # LanPortDetector.m
  # ZeroTierBridge.m
  # SOCKS5Proxy.m
  # PortForwarder.m
  LauncherMenuViewController.m
  LauncherNavigationController.m
  LauncherNewsViewController.m
  HomeCustomizeViewController.m
  LauncherRootViewController.m
  LauncherCardLayoutViewController.m
  LauncherRightPanelViewController.m
  VersionManagerViewController.m
  ProfileSettingsViewController.m
  DownloadViewController.m
  LauncherPreferences.m
  LauncherPreferencesViewController.m
  LauncherPrefContCfgViewController.m
  LauncherPrefGameDirViewController.m
  LauncherPrefManageJREViewController.m
  LauncherProfileEditorViewController.m
  LauncherProfilesViewController.m
  LauncherSplitViewController.m
  MinecraftResourceDownloadTask.m
  MinecraftResourceUtils.m
  PickTextField.m
  PLLogOutputView.m
  PLCrashView.m
  PLPickerView.m
  PLPreferences.m
  PLPrefTableViewController.m
  PLProfiles.m
  SceneDelegate.m
  SceneExternalDelegate.m
  SurfaceViewController.m
  SurfaceViewController+ExternalDisplay.m
  SurfaceViewController+LogView.m
  SurfaceViewController+Navigation.m
  TrackedTextField.m
  egl_bridge.m
  ZinkConfig.m
  input_bridge_v3.m
  ios_uikit_bridge.m
  utils.m

  # Version card cell (shared between DownloadViewController and LauncherProfilesViewController)
  VersionCardCell.m

  # Mod-related sources (ensure implementations are compiled and linked)
  MarqueeLabel.m
  ModItem.m
  ModService.m
  ModTableViewCell.m
  ModTableViewController.m
  ModsManagerViewController.m
  ModVersion.m
  ModVersionViewController.m
  ModVersionTableViewCell.m

  # Shared resource detail page header view (used by the Mod/Shader/Asset version pages to show the project cover image/information/tags/description)
  AssetDetailHeaderView.m

  # Unified mod loader icon helper class (bundle PNG first, falling back to an SF Symbol, unifying loader brand colors and icons project-wide)
  ModLoaderIconHelper.m

  # Unified project icon loader (two-level cache + downsampling + concurrency control + CDN mirror, modeled on FCL Glide + ZL2 Coil)
  IconLoader.m

  # MCIM mod mirror source helper class (modeled on ZalithLauncher 2 MCIMMirror.kt)
  MCIMMirror.m

  # Shader-related sources
  ShaderItem.m
  ShaderService.m
  ShaderTableViewCell.m
  ShaderVersion.m
  ShaderVersionTableViewCell.m
  ShaderVersionViewController.m
  ShadersManagerViewController.m

  # Modpack import/export sources
  ModpackImportViewController.m
  ModpackImportService.m
  ModpackExportService.m
  ModpackExportViewController.m

  # CurseForge MurmurHash2 fingerprint tool
  MurmurHash2.m

  # Resource Pack / Data Pack / World management (services, items, version VC, manager VCs)
  ResourcePackItem.m
  DataPackItem.m
  WorldItem.m
  ResourcePackService.m
  DataPackService.m
  WorldService.m
  AssetVersionViewController.m
  ResourcePacksManagerViewController.m
  DataPacksManagerViewController.m
  WorldsManagerViewController.m

  # Server projects (Modrinth Server Projects + CurseForge server packs)
  ServerItem.m
  ServerService.m
  ServerListViewController.m
  ServerDetailViewController.m

  # CurseForge API Key settings page
  installer/CurseForgeAPIKeyViewController.m

  # Mod update service (dual-source SHA1/MurmurHash2 reverse lookup)
  ModUpdateService.m
  ModUpdateViewController.m

  # Custom icon management sources
  CustomIconManager.m
  ImageCropperViewController.m

  # Account custom avatar management sources
  AvatarManager.m

  # Background wallpaper sources
  BackgroundManager.m
  BackgroundSettingsViewController.m

  # FCL-style interface is implemented in LauncherMenuViewController.m

  # TouchController bridge and preferences
  TouchControllerBridge.m
  TouchControllerPreferencesViewController.m

  # Terracotta multiplayer - temporarily removed (while investigating a launch crash)
  # TerracottaBridge.m
  # TerracottaManager.m
  # SilentAudioPlayer.m
  # TerracottaViewController.m

  # Update checker (modeled on FCL/ZL2, using the GitHub Releases API to check for stable updates)
  UpdateChecker.m

  # Minecraft news (modeled on PCL-CE, calling the official minecraft-services.net news API)
  MinecraftNewsItem.m
  MinecraftNewsService.m
  MinecraftNewsViewController.m

  # Announcement system (fetches JSON from the official site, with Markdown rendering)
  AnnouncementItem.m
  AnnouncementService.m
  MarkdownParser.m
  AnnouncementListViewController.m
  AnnouncementDetailViewController.m
)

# Add ModLoaderIcons PNG files into the app bundle Resources/ModLoaderIcons so they are available at runtime.
# This will copy all *.png under Natives/ModLoaderIcons into the bundle at Resources/ModLoaderIcons/<name>.png
set(MODLOADER_ICONS_DIR "${CMAKE_CURRENT_LIST_DIR}/ModLoaderIcons")
if(EXISTS "${MODLOADER_ICONS_DIR}")
  file(GLOB MODLOADER_ICON_FILES "${MODLOADER_ICONS_DIR}/*.png")
  if(MODLOADER_ICON_FILES)
    foreach(_icon ${MODLOADER_ICON_FILES})
      get_filename_component(_name ${_icon} NAME)
      message(STATUS "Including mod loader icon in bundle: ${_name}")
      # Place into Resources/ModLoaderIcons inside the .app bundle so your code can find resourcePath/ModLoaderIcons/...
      set_source_files_properties(${_icon} PROPERTIES MACOSX_PACKAGE_LOCATION "Resources/ModLoaderIcons")
    endforeach()
    # Attach the resource files to the main executable target so CMake copies them into the bundle
    target_sources(AngelAuraAmethyst PRIVATE ${MODLOADER_ICON_FILES})
  endif()
else()
  message(STATUS "ModLoaderIcons directory not found: ${MODLOADER_ICONS_DIR}")
endif()

if("${CMAKE_HOST_SYSTEM_NAME}" MATCHES "Linux|^GNU$|Android")
  target_sources(AngelAuraAmethyst PUBLIC non_darwin_utils.m)
endif()

target_link_libraries(AngelAuraAmethyst
  PUBLIC AFNetworking
  lzma
  "-F'${CMAKE_CURRENT_LIST_DIR}/build'"
  "-F'${CMAKE_CURRENT_LIST_DIR}/resources/Frameworks'"
  # ZeroTier temporarily removed: "${ZT_FRAMEWORK_SEARCH_PATH}" "${ZT_FRAMEWORK_LINK}" "${ZT_CXX_LIB}"
  "-framework AltKit"
  "-framework AuthenticationServices"
  "-framework AVFoundation"
  "-framework CAltKit"
  "-framework CoreFoundation"
  "-framework CoreGraphics"
  "-framework CoreImage"
  "-framework CoreMedia"
  "-framework ImageIO"
  "-framework CoreMotion"
  "-framework GameController"
  "-framework IOKit"
  "-framework QuartzCore"
  "-framework UIKit"
  "-framework UniformTypeIdentifiers"
  "-framework UnzipKit"
  "-framework WebKit"
  "-weak_framework SafariServices"
  ${TOUCHCONTROLLER_LIB}
  # Terracotta multiplayer temporarily removed: ${TERRACOTTA_LIB} "-lc++" "-lresolv"
)
set_target_properties(AngelAuraAmethyst PROPERTIES
  MACOSX_BUNDLE TRUE
  MACOSX_FRAMEWORK_IDENTIFIER org.cmake.ExecutableTarget
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_LIST_DIR}/Info.plist")
