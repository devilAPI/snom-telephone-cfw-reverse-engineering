/*
 * snom D375 desk phone: Broadcom BCM11107 ("bcmring"), ARM1176, 256 MB DDR.
 *
 * Boots the unmodified kernel out of a snom firmware image. The address map
 * and interrupt numbers come from Linux 3.0 arch/arm/mach-bcmring; see
 * docs/qemu.md.
 *
 * Anything without a model is backed by snom-iostub, a sparse register store:
 * reads return the last written value, and the first access to each address
 * is logged under "-d unimp". That log is the to-do list for this file.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include "qemu/osdep.h"
#include "qapi/error.h"
#include "qemu/log.h"
#include "qemu/units.h"
#include "qemu/error-report.h"
#include "hw/core/sysbus.h"
#include "hw/core/boards.h"
#include "hw/core/irq.h"
#include "hw/core/ptimer.h"
#include "hw/core/qdev-properties.h"
#include "hw/arm/boot.h"
#include "hw/arm/machines-qom.h"
#include "hw/char/pl011.h"
#include "hw/core/or-irq.h"
#include "qemu/timer.h"
#include "net/net.h"
#include "ui/console.h"
#include "ui/input.h"
#include "standard-headers/linux/input-event-codes.h"
#include "qemu/guest-random.h"
#include "hw/core/qdev-properties-system.h"
#include "system/block-backend.h"
#include "system/blockdev.h"
#include "system/address-spaces.h"
#include "system/memory.h"
#include "system/system.h"
#include "system/runstate.h"
#include "target/arm/cpu-qom.h"
#include "qom/object.h"
#include "snom_common.h"

/* Physical map (mach/csp/mm_addr.h) */
#define MM_FLASHC       0x20000000
#define MM_BROM         0x30000000
#define MM_ARAM         0x30100000
#define MM_DMA0         0x30200000
#define MM_DMA1         0x30300000
#define MM_ESW          0x30400000
#define MM_ESW_CTL      0x304a0000
#define MM_CLCD         0x30500000
#define MM_VRAM         0x40000000
#define MM_CHIPC        0x80000000
#define MM_UMI          0x80001000
#define MM_NAND         0x80001800
#define MM_SPUMP        0x8000a000
#define MM_KEYC         0x8000d000
#define MM_RNG          0x8000c000
#define MM_USB_PHY      0x80420000
#define MM_UARTA        0x80012000
#define MM_UARTB        0x80013000
#define MM_TMR          0x80017000
#define MM_SINTC        0x80100000
#define MM_INTC0        0x80200000
#define MM_INTC1        0x80201000

/* Interrupts, numbered per controller */
#define INTC0_TIMER0    22
#define INTC1_UARTB     12
#define INTC1_UARTA     14
#define INTC1_KEYC      16

#define CHIPC_SOFT_RESET1 0x80

#define DMA_COMP_PARM1_HI 0x00000700

#define SNOM_BOARD_ID   0x922
#define SNOM_PHYS_OFFSET 0x00200000

#define TMR_CHANNELS    4
#define TMR_LOW_HZ      25000000    /* timers 0-2: 25 MHz crystal */
#define TMR_HIGH_HZ     166000000   /* timer 3: bus clock */

/* ---- Four SP804 channels with an interrupt line each ------------------- */

#define TYPE_SNOM_TIMER "snom-timer"
OBJECT_DECLARE_SIMPLE_TYPE(SnomTimerState, SNOM_TIMER)

typedef struct SnomTimerChan {
    ptimer_state *pt;
    SnomTimerState *parent;
    qemu_irq irq;
    uint32_t ctrl, limit, bgload, freq;
    int raw;
} SnomTimerChan;

struct SnomTimerState {
    SysBusDevice parent_obj;
    MemoryRegion mmio;
    SnomTimerChan ch[TMR_CHANNELS];
};

#define TCTRL_ONESHOT   (1 << 0)
#define TCTRL_32BIT     (1 << 1)
#define TCTRL_IE        (1 << 5)
#define TCTRL_PERIODIC  (1 << 6)
#define TCTRL_ENABLE    (1 << 7)

static void snom_timer_update(SnomTimerChan *c)
{
    qemu_set_irq(c->irq, c->raw && (c->ctrl & TCTRL_IE));
}

static void snom_timer_tick(void *opaque)
{
    SnomTimerChan *c = opaque;

    c->raw = 1;
    snom_timer_update(c);
}

/* Call inside a ptimer transaction. */
static void snom_timer_reload(SnomTimerChan *c, int reload)
{
    uint64_t limit;

    if (!(c->ctrl & (TCTRL_PERIODIC | TCTRL_ONESHOT))) {
        limit = (c->ctrl & TCTRL_32BIT) ? 0xffffffffULL : 0xffff;
    } else {
        limit = (c->ctrl & TCTRL_32BIT) ? c->limit : (c->limit & 0xffff);
    }
    ptimer_set_limit(c->pt, limit, reload);
}

static uint64_t snom_timer_read(void *opaque, hwaddr off, unsigned size)
{
    SnomTimerState *s = opaque;
    SnomTimerChan *c = &s->ch[(off >> 5) & 3];

    if (off >= TMR_CHANNELS * 0x20) {
        return 0;
    }
    switch (off & 0x1f) {
    case 0x00: return c->limit;
    case 0x04: return ptimer_get_count(c->pt);
    case 0x08: return c->ctrl;
    case 0x10: return c->raw;
    case 0x14: return c->raw && (c->ctrl & TCTRL_IE);
    case 0x18: return c->bgload;
    }
    return 0;
}

static void snom_timer_write(void *opaque, hwaddr off, uint64_t val,
                             unsigned size)
{
    SnomTimerState *s = opaque;
    SnomTimerChan *c = &s->ch[(off >> 5) & 3];
    int shift;

    if (off >= TMR_CHANNELS * 0x20) {
        return;
    }
    ptimer_transaction_begin(c->pt);
    switch (off & 0x1f) {
    case 0x00:
        c->limit = val;
        c->bgload = val;
        snom_timer_reload(c, 1);
        break;
    case 0x08:
        if (c->ctrl & TCTRL_ENABLE) {
            ptimer_stop(c->pt);
        }
        c->ctrl = val;
        shift = (val >> 2) & 3;
        ptimer_set_freq(c->pt, c->freq >> (shift == 1 ? 4 :
                                           shift == 2 ? 8 : 0));
        snom_timer_reload(c, 0);
        if (c->ctrl & TCTRL_ENABLE) {
            ptimer_run(c->pt, !!(c->ctrl & TCTRL_ONESHOT));
        }
        break;
    case 0x0c:
        c->raw = 0;
        break;
    case 0x18:
        c->limit = val;
        c->bgload = val;
        snom_timer_reload(c, 0);
        break;
    }
    ptimer_transaction_commit(c->pt);
    snom_timer_update(c);
}

static const MemoryRegionOps snom_timer_ops = {
    .read = snom_timer_read,
    .write = snom_timer_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid.min_access_size = 1,
    .valid.max_access_size = 4,
};

static void snom_timer_init(Object *obj)
{
    SnomTimerState *s = SNOM_TIMER(obj);
    int i;

    memory_region_init_io(&s->mmio, obj, &snom_timer_ops, s, "snom-timer",
                          0x800);
    sysbus_init_mmio(SYS_BUS_DEVICE(obj), &s->mmio);
    for (i = 0; i < TMR_CHANNELS; i++) {
        SnomTimerChan *c = &s->ch[i];

        c->parent = s;
        c->freq = i == 3 ? TMR_HIGH_HZ : TMR_LOW_HZ;
        c->ctrl = TCTRL_IE;
        c->limit = 0xffffffff;
        c->pt = ptimer_init(snom_timer_tick, c, PTIMER_POLICY_LEGACY);
        ptimer_transaction_begin(c->pt);
        ptimer_set_freq(c->pt, c->freq);
        ptimer_transaction_commit(c->pt);
        sysbus_init_irq(SYS_BUS_DEVICE(obj), &c->irq);
    }
}

/*
 * A guest reboot must stop everything these models keep running. A timer or DMA
 * channel left active keeps firing into the new kernel, which leaves the VM
 * crawling with one host core busy, and writes into memory it no longer owns.
 */
static void snom_timer_reset(DeviceState *dev)
{
    SnomTimerState *s = SNOM_TIMER(dev);
    int i;

    for (i = 0; i < TMR_CHANNELS; i++) {
        SnomTimerChan *c = &s->ch[i];

        ptimer_transaction_begin(c->pt);
        ptimer_stop(c->pt);
        ptimer_set_freq(c->pt, c->freq);
        ptimer_transaction_commit(c->pt);
        c->ctrl = TCTRL_IE;
        c->limit = 0xffffffff;
        c->bgload = 0;
        c->raw = 0;
        qemu_set_irq(c->irq, 0);
    }
}

static void snom_timer_class_init(ObjectClass *oc, const void *data)
{
    device_class_set_legacy_reset(DEVICE_CLASS(oc), snom_timer_reset);
}

static const TypeInfo snom_timer_info = {
    .name = TYPE_SNOM_TIMER,
    .parent = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(SnomTimerState),
    .instance_init = snom_timer_init,
    .class_init = snom_timer_class_init,
};

/* ---- Sparse register store for everything without a model -------------- */

#define TYPE_SNOM_IOSTUB "snom-iostub"
DECLARE_INSTANCE_CHECKER(SnomIoStubState, SNOM_IOSTUB, TYPE_SNOM_IOSTUB)

struct SnomIoStubState {
    SysBusDevice parent_obj;
    MemoryRegion mmio;
    GHashTable *regs;    /* word offset -> last value */
    GHashTable *seen;    /* word offset -> logged */
    GHashTable *autoclr; /* word offset -> bits that clear themselves */
    GHashTable *fixed;   /* word offset -> value that ignores writes */
    char *name;
    uint64_t base;
    uint64_t size;
    hwaddr reset_off;
    uint32_t reset_mask, reset_val;
};

static void snom_iostub_log(SnomIoStubState *s, hwaddr off, const char *what,
                            uint64_t val)
{
    gpointer key = GUINT_TO_POINTER((guint)(off & ~3) + 1);

    if (!g_hash_table_contains(s->seen, key)) {
        g_hash_table_add(s->seen, key);
        qemu_log_mask(LOG_UNIMP, "iostub %s: first %s 0x%08" PRIx64
                      " = 0x%08" PRIx64 "\n", s->name, what, s->base + off,
                      val);
    }
}

static uint64_t snom_iostub_read(void *opaque, hwaddr off, unsigned size)
{
    SnomIoStubState *s = opaque;
    gpointer key = GUINT_TO_POINTER((guint)(off & ~3) + 1);
    uint32_t v = GPOINTER_TO_UINT(g_hash_table_lookup(s->regs, key));

    snom_iostub_log(s, off, "read", v);
    return extract32(v, (off & 3) * 8, MIN(size * 8, 32));
}

static void snom_iostub_write(void *opaque, hwaddr off, uint64_t val,
                              unsigned size)
{
    SnomIoStubState *s = opaque;
    gpointer key = GUINT_TO_POINTER((guint)(off & ~3) + 1);
    uint32_t v = GPOINTER_TO_UINT(g_hash_table_lookup(s->regs, key));

    v = deposit32(v, (off & 3) * 8, MIN(size * 8, 32), val);
    v &= ~GPOINTER_TO_UINT(g_hash_table_lookup(s->autoclr, key));
    if (g_hash_table_contains(s->fixed, key)) {
        return;
    }
    g_hash_table_insert(s->regs, key, GUINT_TO_POINTER(v));
    snom_iostub_log(s, off, "write", val);
    if (s->reset_mask && off == s->reset_off &&
        (val & s->reset_mask) == s->reset_val) {
        qemu_system_reset_request(SHUTDOWN_CAUSE_GUEST_RESET);
    }
}

static const MemoryRegionOps snom_iostub_ops = {
    .read = snom_iostub_read,
    .write = snom_iostub_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid.min_access_size = 1,
    .valid.max_access_size = 4,
    .impl.min_access_size = 1,
    .impl.max_access_size = 4,
};

static void snom_iostub_realize(DeviceState *dev, Error **errp)
{
    SnomIoStubState *s = SNOM_IOSTUB(dev);

    s->regs = g_hash_table_new(g_direct_hash, g_direct_equal);
    s->seen = g_hash_table_new(g_direct_hash, g_direct_equal);
    s->autoclr = g_hash_table_new(g_direct_hash, g_direct_equal);
    s->fixed = g_hash_table_new(g_direct_hash, g_direct_equal);
    memory_region_init_io(&s->mmio, OBJECT(dev), &snom_iostub_ops, s,
                          s->name, s->size);
    sysbus_init_mmio(SYS_BUS_DEVICE(dev), &s->mmio);
}

static const Property snom_iostub_props[] = {
    DEFINE_PROP_STRING("name", SnomIoStubState, name),
    DEFINE_PROP_UINT64("base", SnomIoStubState, base, 0),
    DEFINE_PROP_UINT64("size", SnomIoStubState, size, 0),
};

static void snom_iostub_class_init(ObjectClass *oc, const void *data)
{
    DeviceClass *dc = DEVICE_CLASS(oc);

    dc->realize = snom_iostub_realize;
    device_class_set_props(dc, snom_iostub_props);
}

static const TypeInfo snom_iostub_info = {
    .name = TYPE_SNOM_IOSTUB,
    .parent = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(SnomIoStubState),
    .class_init = snom_iostub_class_init,
};

void snom_stub_preset(SnomIoStubState *s, hwaddr addr, uint32_t val)
{
    g_hash_table_insert(s->regs,
                        GUINT_TO_POINTER((guint)(addr - s->base) + 1),
                        GUINT_TO_POINTER(val));
}

/* Writing val to addr, under mask, restarts the machine. */
void snom_stub_reset_on(SnomIoStubState *s, hwaddr addr, uint32_t mask,
                        uint32_t val)
{
    s->reset_off = addr - s->base;
    s->reset_mask = mask;
    s->reset_val = val;
}

/* Read-only status and ID registers. */
void snom_stub_fixed(SnomIoStubState *s, hwaddr addr, uint32_t val)
{
    snom_stub_preset(s, addr, val);
    g_hash_table_add(s->fixed, GUINT_TO_POINTER((guint)(addr - s->base) + 1));
}

/* Bits such as soft-reset that hardware clears as soon as they are set. */
void snom_stub_autoclear(SnomIoStubState *s, hwaddr addr, uint32_t mask)
{
    g_hash_table_insert(s->autoclr,
                        GUINT_TO_POINTER((guint)(addr - s->base) + 1),
                        GUINT_TO_POINTER(mask));
}

SnomIoStubState *snom_map_stub(const char *name, hwaddr base, uint64_t size)
{
    DeviceState *d = qdev_new(TYPE_SNOM_IOSTUB);

    qdev_prop_set_string(d, "name", name);
    qdev_prop_set_uint64(d, "base", base);
    qdev_prop_set_uint64(d, "size", size);
    sysbus_realize_and_unref(SYS_BUS_DEVICE(d), &error_fatal);
    sysbus_mmio_map_overlap(SYS_BUS_DEVICE(d), 0, base, -1000);
    return SNOM_IOSTUB(d);
}

/* ---- 128 MiB large-page NAND behind the UMI controller ------------------ */

#define TYPE_SNOM_NAND "snom-nand"
OBJECT_DECLARE_SIMPLE_TYPE(SnomNandState, SNOM_NAND)

#define NAND_PAGE       2048
#define NAND_OOB        64
#define NAND_RAW_PAGE   (NAND_PAGE + NAND_OOB)
#define NAND_PAGES      65536
#define NAND_PPB        64
#define NAND_BYTES      ((uint64_t)NAND_PAGES * NAND_RAW_PAGE)

enum { NAND_IDLE, NAND_RD_ID, NAND_RD_STATUS, NAND_RD_DATA, NAND_WR_DATA };

struct SnomNandState {
    SysBusDevice parent_obj;
    MemoryRegion mmio;
    BlockBackend *blk;
    uint8_t *store;
    uint8_t page[NAND_RAW_PAGE];
    uint8_t addr[5];
    unsigned naddr, pos, mode;
    uint8_t cmd;
    bool status_only;
};

/* Samsung K9F1G08: 128 MiB, 2 KiB pages, 128 KiB blocks, 8 bit. */
static const uint8_t snom_nand_id[5] = { 0xec, 0xf1, 0x00, 0x95, 0x40 };

static unsigned snom_nand_row(SnomNandState *s, unsigned first)
{
    return (s->addr[first] | (s->addr[first + 1] << 8)) % NAND_PAGES;
}

static void snom_nand_store_range(SnomNandState *s, uint64_t off, uint64_t len)
{
    if (s->blk && blk_pwrite(s->blk, off, len, s->store + off, 0) < 0) {
        error_report("snom-nand: write to backing file failed");
    }
}

static void snom_nand_set_col(SnomNandState *s)
{
    s->pos = MIN(s->addr[0] | (s->addr[1] << 8), NAND_RAW_PAGE);
}

static void snom_nand_command(SnomNandState *s, uint8_t cmd)
{
    uint64_t off;
    unsigned row, i;

    switch (cmd) {
    case 0xff:                  /* reset */
        s->mode = NAND_IDLE;
        break;
    case 0x90:                  /* read ID */
        s->mode = NAND_RD_ID;
        s->pos = 0;
        break;
    case 0x70:                  /* read status */
        s->status_only = true;
        return;
    case 0x30:                  /* read confirm */
        memcpy(s->page, s->store + (uint64_t)snom_nand_row(s, 2) *
               NAND_RAW_PAGE, NAND_RAW_PAGE);
        snom_nand_set_col(s);
        s->mode = NAND_RD_DATA;
        break;
    case 0xe0:                  /* random data output confirm */
        snom_nand_set_col(s);
        s->mode = NAND_RD_DATA;
        break;
    case 0x80:                  /* page program setup */
        memset(s->page, 0xff, sizeof(s->page));
        s->naddr = 0;
        s->mode = NAND_WR_DATA;
        s->pos = 0;
        break;
    case 0x10:                  /* page program confirm */
        off = (uint64_t)snom_nand_row(s, 2) * NAND_RAW_PAGE;
        for (i = 0; i < NAND_RAW_PAGE; i++) {
            s->store[off + i] &= s->page[i];
        }
        snom_nand_store_range(s, off, NAND_RAW_PAGE);
        s->mode = NAND_IDLE;
        break;
    case 0xd0:                  /* block erase confirm */
        row = snom_nand_row(s, 0) & ~(NAND_PPB - 1);
        off = (uint64_t)row * NAND_RAW_PAGE;
        memset(s->store + off, 0xff, NAND_PPB * NAND_RAW_PAGE);
        snom_nand_store_range(s, off, NAND_PPB * NAND_RAW_PAGE);
        s->mode = NAND_IDLE;
        break;
    }
    s->status_only = false;
    s->cmd = cmd;
    if (cmd != 0x10 && cmd != 0xd0 && cmd != 0x30 && cmd != 0xe0) {
        s->naddr = 0;
    }
}

static uint8_t snom_nand_data_in(SnomNandState *s)
{
    if (s->status_only) {
        return 0xc0;            /* ready, not write-protected */
    }
    switch (s->mode) {
    case NAND_RD_ID:
        return snom_nand_id[s->pos++ % sizeof(snom_nand_id)];
    case NAND_RD_DATA:
        return s->pos < NAND_RAW_PAGE ? s->page[s->pos++] : 0xff;
    }
    return 0xc0;
}

static uint64_t snom_nand_read(void *opaque, hwaddr off, unsigned size)
{
    SnomNandState *s = opaque;
    uint32_t v = 0;
    unsigned i;

    if (off >= 8) {
        for (i = 0; i < size; i++) {
            v |= (uint32_t)snom_nand_data_in(s) << (i * 8);
        }
    }
    return v;
}

static void snom_nand_write(void *opaque, hwaddr off, uint64_t val,
                            unsigned size)
{
    SnomNandState *s = opaque;
    unsigned i;

    if (off == 0) {
        snom_nand_command(s, val);
    } else if (off == 4) {
        if (s->cmd == 0x85 && s->naddr == 0) {
            memset(s->addr, 0, sizeof(s->addr));
        }
        if (s->naddr < sizeof(s->addr)) {
            s->addr[s->naddr++] = val;
        }
        if (s->mode == NAND_WR_DATA && s->naddr == 2) {
            snom_nand_set_col(s);
        }
    } else if (s->mode == NAND_WR_DATA) {
        for (i = 0; i < size && s->pos < NAND_RAW_PAGE; i++) {
            s->page[s->pos++] = val >> (i * 8);
        }
    }
}

static const MemoryRegionOps snom_nand_ops = {
    .read = snom_nand_read,
    .write = snom_nand_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid.min_access_size = 1,
    .valid.max_access_size = 4,
};

static void snom_nand_realize(DeviceState *dev, Error **errp)
{
    SnomNandState *s = SNOM_NAND(dev);

    s->store = g_malloc(NAND_BYTES);
    memset(s->store, 0xff, NAND_BYTES);
    if (s->blk) {
        if (blk_set_perm(s->blk, BLK_PERM_CONSISTENT_READ | BLK_PERM_WRITE,
                         BLK_PERM_ALL, errp) < 0) {
            return;
        }
        if (blk_getlength(s->blk) != NAND_BYTES) {
            error_setg(errp, "NAND image must be %" PRIu64 " bytes",
                       NAND_BYTES);
            return;
        }
        if (blk_pread(s->blk, 0, NAND_BYTES, s->store, 0) < 0) {
            error_setg(errp, "cannot read NAND image");
            return;
        }
    }
    memory_region_init_io(&s->mmio, OBJECT(dev), &snom_nand_ops, s,
                          "snom-nand", 0x800);
    sysbus_init_mmio(SYS_BUS_DEVICE(dev), &s->mmio);
}

static const Property snom_nand_props[] = {
    DEFINE_PROP_DRIVE("drive", SnomNandState, blk),
};

static void snom_nand_reset(DeviceState *dev)
{
    SnomNandState *s = SNOM_NAND(dev);

    s->mode = NAND_IDLE;
    s->naddr = s->pos = 0;
    s->cmd = 0;
    s->status_only = false;
}

static void snom_nand_class_init(ObjectClass *oc, const void *data)
{
    DeviceClass *dc = DEVICE_CLASS(oc);

    dc->realize = snom_nand_realize;
    device_class_set_legacy_reset(dc, snom_nand_reset);
    device_class_set_props(dc, snom_nand_props);
}

static const TypeInfo snom_nand_info = {
    .name = TYPE_SNOM_NAND,
    .parent = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(SnomNandState),
    .class_init = snom_nand_class_init,
};

/* ---- Synopsys DesignWare AHB DMA controller ----------------------------- */

#define TYPE_SNOM_DMA "snom-dma"
OBJECT_DECLARE_SIMPLE_TYPE(SnomDmaState, SNOM_DMA)

#define DMA_CHANNELS    8
#define DMA_CH_STRIDE   0x58
#define DMA_RAW         0x2c0   /* Tfr, Block, SrcTran, DstTran, Err */
#define DMA_STATUS      0x2e8
#define DMA_MASK        0x310
#define DMA_CLEAR       0x338
#define DMA_STATUS_INT  0x360
#define DMA_CFG         0x398
#define DMA_CH_EN       0x3a0
#define DMA_NUM_INT     5

#define DMA_CH_SAR      0x00
#define DMA_CH_DAR      0x08
#define DMA_CH_LLP      0x10
#define DMA_CH_CTL_LO   0x18
#define DMA_CH_CTL_HI   0x1c

#define CTL_INT_EN      (1 << 0)
#define CTL_TT_FC(v)    (((v) >> 20) & 7)
#define CTL_LLP_EN      (3 << 27)
#define CTLH_DONE       (1 << 12)

/* Peripheral channels run off a timer; each block takes this long. */
#define DMA_PERIPH_BLOCK_NS (5 * SCALE_MS)

struct SnomDmaState {
    SysBusDevice parent_obj;
    MemoryRegion mmio;
    qemu_irq irq[DMA_CHANNELS];
    uint32_t regs[0x400 / 4];
    uint8_t raw[DMA_NUM_INT];
    uint8_t mask[DMA_NUM_INT];
    uint8_t chen;
    QEMUTimer *timer[DMA_CHANNELS];
    bool cfg_en;
    uint32_t cur_desc[DMA_CHANNELS];

    /* Ethernet switch FIFOs hang off the second controller. */
    bool esw;
    NICState *nic;
    NICConf conf;
    uint32_t rx_desc;
    int rx_ch;
};

#define DMA_REG(s, off) ((s)->regs[(off) / 4])
#define DMA_CHR(s, ch, off) DMA_REG(s, (ch) * DMA_CH_STRIDE + (off))

static void snom_dma_update(SnomDmaState *s)
{
    int ch, t;

    for (ch = 0; ch < DMA_CHANNELS; ch++) {
        int level = 0;

        for (t = 0; t < DMA_NUM_INT; t++) {
            level |= (s->raw[t] & s->mask[t]) >> ch & 1;
        }
        qemu_set_irq(s->irq[ch], level && s->cfg_en);
    }
}

static void snom_dma_desc_done(SnomDmaState *s, int ch, uint32_t hi)
{
    uint32_t wb = cpu_to_le32(hi | CTLH_DONE);

    if (s->cur_desc[ch]) {
        address_space_write(&address_space_memory, s->cur_desc[ch] + 0x10,
                            MEMTXATTRS_UNSPECIFIED, &wb, sizeof(wb));
    }
}

/* Copy one block. Returns true if another descriptor follows. */
static bool snom_dma_block(SnomDmaState *s, int ch)
{
    uint32_t lo = DMA_CHR(s, ch, DMA_CH_CTL_LO);
    uint32_t hi = DMA_CHR(s, ch, DMA_CH_CTL_HI);
    uint32_t sar = DMA_CHR(s, ch, DMA_CH_SAR);
    uint32_t dar = DMA_CHR(s, ch, DMA_CH_DAR);
    uint32_t llp = DMA_CHR(s, ch, DMA_CH_LLP);
    uint32_t len = (hi & 0xfff) << ((lo >> 4) & 7);
    unsigned sinc = (lo >> 9) & 3, dinc = (lo >> 7) & 3;
    AddressSpace *as = &address_space_memory;
    uint32_t i, w = 1u << ((lo >> 1) & 7), r = 1u << ((lo >> 4) & 7);
    g_autofree uint8_t *buf = g_malloc0(len + 8);

    if (sinc == 0) {
        address_space_read(as, sar, MEMTXATTRS_UNSPECIFIED, buf, len);
    } else {
        for (i = 0; i < len; i += r) {
            address_space_read(as, sar, MEMTXATTRS_UNSPECIFIED, buf + i, r);
        }
    }
    if (dinc == 0) {
        address_space_write(as, dar, MEMTXATTRS_UNSPECIFIED, buf, len);
    } else {
        for (i = 0; i < len; i += w) {
            address_space_write(as, dar, MEMTXATTRS_UNSPECIFIED, buf + i, w);
        }
    }

    if (lo & CTL_INT_EN) {
        s->raw[1] |= 1 << ch;
    }
    if (!(lo & CTL_LLP_EN) || !(llp & ~3u)) {
        snom_dma_desc_done(s, ch, hi);
        return false;
    }

    /* Load the next descriptor. The driver never looks at DONE. */
    {
        uint32_t d[5];
        address_space_read(as, llp & ~3u, MEMTXATTRS_UNSPECIFIED, d,
                           sizeof(d));
        DMA_CHR(s, ch, DMA_CH_SAR) = le32_to_cpu(d[0]);
        DMA_CHR(s, ch, DMA_CH_DAR) = le32_to_cpu(d[1]);
        DMA_CHR(s, ch, DMA_CH_LLP) = le32_to_cpu(d[2]);
        DMA_CHR(s, ch, DMA_CH_CTL_LO) = le32_to_cpu(d[3]);
        DMA_CHR(s, ch, DMA_CH_CTL_HI) = le32_to_cpu(d[4]);
    }
    return true;
}

static void snom_dma_finish(SnomDmaState *s, int ch)
{
    s->raw[0] |= 1 << ch;
    s->chen &= ~(1 << ch);
    snom_dma_update(s);
}

/*
 * Ethernet switch datapath. A transmitted frame is a two-descriptor chain: an
 * 8-byte control word to one FIFO (its low bits give the start offset of the
 * frame in the 8-byte-aligned buffer), then the frame to the other. The frame
 * carries a 4-byte switch tag after the MAC addresses, and block counts are in
 * 8-byte units, so a frame may end with up to 7 pad bytes; IP ignores those.
 *
 * Received frames need the same tag plus a 4-byte FCS, because the driver
 * strips both. The length goes in bits 28:13 of the descriptor's SSTAT word.
 */
#define ESW_RX_FIFO     0x3048
#define ESW_TX_FIFO     0x3049
#define ESW_TX_CONFIG   0x30490008
#define ESW_TAG_LEN     4
#define ESW_FCS_LEN     4
#define ESW_MAC_LEN     12
#define ESW_MAX_FRAME   2048

static void snom_esw_transmit(SnomDmaState *s, int ch)
{
    AddressSpace *as = &address_space_memory;
    uint8_t ctlword[8] = { 0 };
    int guard = 4096;

    while (guard--) {
        uint32_t lo = DMA_CHR(s, ch, DMA_CH_CTL_LO);
        uint32_t hi = DMA_CHR(s, ch, DMA_CH_CTL_HI);
        uint32_t sar = DMA_CHR(s, ch, DMA_CH_SAR);
        uint32_t llp = DMA_CHR(s, ch, DMA_CH_LLP);
        uint32_t len = (hi & 0xfff) * 8;
        uint32_t d[5];

        if (DMA_CHR(s, ch, DMA_CH_DAR) == ESW_TX_CONFIG) {
            address_space_read(as, sar, MEMTXATTRS_UNSPECIFIED, ctlword,
                               sizeof(ctlword));
        } else if (len >= 8 && len <= ESW_MAX_FRAME) {
            g_autofree uint8_t *buf = g_malloc(len);
            unsigned off = ctlword[0] & 7;

            address_space_read(as, sar, MEMTXATTRS_UNSPECIFIED, buf, len);
            if (s->nic && len - off > ESW_MAC_LEN + ESW_TAG_LEN) {
                uint8_t *f = buf + off;
                size_t flen = len - off;

                memmove(f + ESW_TAG_LEN, f, ESW_MAC_LEN);
                qemu_send_packet(qemu_get_queue(s->nic), f + ESW_TAG_LEN,
                                 flen - ESW_TAG_LEN);
            }
        }
        snom_dma_desc_done(s, ch, hi);
        if (lo & CTL_INT_EN) {
            s->raw[1] |= 1 << ch;
        }
        if (!(lo & CTL_LLP_EN) || !(llp & ~3u)) {
            return;
        }
        s->cur_desc[ch] = llp & ~3u;
        address_space_read(as, llp & ~3u, MEMTXATTRS_UNSPECIFIED, d, sizeof(d));
        DMA_CHR(s, ch, DMA_CH_SAR) = le32_to_cpu(d[0]);
        DMA_CHR(s, ch, DMA_CH_DAR) = le32_to_cpu(d[1]);
        DMA_CHR(s, ch, DMA_CH_LLP) = le32_to_cpu(d[2]);
        DMA_CHR(s, ch, DMA_CH_CTL_LO) = le32_to_cpu(d[3]);
        DMA_CHR(s, ch, DMA_CH_CTL_HI) = le32_to_cpu(d[4]);
    }
}

static ssize_t snom_esw_receive(NetClientState *nc, const uint8_t *buf,
                                size_t size)
{
    SnomDmaState *s = qemu_get_nic_opaque(nc);
    AddressSpace *as = &address_space_memory;
    uint8_t frame[ESW_MAX_FRAME];
    uint32_t d[6], hw, status;
    size_t len;

    if (!s->rx_desc || size < ESW_MAC_LEN ||
        size + ESW_TAG_LEN + ESW_FCS_LEN > sizeof(frame)) {
        return size;
    }
    address_space_read(as, s->rx_desc, MEMTXATTRS_UNSPECIFIED, d, sizeof(d));
    if (d[5]) {
        return size;            /* ring full: the driver has not caught up */
    }

    memcpy(frame, buf, ESW_MAC_LEN);
    memset(frame + ESW_MAC_LEN, 0, ESW_TAG_LEN);
    memcpy(frame + ESW_MAC_LEN + ESW_TAG_LEN, buf + ESW_MAC_LEN,
           size - ESW_MAC_LEN);
    len = size + ESW_TAG_LEN;
    memset(frame + len, 0, ESW_FCS_LEN);
    len += ESW_FCS_LEN;

    address_space_write(as, le32_to_cpu(d[1]), MEMTXATTRS_UNSPECIFIED, frame,
                        len);
    status = cpu_to_le32(len << 13);
    hw = cpu_to_le32(le32_to_cpu(d[4]) | CTLH_DONE);
    address_space_write(as, s->rx_desc + 0x14, MEMTXATTRS_UNSPECIFIED, &status,
                        sizeof(status));
    address_space_write(as, s->rx_desc + 0x10, MEMTXATTRS_UNSPECIFIED, &hw,
                        sizeof(hw));
    s->rx_desc = le32_to_cpu(d[2]) & ~3u;
    s->raw[1] |= 1 << s->rx_ch;
    snom_dma_update(s);
    return size;
}

static NetClientInfo snom_esw_net_info = {
    .type = NET_CLIENT_DRIVER_NIC,
    .size = sizeof(NICState),
    .receive = snom_esw_receive,
};

static void snom_dma_periph_tick(void *opaque);

typedef struct SnomDmaTimerArg {
    SnomDmaState *s;
    int ch;
} SnomDmaTimerArg;

static void snom_dma_start(SnomDmaState *s, int ch)
{
    uint32_t llp = DMA_CHR(s, ch, DMA_CH_LLP);
    uint32_t lo = DMA_CHR(s, ch, DMA_CH_CTL_LO);

    s->cur_desc[ch] = 0;

    /* With LLP enabled, the channel starts by fetching the first descriptor */
    if ((lo & CTL_LLP_EN) && (llp & ~3u)) {
        uint32_t d[5];

        s->cur_desc[ch] = llp & ~3u;

        address_space_read(&address_space_memory, llp & ~3u,
                           MEMTXATTRS_UNSPECIFIED, d, sizeof(d));
        DMA_CHR(s, ch, DMA_CH_SAR) = le32_to_cpu(d[0]);
        DMA_CHR(s, ch, DMA_CH_DAR) = le32_to_cpu(d[1]);
        DMA_CHR(s, ch, DMA_CH_LLP) = le32_to_cpu(d[2]);
        DMA_CHR(s, ch, DMA_CH_CTL_LO) = le32_to_cpu(d[3]);
        DMA_CHR(s, ch, DMA_CH_CTL_HI) = le32_to_cpu(d[4]);
        lo = DMA_CHR(s, ch, DMA_CH_CTL_LO);
    }

    if (CTL_TT_FC(lo) == 0) {
        /* Memory to memory completes at once; rings are never used here. */
        int guard = 100000;

        while (snom_dma_block(s, ch) && --guard) {
            /* next descriptor */
        }
        snom_dma_finish(s, ch);
    } else if (DMA_CHR(s, ch, DMA_CH_SAR) >> 16 == ESW_RX_FIFO) {
        /* Ethernet receive ring: idle until a frame arrives. */
        s->rx_desc = s->cur_desc[ch];
        s->rx_ch = ch;
    } else if (DMA_CHR(s, ch, DMA_CH_DAR) >> 16 == ESW_TX_FIFO) {
        snom_esw_transmit(s, ch);
        snom_dma_finish(s, ch);
    } else {
        timer_mod(s->timer[ch], qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) +
                  DMA_PERIPH_BLOCK_NS);
    }
}

static void snom_dma_periph_tick(void *opaque)
{
    SnomDmaTimerArg *a = opaque;
    SnomDmaState *s = a->s;
    int ch = a->ch;
    bool more;

    if (!(s->chen & (1 << ch))) {
        return;
    }
    more = snom_dma_block(s, ch);
    if (more) {
        snom_dma_update(s);
        timer_mod(s->timer[ch], qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) +
                  DMA_PERIPH_BLOCK_NS);
    } else {
        snom_dma_finish(s, ch);
    }
}

static uint64_t snom_dma_read(void *opaque, hwaddr off, unsigned size)
{
    SnomDmaState *s = opaque;
    unsigned t;

    if (off >= DMA_RAW && off < DMA_STATUS) {
        t = (off - DMA_RAW) / 8;
        return off & 4 ? 0 : s->raw[t];
    }
    if (off >= DMA_STATUS && off < DMA_MASK) {
        t = (off - DMA_STATUS) / 8;
        return off & 4 ? 0 : s->raw[t] & s->mask[t];
    }
    if (off >= DMA_MASK && off < DMA_CLEAR) {
        t = (off - DMA_MASK) / 8;
        return off & 4 ? 0 : s->mask[t];
    }
    if (off >= DMA_CLEAR && off < DMA_STATUS_INT) {
        return 0;
    }
    switch (off) {
    case DMA_STATUS_INT: {
        uint32_t v = 0;

        for (t = 0; t < DMA_NUM_INT; t++) {
            v |= (!!(s->raw[t] & s->mask[t])) << t;
        }
        return v;
    }
    case DMA_CFG:
        return s->cfg_en;
    case DMA_CH_EN:
        return s->chen;
    case 0x3f4:
        return DMA_COMP_PARM1_HI;
    }
    return off < sizeof(s->regs) ? DMA_REG(s, off & ~3) : 0;
}

static void snom_dma_write(void *opaque, hwaddr off, uint64_t val,
                           unsigned size)
{
    SnomDmaState *s = opaque;
    unsigned t;
    int ch;

    if (off >= DMA_MASK && off < DMA_CLEAR) {
        if (!(off & 4)) {
            uint8_t we = val >> 8;

            t = (off - DMA_MASK) / 8;
            s->mask[t] = (s->mask[t] & ~we) | (val & we);
            snom_dma_update(s);
        }
        return;
    }
    if (off >= DMA_CLEAR && off < DMA_STATUS_INT) {
        if (!(off & 4)) {
            s->raw[(off - DMA_CLEAR) / 8] &= ~val;
            snom_dma_update(s);
        }
        return;
    }
    switch (off) {
    case DMA_CFG:
        s->cfg_en = val & 1;
        snom_dma_update(s);
        return;
    case DMA_CH_EN: {
        uint8_t we = val >> 8;
        uint8_t next = (s->chen & ~we) | (val & we);
        uint8_t started = next & ~s->chen;

        s->chen = next;
        for (ch = 0; ch < DMA_CHANNELS; ch++) {
            if (started & (1 << ch)) {
                snom_dma_start(s, ch);
            }
        }
        return;
    }
    }
    if (off < sizeof(s->regs)) {
        DMA_REG(s, off & ~3) = val;
    }
}

static const MemoryRegionOps snom_dma_ops = {
    .read = snom_dma_read,
    .write = snom_dma_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid.min_access_size = 4,
    .valid.max_access_size = 4,
};

static void snom_dma_instance_init(Object *obj)
{
    SnomDmaState *s = SNOM_DMA(obj);
    int i;

    memory_region_init_io(&s->mmio, obj, &snom_dma_ops, s, "snom-dma",
                          0x400);
    sysbus_init_mmio(SYS_BUS_DEVICE(obj), &s->mmio);
    for (i = 0; i < DMA_CHANNELS; i++) {
        SnomDmaTimerArg *a = g_new(SnomDmaTimerArg, 1);

        a->s = s;
        a->ch = i;
        sysbus_init_irq(SYS_BUS_DEVICE(obj), &s->irq[i]);
        s->timer[i] = timer_new_ns(QEMU_CLOCK_VIRTUAL, snom_dma_periph_tick,
                                   a);
    }
}

static void snom_dma_realize(DeviceState *dev, Error **errp)
{
    SnomDmaState *s = SNOM_DMA(dev);

    if (s->esw) {
        qemu_macaddr_default_if_unset(&s->conf.macaddr);
        s->nic = qemu_new_nic(&snom_esw_net_info, &s->conf,
                              object_get_typename(OBJECT(dev)), dev->id,
                              &dev->mem_reentrancy_guard, s);
        qemu_format_nic_info_str(qemu_get_queue(s->nic), s->conf.macaddr.a);
    }
}

static const Property snom_dma_props[] = {
    DEFINE_NIC_PROPERTIES(SnomDmaState, conf),
    DEFINE_PROP_BOOL("esw", SnomDmaState, esw, false),
};

static void snom_dma_reset(DeviceState *dev)
{
    SnomDmaState *s = SNOM_DMA(dev);
    int i;

    for (i = 0; i < DMA_CHANNELS; i++) {
        timer_del(s->timer[i]);
        s->cur_desc[i] = 0;
        qemu_set_irq(s->irq[i], 0);
    }
    memset(s->regs, 0, sizeof(s->regs));
    memset(s->raw, 0, sizeof(s->raw));
    memset(s->mask, 0, sizeof(s->mask));
    s->chen = 0;
    s->cfg_en = false;
    s->rx_desc = 0;
}

static void snom_dma_class_init(ObjectClass *oc, const void *data)
{
    DeviceClass *dc = DEVICE_CLASS(oc);

    dc->realize = snom_dma_realize;
    device_class_set_legacy_reset(dc, snom_dma_reset);
    device_class_set_props(dc, snom_dma_props);
}

static const TypeInfo snom_dma_info = {
    .name = TYPE_SNOM_DMA,
    .parent = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(SnomDmaState),
    .instance_init = snom_dma_instance_init,
    .class_init = snom_dma_class_init,
};

/* ---- Random number generator -------------------------------------------- */

#define TYPE_SNOM_RNG "snom-rng"
OBJECT_DECLARE_SIMPLE_TYPE(SnomRngState, SNOM_RNG)

struct SnomRngState {
    SysBusDevice parent_obj;
    MemoryRegion mmio;
    uint32_t regs[0x20];
};

static uint64_t snom_rng_read(void *opaque, hwaddr off, unsigned size)
{
    SnomRngState *s = opaque;
    uint32_t v;

    switch (off) {
    case 0x04:
        return 0xff0fffff;      /* warmed up, FIFO full */
    case 0x08:
        qemu_guest_getrandom_nofail(&v, sizeof(v));
        return v;
    }
    return off < sizeof(s->regs) ? s->regs[off / 4] : 0;
}

static void snom_rng_write(void *opaque, hwaddr off, uint64_t val,
                           unsigned size)
{
    SnomRngState *s = opaque;

    if (off < sizeof(s->regs)) {
        s->regs[off / 4] = val;
    }
}

static const MemoryRegionOps snom_rng_ops = {
    .read = snom_rng_read,
    .write = snom_rng_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid.min_access_size = 4,
    .valid.max_access_size = 4,
};

static void snom_rng_init(Object *obj)
{
    SnomRngState *s = SNOM_RNG(obj);

    memory_region_init_io(&s->mmio, obj, &snom_rng_ops, s, "snom-rng", 0x1000);
    sysbus_init_mmio(SYS_BUS_DEVICE(obj), &s->mmio);
}

static const TypeInfo snom_rng_info = {
    .name = TYPE_SNOM_RNG,
    .parent = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(SnomRngState),
    .instance_init = snom_rng_init,
};

/* ---- LCD controller (PrimeCell-style register layout) ------------------- */

#define TYPE_SNOM_LCD "snom-lcd"
OBJECT_DECLARE_SIMPLE_TYPE(SnomLcdState, SNOM_LCD)

#define LCD_WIDTH       480
#define LCD_HEIGHT      272
#define LCD_UPBASE      0x10

struct SnomLcdState {
    SysBusDevice parent_obj;
    MemoryRegion mmio;
    QemuConsole *con;
    uint32_t regs[0x400];
};

static uint64_t snom_lcd_read(void *opaque, hwaddr off, unsigned size)
{
    SnomLcdState *s = opaque;

    return off < sizeof(s->regs) ? s->regs[off / 4] : 0;
}

static void snom_lcd_write(void *opaque, hwaddr off, uint64_t val,
                           unsigned size)
{
    SnomLcdState *s = opaque;

    if (off < sizeof(s->regs)) {
        s->regs[off / 4] = val;
    }
}

static const MemoryRegionOps snom_lcd_ops = {
    .read = snom_lcd_read,
    .write = snom_lcd_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid.min_access_size = 1,
    .valid.max_access_size = 4,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
};

/* The panel is scanned out as 32-bit BGRX from the address in UPBASE. */
static bool snom_lcd_update(void *opaque)
{
    SnomLcdState *s = opaque;
    DisplaySurface *surf = qemu_console_surface(s->con);
    uint32_t base = s->regs[LCD_UPBASE / 4];

    if (!surf || !base) {
        return true;
    }
    address_space_read(&address_space_memory, base, MEMTXATTRS_UNSPECIFIED,
                       surface_data(surf), LCD_WIDTH * LCD_HEIGHT * 4);
    qemu_console_update_full(s->con);
    return true;
}

static void snom_lcd_invalidate(void *opaque)
{
}

static const GraphicHwOps snom_lcd_gfx_ops = {
    .invalidate = snom_lcd_invalidate,
    .gfx_update = snom_lcd_update,
};

static void snom_lcd_realize(DeviceState *dev, Error **errp)
{
    SnomLcdState *s = SNOM_LCD(dev);

    memory_region_init_io(&s->mmio, OBJECT(dev), &snom_lcd_ops, s, "snom-lcd",
                          sizeof(s->regs));
    sysbus_init_mmio(SYS_BUS_DEVICE(dev), &s->mmio);
    s->con = qemu_graphic_console_create(dev, 0, &snom_lcd_gfx_ops, s);
    qemu_console_resize(s->con, LCD_WIDTH, LCD_HEIGHT);
}

static void snom_lcd_class_init(ObjectClass *oc, const void *data)
{
    DEVICE_CLASS(oc)->realize = snom_lcd_realize;
}

static const TypeInfo snom_lcd_info = {
    .name = TYPE_SNOM_LCD,
    .parent = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(SnomLcdState),
    .class_init = snom_lcd_class_init,
};

/* ---- Keypad matrix ------------------------------------------------------- */

#define TYPE_SNOM_KEYPAD "snom-keypad"
OBJECT_DECLARE_SIMPLE_TYPE(SnomKeypadState, SNOM_KEYPAD)

/*
 * Five 32-bit registers hold the matrix, active low, 9 usable bits per half.
 * A key's Linux code k selects halfword k >> 4 (even = upper half of the
 * register) and bit k & 15. The driver keeps the interrupt off while scanning,
 * so reading the matrix acknowledges it.
 */
#define KEY_REGS        5
#define KEY_IDLE        0x01ff01ff
#define KEY_CTRL        0x1c
#define KEY_CTRL_IE     (1 << 1)

struct SnomKeypadState {
    SysBusDevice parent_obj;
    MemoryRegion mmio;
    qemu_irq irq;
    uint32_t matrix[KEY_REGS];
    uint32_t ctrl, other[2];
    bool pending;
};

/*
 * Host keys to the codes lcsD375 uses, found by pressing each code in the running
 * app. Doom's own names for these codes differ; see docs/qemu.md.
 */
static const struct {
    unsigned host;
    uint8_t code;
} snom_keymap[] = {
    { KEY_UP, 116 },
    { KEY_DOWN, 67 },
    { KEY_ENTER, 102 },         /* OK */
    { KEY_ESC, 115 },           /* cancel */
    { KEY_F1, 19 },             /* Call History */
    { KEY_F2, 33 },             /* Directory */
    { KEY_F3, 65 },             /* Settings */
    { KEY_1, 51 },              /* digits 1-6 confirmed as menu shortcuts */
    { KEY_2, 49 },
    { KEY_3, 48 },
    { KEY_4, 38 },
    { KEY_5, 37 },
    { KEY_6, 36 },
};

static void snom_keypad_update(SnomKeypadState *s)
{
    qemu_set_irq(s->irq, s->pending && (s->ctrl & KEY_CTRL_IE));
}

static void snom_keypad_set(SnomKeypadState *s, unsigned code, bool down)
{
    unsigned half = code >> 4, reg = half >> 1;
    uint32_t bit = 1u << ((code & 15) + (half & 1 ? 0 : 16));

    if (reg >= KEY_REGS) {
        return;
    }
    s->matrix[reg] = down ? s->matrix[reg] & ~bit : s->matrix[reg] | bit;
    s->pending = true;
    snom_keypad_update(s);
}

static void snom_keypad_event(DeviceState *dev, QemuConsole *src,
                              QemuInputEvent *evt)
{
    SnomKeypadState *s = SNOM_KEYPAD(dev);
    unsigned i;

    /* Debug: host key 2 + n presses matrix code n, to explore unmapped keys. */
    if (getenv("SNOM_KEYPROBE")) {
        if (evt->key.key >= 2 && evt->key.key < 2 + 128) {
            snom_keypad_set(s, evt->key.key - 2, evt->key.down);
        }
        return;
    }
    for (i = 0; i < ARRAY_SIZE(snom_keymap); i++) {
        if (snom_keymap[i].host == evt->key.key) {
            snom_keypad_set(s, snom_keymap[i].code, evt->key.down);
        }
    }
}

static const QemuInputHandler snom_keypad_input = {
    .name = "snom keypad",
    .mask = INPUT_EVENT_MASK_KEY,
    .event = snom_keypad_event,
};

static uint64_t snom_keypad_read(void *opaque, hwaddr off, unsigned size)
{
    SnomKeypadState *s = opaque;

    if (off < KEY_REGS * 4) {
        s->pending = false;
        snom_keypad_update(s);
        return s->matrix[off / 4];
    }
    switch (off) {
    case 0x14: return s->other[0];
    case 0x18: return s->other[1];
    case KEY_CTRL: return s->ctrl;
    }
    return 0;
}

static void snom_keypad_write(void *opaque, hwaddr off, uint64_t val,
                              unsigned size)
{
    SnomKeypadState *s = opaque;

    switch (off) {
    case 0x14: s->other[0] = val; break;
    case 0x18: s->other[1] = val; break;
    case KEY_CTRL:
        s->ctrl = val;
        snom_keypad_update(s);
        break;
    }
}

static const MemoryRegionOps snom_keypad_ops = {
    .read = snom_keypad_read,
    .write = snom_keypad_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid.min_access_size = 4,
    .valid.max_access_size = 4,
};

static void snom_keypad_realize(DeviceState *dev, Error **errp)
{
    SnomKeypadState *s = SNOM_KEYPAD(dev);
    int i;

    for (i = 0; i < KEY_REGS; i++) {
        s->matrix[i] = KEY_IDLE;
    }
    memory_region_init_io(&s->mmio, OBJECT(dev), &snom_keypad_ops, s,
                          "snom-keypad", 0x1000);
    sysbus_init_mmio(SYS_BUS_DEVICE(dev), &s->mmio);
    sysbus_init_irq(SYS_BUS_DEVICE(dev), &s->irq);
    qemu_input_handler_register(dev, &snom_keypad_input);
}

static void snom_keypad_reset(DeviceState *dev)
{
    SnomKeypadState *s = SNOM_KEYPAD(dev);
    int i;

    for (i = 0; i < KEY_REGS; i++) {
        s->matrix[i] = KEY_IDLE;
    }
    s->ctrl = s->other[0] = s->other[1] = 0;
    s->pending = false;
    qemu_set_irq(s->irq, 0);
}

static void snom_keypad_class_init(ObjectClass *oc, const void *data)
{
    DEVICE_CLASS(oc)->realize = snom_keypad_realize;
    device_class_set_legacy_reset(DEVICE_CLASS(oc), snom_keypad_reset);
}

static const TypeInfo snom_keypad_info = {
    .name = TYPE_SNOM_KEYPAD,
    .parent = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(SnomKeypadState),
    .class_init = snom_keypad_class_init,
};

/* ---- Board ------------------------------------------------------------- */

static struct arm_boot_info snom_binfo;

static void snom_ram(const char *name, hwaddr base, uint64_t size)
{
    MemoryRegion *mr = g_new(MemoryRegion, 1);

    memory_region_init_ram(mr, NULL, name, size, &error_fatal);
    memory_region_add_subregion(get_system_memory(), base, mr);
}

static void snom_d375_init(MachineState *machine)
{
    MemoryRegion *sysmem = get_system_memory();
    Object *cpuobj = object_new(machine->cpu_type);
    DeviceState *cpu, *orirq, *intc0, *intc1, *sintc, *tmr, *nand;
    DriveInfo *dinfo;
    int d;
    SnomIoStubState *io30, *io80;
    int i;

    /* The kernel runs without a security monitor, so no EL3 is needed. */
    object_property_set_bool(cpuobj, "has_el3", false, &error_fatal);
    qdev_realize(DEVICE(cpuobj), NULL, &error_fatal);
    cpu = DEVICE(cpuobj);

    memory_region_add_subregion(sysmem, 0, machine->ram);
    snom_ram("snom.aram", MM_ARAM, 64 * KiB);
    snom_ram("snom.vram", MM_VRAM, 64 * KiB);

    orirq = qdev_new(TYPE_OR_IRQ);
    qdev_prop_set_uint16(orirq, "num-lines", 3);
    qdev_realize_and_unref(orirq, NULL, &error_fatal);
    qdev_connect_gpio_out(orirq, 0, qdev_get_gpio_in(cpu, ARM_CPU_IRQ));

    intc0 = sysbus_create_varargs("pl190", MM_INTC0,
                                  qdev_get_gpio_in(orirq, 0), NULL);
    intc1 = sysbus_create_varargs("pl190", MM_INTC1,
                                  qdev_get_gpio_in(orirq, 1), NULL);
    sintc = sysbus_create_varargs("pl190", MM_SINTC,
                                  qdev_get_gpio_in(orirq, 2), NULL);
    (void)sintc;

    tmr = sysbus_create_simple(TYPE_SNOM_TIMER, MM_TMR, NULL);
    for (i = 0; i < TMR_CHANNELS; i++) {
        sysbus_connect_irq(SYS_BUS_DEVICE(tmr), i,
                           qdev_get_gpio_in(intc0, INTC0_TIMER0 + i));
    }

    for (d = 0; d < 2; d++) {
        DeviceState *dma = qdev_new(TYPE_SNOM_DMA);

        if (d) {
            qdev_prop_set_bit(dma, "esw", true);
            qemu_configure_nic_device(dma, true, NULL);
        }
        sysbus_realize_and_unref(SYS_BUS_DEVICE(dma), &error_fatal);
        sysbus_mmio_map(SYS_BUS_DEVICE(dma), 0, d ? MM_DMA1 : MM_DMA0);
        for (i = 0; i < DMA_CHANNELS; i++) {
            sysbus_connect_irq(SYS_BUS_DEVICE(dma), i,
                               qdev_get_gpio_in(intc0, d * 8 + i));
        }
    }

    nand = qdev_new(TYPE_SNOM_NAND);
    dinfo = drive_get(IF_MTD, 0, 0);
    if (dinfo) {
        qdev_prop_set_drive_err(nand, "drive", blk_by_legacy_dinfo(dinfo),
                                &error_fatal);
    }
    sysbus_realize_and_unref(SYS_BUS_DEVICE(nand), &error_fatal);
    sysbus_mmio_map(SYS_BUS_DEVICE(nand), 0, MM_NAND);

    sysbus_create_simple(TYPE_SNOM_LCD, MM_CLCD, NULL);
    sysbus_create_simple(TYPE_SNOM_KEYPAD, MM_KEYC,
                         qdev_get_gpio_in(intc1, INTC1_KEYC));

    pl011_create(MM_UARTA, qdev_get_gpio_in(intc1, INTC1_UARTA),
                 serial_hd(0));
    pl011_create(MM_UARTB, qdev_get_gpio_in(intc1, INTC1_UARTB),
                 serial_hd(1));

    snom_map_stub("flash", MM_FLASHC, 256 * MiB);
    io30 = snom_map_stub("io30", MM_BROM, 256 * MiB);
    io80 = snom_map_stub("io80", MM_CHIPC, 16 * MiB);

    snom_stub_fixed(io30, MM_ESW_CTL, 0x00800000);  /* switch out of reset */
    snom_stub_fixed(io80, MM_UMI + 0x1c, 0x3);      /* NAND ready, CS active */
    snom_stub_fixed(io80, MM_UMI + 0x4c, 0x30000);  /* BCH: ECC valid, clean */
    /*
     * Hamming ECC. Reading all-ones matches the erased OOB of a fresh image,
     * and anything the kernel programs stores FF too, so every page verifies.
     */
    snom_stub_fixed(io80, MM_UMI + 0x24, 0x00ffffff);
    snom_stub_autoclear(io80, MM_SPUMP, 0x2);       /* SPU soft reset */
    snom_stub_autoclear(io80, MM_CHIPC + CHIPC_SOFT_RESET1, 0x1);
    snom_stub_reset_on(io80, MM_CHIPC + CHIPC_SOFT_RESET1, 0x1, 0x1);
    snom_stub_fixed(io80, MM_CHIPC + 0x60, 0x80000001); /* PLL1 locked */
    snom_stub_fixed(io80, MM_CHIPC + 0xa0, 0x80000001); /* PLL2 locked */
    /* 25 MHz crystal: PLL1 VCO 2 GHz (N=80), PLL2 VCO 1.8 GHz (N=72). */
    snom_stub_preset(io80, MM_CHIPC + 0x68, (80 << 8) | (1 << 4) | 1);
    snom_stub_preset(io80, MM_CHIPC + 0xa8, (72 << 8) | (1 << 4) | 1);
    /* Channel post-dividers: DDR 333 MHz, ARM 500 MHz, the rest 100 MHz. */
    snom_stub_preset(io80, MM_CHIPC + 0x04, 6);
    snom_stub_preset(io80, MM_CHIPC + 0x08, 4);
    for (i = 0x0c; i <= 0x28; i += 4) {
        snom_stub_preset(io80, MM_CHIPC + i, 20);
    }
    for (i = 0x4c; i <= 0x54; i += 4) {
        snom_stub_preset(io80, MM_CHIPC + i, 18);
    }
    /*
     * DDR phase: aligned, at the target value of 0xf. VPM phase stays at 0 so
     * the voice DSP load fails at once instead of waiting for a DSP that is
     * not there.
     */
    snom_stub_fixed(io80, MM_CHIPC + 0xc0, 0x0f800080);
    snom_stub_fixed(io80, MM_USB_PHY + 0x0c, 0x01000000); /* PHY PLL locked */
    sysbus_create_simple(TYPE_SNOM_RNG, MM_RNG, NULL);

    /* snom's kernel is linked with PHYS_OFFSET 2 MB above the start of DDR. */
    snom_binfo.loader_start = SNOM_PHYS_OFFSET;
    snom_binfo.ram_size = machine->ram_size - SNOM_PHYS_OFFSET;
    snom_binfo.board_id = SNOM_BOARD_ID;
    arm_load_kernel(ARM_CPU(cpu), machine, &snom_binfo);
}

static void snom_d375_class_init(ObjectClass *oc, const void *data)
{
    MachineClass *mc = MACHINE_CLASS(oc);

    mc->desc = "snom D375 desk phone (Broadcom BCM11107, ARM1176)";
    mc->init = snom_d375_init;
    mc->ignore_memory_transaction_failures = true;
    mc->default_cpu_type = ARM_CPU_TYPE_NAME("arm1176");
    mc->default_ram_id = "snom.ram";
    mc->default_ram_size = 256 * MiB;
}

static const TypeInfo snom_d375_type = {
    .name = MACHINE_TYPE_NAME("snom-d375"),
    .parent = TYPE_MACHINE,
    .class_init = snom_d375_class_init,
    .interfaces = arm_machine_interfaces,
};

static void snom_d375_register_types(void)
{
    type_register_static(&snom_timer_info);
    type_register_static(&snom_iostub_info);
    type_register_static(&snom_nand_info);
    type_register_static(&snom_dma_info);
    type_register_static(&snom_rng_info);
    type_register_static(&snom_lcd_info);
    type_register_static(&snom_keypad_info);
    type_register_static(&snom_d375_type);
}

type_init(snom_d375_register_types)
