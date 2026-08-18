#ifndef TERRACOTTA_H
#define TERRACOTTA_H

/* libterracotta C ABI - the same source as HMCL/FCL/ZL2 v0.4.2
 *
 * Origin: burningtnt/Terracotta + an iOS porting patch (terracotta_ios_start_host_with_port)
 * How it is built: see Natives/terracotta/libterracotta.xcframework/
 *
 * Thread safety: every function is protected internally by a mutex and may be called from any thread.
 * String ownership: a returned char* must be freed with terracotta_ios_free_string.
 *
 * Weak linking: every function is declared as a weak symbol with TERRACOTTA_API. When libterracotta.a is absent,
 * the linker treats these symbols as undefined weak and the function pointers are NULL at runtime.
 * TerracottaBridge.m must check that the symbols are available before calling them (with terracotta_ios_available()).
 */

#include <stdint.h>

/* Weak symbol macro: keeps the linker from erroring out when the symbol is undefined (it is NULL at runtime).
 * - __attribute__((weak)) weakens the function symbol itself
 * - __attribute__((weak_import)) only applies to dynamic library imports, not to static libraries
 * weak is used here so linking still succeeds when the static library is absent. */
#define TERRACOTTA_API __attribute__((weak))

#ifdef __cplusplus
extern "C" {
#endif

/* Initialize Terracotta. Called once per process lifetime.
 *   dir        the Terracotta working directory (the machine-id is written here, to keep the player identity across launches)
 *   logging_fd the log file descriptor (-1 means do not write a file, only stderr)
 * Returns 0 on success. */
TERRACOTTA_API int terracotta_ios_start(const char *dir, int logging_fd);

/* Read the current state (a JSON string). The caller is responsible for free_string.
 * JSON schema：
 *   {"state":"waiting|host-scanning|host-starting|host-ok|guest-connecting|guest-starting|guest-ok|exception",
 *    "index":int, "room":string?, "url":string?,
 *    "profile_index":int?, "profiles":[{name,machine_id,easytier_id,vendor,kind}]?,
 *    "difficulty":string?, "type":int?} */
TERRACOTTA_API char *terracotta_ios_get_state(void);

/* Return to the Waiting state (terminating the current session). Idempotent. */
TERRACOTTA_API void terracotta_ios_set_waiting(void);

/* Host: start scanning for the local MC "Open to LAN" multicast broadcast.
 *   room        optional, reuses an existing invite code; NULL lets the Rust side generate one
 *   player      optional, the player nickname; NULL uses the default */
TERRACOTTA_API void terracotta_ios_set_scanning(const char *room, const char *player);

/* Host (manual port mode): skip the multicast scan and start the host directly with the MC LAN port entered by the user.
 * Multicast reception on iOS is affected by the local network permission and by code signing, so the LAN broadcast MC sends inside PojavLauncher may not be received.
 * After the user opens the world to LAN, MC shows the port number, which can simply be entered.
 *   room        optional, reuses an existing invite code; NULL lets the Rust side generate one
 *   port        the MC LAN port (such as 25565, or the random port MC displays)
 *   player      optional, the player nickname; NULL uses the default
 * Returns 1 when startup has begun; 0 when not currently in the Waiting state. */
TERRACOTTA_API int terracotta_ios_start_host_with_port(const char *room, uint16_t port, const char *player);

/* Guest: join a room.
 *   room    required, the Scaffolding invite code shared by the host
 *   player  optional, the player nickname; NULL uses the default
 * Returns 1 when joining has begun; 0 when the invite code is invalid or not currently in the Waiting state. */
TERRACOTTA_API int terracotta_ios_set_guesting(const char *room, const char *player);

/* Only validates the invite code format, without joining.
 * Returns 3 for a valid Scaffolding invite code; any other value means it is invalid. */
TERRACOTTA_API int terracotta_ios_verify_room_code(const char *code);

/* Metadata: (version, compile_timestamp_ms, easytier_version).
 * Returns a NUL-separated UTF-8 string: "<version>\0<ts_ms>\0<et_version>\0".
 * The caller is responsible for free_string. */
TERRACOTTA_API char *terracotta_ios_get_metadata(void);

/* Free the string returned by terracotta_ios_get_state / _get_metadata. */
TERRACOTTA_API void terracotta_ios_free_string(char *ptr);

/* Debugging only: trigger a panic on the Rust side (should never be called). */
TERRACOTTA_API void terracotta_ios_panic(void);

#ifdef __cplusplus
}
#endif

/* Check at runtime whether libterracotta is available (whether the terracotta_ios_start symbol resolved).
 * When the library is not linked every terracotta_ios_* function pointer is NULL, so TerracottaBridge must check before calling. */
#define terracotta_ios_available() (terracotta_ios_start != NULL)

#endif /* TERRACOTTA_H */
