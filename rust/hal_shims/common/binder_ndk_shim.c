#include "binder_ndk_shim.h"

#include <android/binder_ibinder.h>
#include <android/binder_manager.h>
#include <android/binder_status.h>

bool binder_ndk_ping(const char *instance) {
	if (instance == NULL) {
		return false;
	}

	AIBinder *binder = AServiceManager_waitForService(instance);
	if (binder == NULL) {
		return false;
	}

	const binder_status_t status = AIBinder_ping(binder);
	AIBinder_decStrong(binder);
	return status == STATUS_OK;
}
