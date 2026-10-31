// Thin C wrapper over libgphoto2 so Swift never touches its widget trees or varargs.
// Not thread-safe: call everything for one camera from a single serial queue.
#pragma once
#include <stddef.h>

typedef struct GPBCamera GPBCamera;

/// Opens the first camera gphoto2 auto-detects. On failure returns NULL and writes a
/// message into `err`.
GPBCamera *gpb_open(char *model, size_t modelLen, char *err, size_t errLen);
/// Opens a camera at an explicit port path (e.g. "ptpip:127.0.0.1:5000:5000") with the
/// given driver model name (e.g. "PTP/IP Camera"). Same error convention as gpb_open.
GPBCamera *gpb_open_path(const char *path, const char *driverModel, char *model, size_t modelLen,
                         char *err, size_t errLen);
void gpb_close(GPBCamera *cam);

/// One live view JPEG. The bytes stay valid until the next gpb_preview call.
/// Returns a gphoto2 result code (0 = ok).
int gpb_preview(GPBCamera *cam, const unsigned char **data, unsigned long *size);

/// Reads a RADIO/MENU/TEXT/TOGGLE setting. `current` gets the value; `choices` gets
/// every allowed value separated by '\n'. Returns a gphoto2 result code.
int gpb_get(GPBCamera *cam, const char *key, char *current, size_t currentLen,
            char *choices, size_t choicesLen, int *readonly);

/// Sets a setting from its string form (a choice for RADIO/MENU, "0"/"1" for TOGGLE).
int gpb_set(GPBCamera *cam, const char *key, const char *value);

/// Sends a Sony SDIO control code (e.g. 0xD2E4 RemoteTouch) with a UINT32 value, the
/// way Sony's own remote apps do. libgphoto2 has the sender but doesn't export it, so
/// this resolves it from the loaded ptp2 camlib's symbol table. Returns a PTP response
/// code (0x2001 = OK), or -1 if the function couldn't be found.
int gpb_sony_control(GPBCamera *cam, unsigned short code, unsigned int value);

const char *gpb_result_string(int result);
