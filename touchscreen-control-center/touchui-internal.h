#ifndef MU5252_TOUCHUI_INTERNAL_H
#define MU5252_TOUCHUI_INTERNAL_H

#include "touchui-abi.h"
#include "touchui-model.h"
#include "touchui-state.h"
/* 定义在 touchui-worker.inc；网络数据源（先包含）需要用同一时间基准 */
static long long monotonic_millis(void);

#endif
