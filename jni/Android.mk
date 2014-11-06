LOCAL_PATH := $(call my-dir)/smem
include $(CLEAR_VARS)
LOCAL_MODULE := smemcap
LOCAL_SRC_FILES := smemcap.c
include $(BUILD_EXECUTABLE)

