/*
 * Register stub shared by the snom machines; defined in snom_d375.c.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#ifndef SNOM_COMMON_H
#define SNOM_COMMON_H

#include "exec/hwaddr.h"

typedef struct SnomIoStubState SnomIoStubState;

SnomIoStubState *snom_map_stub(const char *name, hwaddr base, uint64_t size);
void snom_stub_preset(SnomIoStubState *s, hwaddr addr, uint32_t val);
void snom_stub_fixed(SnomIoStubState *s, hwaddr addr, uint32_t val);
void snom_stub_autoclear(SnomIoStubState *s, hwaddr addr, uint32_t mask);
void snom_stub_reset_on(SnomIoStubState *s, hwaddr addr, uint32_t mask,
                        uint32_t val);

#endif
