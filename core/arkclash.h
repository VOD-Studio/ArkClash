// C API exported by libclash.so (core/lib.go). Keep the two in sync.
#ifndef ARKCLASH_CORE_H
#define ARKCLASH_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

// Starts the core with a JSON options object. Returns NULL on success or an
// error message to release with ArkClashFree.
char *ArkClashStart(char *optionsJSON);
void ArkClashStop(void);
// Returns the mihomo version; release with ArkClashFree.
char *ArkClashVersion(void);
void ArkClashFree(char *p);

#ifdef __cplusplus
}
#endif

#endif // ARKCLASH_CORE_H
