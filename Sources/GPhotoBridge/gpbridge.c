#include "gpbridge.h"

#include <gphoto2/gphoto2.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct GPBCamera {
    Camera *camera;
    GPContext *context;
    CameraFile *previewFile;
};

// Driver and port tables are loaded once; the app retries gpb_open every couple of
// seconds while waiting for the camera.
static CameraAbilitiesList *abilitiesList;
static GPPortInfoList *portList;

GPBCamera *gpb_open(char *model, size_t modelLen, char *err, size_t errLen) {
    GPContext *context = gp_context_new();
    if (!abilitiesList) {
        gp_abilities_list_new(&abilitiesList);
        gp_abilities_list_load(abilitiesList, context);
        gp_port_info_list_new(&portList);
        gp_port_info_list_load(portList);
    }

    // Detect first, and only open a camera that's actually there. Letting
    // gp_camera_init auto-detect a camera that's mid USB re-enumeration fails with
    // "Unknown model" and leaves the device unclaimable for the rest of the process.
    CameraList *found = NULL;
    gp_list_new(&found);
    int r = gp_abilities_list_detect(abilitiesList, portList, found, context);
    const char *name = NULL, *path = NULL;
    if (r < GP_OK || gp_list_count(found) < 1 ||
        gp_list_get_name(found, 0, &name) < GP_OK || gp_list_get_value(found, 0, &path) < GP_OK) {
        snprintf(err, errLen, "%s", r < GP_OK ? gp_result_as_string(r) : "no camera detected");
        gp_list_free(found);
        gp_context_unref(context);
        return NULL;
    }

    GPBCamera *cam = calloc(1, sizeof(GPBCamera));
    cam->context = context;
    r = gp_camera_new(&cam->camera);
    CameraAbilities abilities;
    int mi = gp_abilities_list_lookup_model(abilitiesList, name);
    int pi = gp_port_info_list_lookup_path(portList, path);
    GPPortInfo portInfo;
    if (r >= GP_OK) r = mi < 0 ? mi : gp_abilities_list_get_abilities(abilitiesList, mi, &abilities);
    if (r >= GP_OK) r = gp_camera_set_abilities(cam->camera, abilities);
    if (r >= GP_OK) r = pi < 0 ? pi : gp_port_info_list_get_info(portList, pi, &portInfo);
    if (r >= GP_OK) r = gp_camera_set_port_info(cam->camera, portInfo);
    if (r >= GP_OK) r = gp_camera_init(cam->camera, cam->context);
    if (r < GP_OK) {
        snprintf(err, errLen, "%s", gp_result_as_string(r));
        if (cam->camera) {
            gp_camera_exit(cam->camera, cam->context);
            gp_camera_free(cam->camera);
        }
        gp_list_free(found);
        gp_context_unref(cam->context);
        free(cam);
        return NULL;
    }
    snprintf(model, modelLen, "%s", name);
    gp_list_free(found);
    gp_file_new(&cam->previewFile);
    return cam;
}

GPBCamera *gpb_open_path(const char *path, const char *driverModel, char *model, size_t modelLen,
                         char *err, size_t errLen) {
    GPContext *context = gp_context_new();
    if (!abilitiesList) {
        gp_abilities_list_new(&abilitiesList);
        gp_abilities_list_load(abilitiesList, context);
        gp_port_info_list_new(&portList);
        gp_port_info_list_load(portList);
    }
    GPBCamera *cam = calloc(1, sizeof(GPBCamera));
    cam->context = context;
    CameraAbilities abilities;
    GPPortInfo portInfo;
    int r = gp_camera_new(&cam->camera);
    int mi = gp_abilities_list_lookup_model(abilitiesList, driverModel);
    int pi = gp_port_info_list_lookup_path(portList, path);
    if (r >= GP_OK) r = mi < 0 ? mi : gp_abilities_list_get_abilities(abilitiesList, mi, &abilities);
    if (r >= GP_OK) r = gp_camera_set_abilities(cam->camera, abilities);
    if (r >= GP_OK) r = pi < 0 ? pi : gp_port_info_list_get_info(portList, pi, &portInfo);
    if (r >= GP_OK) r = gp_camera_set_port_info(cam->camera, portInfo);
    if (r >= GP_OK) r = gp_camera_init(cam->camera, cam->context);
    if (r < GP_OK) {
        snprintf(err, errLen, "%s", gp_result_as_string(r));
        if (cam->camera) {
            gp_camera_exit(cam->camera, cam->context);
            gp_camera_free(cam->camera);
        }
        gp_context_unref(cam->context);
        free(cam);
        return NULL;
    }
    // The generic PTP/IP driver doesn't know the body's name; ask the camera.
    CameraText summary;
    model[0] = '\0';
    if (gp_camera_get_summary(cam->camera, &summary, cam->context) >= GP_OK) {
        const char *m = strstr(summary.text, "Model: ");
        if (m) sscanf(m + 7, "%127[^\n]", model);
    }
    if (!model[0]) snprintf(model, modelLen, "%s", driverModel);
    gp_file_new(&cam->previewFile);
    return cam;
}

void gpb_close(GPBCamera *cam) {
    if (!cam) return;
    gp_file_free(cam->previewFile);
    gp_camera_exit(cam->camera, cam->context);
    gp_camera_free(cam->camera);
    gp_context_unref(cam->context);
    free(cam);
}

int gpb_preview(GPBCamera *cam, const unsigned char **data, unsigned long *size) {
    gp_file_clean(cam->previewFile);
    int r = gp_camera_capture_preview(cam->camera, cam->previewFile, cam->context);
    if (r < GP_OK) return r;
    const char *bytes = NULL;
    r = gp_file_get_data_and_size(cam->previewFile, &bytes, size);
    *data = (const unsigned char *)bytes;
    return r;
}

int gpb_get(GPBCamera *cam, const char *key, char *current, size_t currentLen,
            char *choices, size_t choicesLen, int *readonly) {
    CameraWidget *w = NULL;
    int r = gp_camera_get_single_config(cam->camera, key, &w, cam->context);
    if (r < GP_OK) return r;
    CameraWidgetType type;
    gp_widget_get_type(w, &type);
    gp_widget_get_readonly(w, readonly);
    current[0] = '\0';
    choices[0] = '\0';

    if (type == GP_WIDGET_TOGGLE) {
        int v = 0;
        gp_widget_get_value(w, &v);
        snprintf(current, currentLen, "%d", v);
    } else if (type == GP_WIDGET_RADIO || type == GP_WIDGET_MENU || type == GP_WIDGET_TEXT) {
        const char *v = NULL;
        gp_widget_get_value(w, &v);
        if (v) snprintf(current, currentLen, "%s", v);
    }
    if (type == GP_WIDGET_RADIO || type == GP_WIDGET_MENU) {
        size_t used = 0;
        int n = gp_widget_count_choices(w);
        for (int i = 0; i < n; i++) {
            const char *c = NULL;
            if (gp_widget_get_choice(w, i, &c) < GP_OK || !c) continue;
            int wrote = snprintf(choices + used, choicesLen - used, "%s%s", used ? "\n" : "", c);
            if (wrote < 0 || (size_t)wrote >= choicesLen - used) break;
            used += (size_t)wrote;
        }
    }
    gp_widget_free(w);
    return GP_OK;
}

int gpb_set(GPBCamera *cam, const char *key, const char *value) {
    CameraWidget *w = NULL;
    int r = gp_camera_get_single_config(cam->camera, key, &w, cam->context);
    if (r < GP_OK) return r;
    CameraWidgetType type;
    gp_widget_get_type(w, &type);
    if (type == GP_WIDGET_TOGGLE) {
        int v = atoi(value);
        r = gp_widget_set_value(w, &v);
    } else {
        r = gp_widget_set_value(w, value);
    }
    if (r >= GP_OK) r = gp_camera_set_single_config(cam->camera, key, w, cam->context);
    gp_widget_free(w);
    return r;
}

// Finds a (possibly local, non-exported) symbol in a loaded image whose path contains
// `imageHint`, by walking its LC_SYMTAB in memory.
static void *find_local_symbol(const char *imageHint, const char *symbol) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, imageHint)) continue;
        const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const struct load_command *lc = (const void *)(mh + 1);
        const struct segment_command_64 *linkedit = NULL;
        const struct symtab_command *symtab = NULL;
        for (uint32_t c = 0; c < mh->ncmds; c++) {
            if (lc->cmd == LC_SEGMENT_64 && !strcmp(((const struct segment_command_64 *)lc)->segname, SEG_LINKEDIT))
                linkedit = (const void *)lc;
            if (lc->cmd == LC_SYMTAB) symtab = (const void *)lc;
            lc = (const void *)((const char *)lc + lc->cmdsize);
        }
        if (!linkedit || !symtab) return NULL;
        uintptr_t base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
        const struct nlist_64 *syms = (const void *)(base + symtab->symoff);
        const char *strs = (const char *)(base + symtab->stroff);
        for (uint32_t s = 0; s < symtab->nsyms; s++) {
            if ((syms[s].n_type & N_STAB) || (syms[s].n_type & N_TYPE) != N_SECT) continue;
            if (!strcmp(strs + syms[s].n_un.n_strx, symbol)) return (void *)(syms[s].n_value + slide);
        }
        return NULL;
    }
    return NULL;
}

// Mirrors libgphoto2's PTPPropValue union closely enough for a UINT32 (it's 16 bytes).
typedef union { uint32_t u32; unsigned char pad[16]; } SonyPropValue;
typedef uint16_t (*SonyControlFn)(void *params, uint16_t code, SonyPropValue *value, uint16_t datatype);

int gpb_sony_control(GPBCamera *cam, unsigned short code, unsigned int value) {
    static SonyControlFn fn;
    if (!fn) fn = (SonyControlFn)find_local_symbol("/ptp2.so", "_ptp_sony_setdevicecontrolvalueb");
    if (!fn) return -1;
    // The ptp2 camlib's private data starts with its PTPParams.
    void *params = (void *)cam->camera->pl;
    SonyPropValue v;
    memset(&v, 0, sizeof v);
    v.u32 = value;
    return fn(params, code, &v, 0x0006 /* PTP_DTC_UINT32 */);
}

const char *gpb_result_string(int result) { return gp_result_as_string(result); }
