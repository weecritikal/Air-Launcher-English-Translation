#ifndef TERRACOTTA_H
#define TERRACOTTA_H

/* libterracotta C ABI - the same source as HMCL/FCL/ZL2 v0.4.2
 *
 * Origin: burningtnt/Terracotta + an iOS porting patch (terracotta_ios_start_host_with_port)
 * Binary location: Natives/terracotta/libterracotta.xcframework/
 *
 * Thread safety: every function is protected internally by a mutex and may be called from any thread.
 * String ownership: a returned char* must be freed with terracotta_ios_free_string.
 *
 * Weak linking: every function is declared as a weak symbol with TERRACOTTA_API. When libterracotta.a is absent,
 * the linker treats these symbols as undefined weak and the function pointers are NULL at runtime.
 * TerracottaBridge.m must check terracotta_ios_available() before calling them.
 */

#include <stdint.h>

/* Weak symbol macro: keeps the linker from erroring out when the symbol is undefined (it is NULL at runtime) */
#define TERRACOTTA_API __attribute__((weak))

#ifdef __cplusplus
extern "C" {
#endif

/* Initialize Terracotta. Called once per process lifetime.
 *   dir        the working directory (where the machine-id is persisted)
 *   logging_fd the log file descriptor (-1 means do not write a file)
 * Returns 0 on success. */
TERRACOTTA_API int terracotta_ios_start(const char *dir, int logging_fd);

/* Read the current state (a JSON string). The caller is responsible for free_string.
 * JSON schema：
 *   {"state":"waiting|host-scanning|host-starting|host-ok|guest-connecting|guest-starting|guest-ok|exception",
 *    "index":int, "room":string?, "url":string?,
 *    "profile_index":int?, "profiles":[...],
 *    "difficulty":string?, "type":int?} */
TERRACOTTA_API char *terracotta_ios_get_state(void);

/* Return to the Waiting state (terminating the current session). Idempotent. */
TERRACOTTA_API void terracotta_ios_set_waiting(void);

/* Host: start scanning for the local MC "Open to LAN" multicast broadcast. */
TERRACOTTA_API void terracotta_ios_set_scanning(const char *room, const char *player);

/* Host (manual port mode): skip the multicast scan and start the host directly with the MC LAN port entered by the user.
 * Returns 1 when startup has begun; 0 when not currently in the Waiting state. */
TERRACOTTA_API int terracotta_ios_start_host_with_port(const char *room, uint16_t port, const char *player);

/* Guest: join a room.
 * Returns 1 when joining has begun; 0 when the invite code is invalid or not currently in the Waiting state. */
TERRACOTTA_API int terracotta_ios_set_guesting(const char *room, const char *player);

/* Only validates the invite code format, without joining.
 * Returns 3 for a valid Scaffolding invite code; any other value means it is invalid. */
TERRACOTTA_API int terracotta_ios_verify_room_code(const char *code);

/* Metadata: (version, compile_timestamp_ms, easytier_version).
 * Returns a NUL-separated UTF-8 string. The caller is responsible for free_string. */
TERRACOTTA_API char *terracotta_ios_get_metadata(void);

/* Free the string returned by terracotta_ios_get_state / _get_metadata. */
TERRACOTTA_API void terracotta_ios_free_string(char *ptr);

/* Debugging only: trigger a panic on the Rust side (should never be called). */
TERRACOTTA_API void terracotta_ios_panic(void);

#ifdef __cplusplus
}
#endif

/* Check at runtime whether libterracotta is available */
#define terracotta_ios_available() (terracotta_ios_start != NULL)

#endif /* TERRACOTTA_H */
