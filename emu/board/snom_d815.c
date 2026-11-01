/*
 * snom D815 desk phone: DSP Group DVF99, ARM926EJ-S, 512 MB DDR at 0x40000000.
 *
 * Boots the unmodified kernel out of a snom .swu image with the device tree
 * shipped next to it. Addresses come from that tree; see docs/qemu.md.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include "qemu/osdep.h"
#include "qapi/error.h"
#include "qemu/units.h"
#include "qemu/timer.h"
#include "net/net.h"
#include "ui/console.h"
#include "ui/input.h"
#include "standard-headers/linux/input-event-codes.h"
#include "qemu/error-report.h"
#include "qemu/host-utils.h"
#include "hw/core/boards.h"
#include "hw/core/irq.h"
#include "hw/core/sysbus.h"
#include "hw/core/qdev-properties.h"
#include "hw/core/qdev-properties-system.h"
#include "chardev/char-fe.h"
#include "qom/object.h"
#include "hw/arm/boot.h"
#include "hw/arm/machines-qom.h"
#include "system/address-spaces.h"
#include "system/block-backend.h"
#include "system/blockdev.h"
#include "system/memory.h"
#include "system/system.h"
#include "target/arm/cpu-qom.h"
#include "snom_common.h"

#define D815_RAM_BASE   0x40000000
#define D815_IO_BASE    0x00000000
#define D815_IO_SIZE    (256 * MiB)
#define D815_CCU        0x05300000
#define D815_PLICU_BASE 0x05100000
#define D815_KEYPAD_BASE 0x050002b0
#define D815_IRQ_KEYPAD 4
#define D815_LCD_BASE   0x06b00000
#define D815_GMAC       0x06e00000
#define D815_IRQ_GMAC   23
#define D815_NFC_BASE   0x05400000
#define D815_IRQ_NFC    22
#define D815_RTC_BASE   0x05600000
#define D815_TMR        0x05800000
#define D815_TMR_HZ     16666666
#define D815_IRQ_TMR    50
#define D815_UART0      0x05a00000
#define D815_UART1      0x05b00000
#define D815_IRQ_UART0  55
#define D815_IRQ_UART1  54

/* ---- PLICU interrupt controller ------------------------------------------ */

#define TYPE_D815_PLICU "d815-plicu"
OBJECT_DECLARE_SIMPLE_TYPE(D815PlicuState, D815_PLICU)

#define PLICU_LINES     64
#define PLICU_ACK       0x00    /* + 4 for lines 32-63 */
#define PLICU_PEND      0x2c
#define PLICU_EN_SET    0x3c
#define PLICU_EN_CLR    0x44

struct D815PlicuState {
    SysBusDevice parent_obj;
    MemoryRegion mmio;
    qemu_irq out;
    uint64_t level, latch, enable;
    uint32_t regs[0x40];
};

static void d815_plicu_update(D815PlicuState *s)
{
    qemu_set_irq(s->out, !!((s->level | s->latch) & s->enable));
}

static void d815_plicu_set(void *opaque, int n, int level)
{
    D815PlicuState *s = opaque;
    uint64_t bit = 1ULL << n;

    if (level) {
        s->level |= bit;
        s->latch |= bit;
    } else {
        s->level &= ~bit;
    }
    d815_plicu_update(s);
}

static uint64_t d815_plicu_read(void *opaque, hwaddr off, unsigned size)
{
    D815PlicuState *s = opaque;
    uint64_t p = (s->level | s->latch) & s->enable;

    switch (off) {
    case PLICU_PEND:
        return (uint32_t)p;
    case PLICU_PEND + 4:
        return p >> 32;
    case PLICU_EN_SET:
        return (uint32_t)s->enable;
    case PLICU_EN_SET + 4:
        return s->enable >> 32;
    }
    return off < sizeof(s->regs) ? s->regs[off / 4] : 0;
}

static void d815_plicu_write(void *opaque, hwaddr off, uint64_t val,
                             unsigned size)
{
    D815PlicuState *s = opaque;

    switch (off) {
    case PLICU_ACK:
        s->latch &= ~val;
        break;
    case PLICU_ACK + 4:
        s->latch &= ~(val << 32);
        break;
    case PLICU_EN_SET:
        s->enable |= val;
        break;
    case PLICU_EN_SET + 4:
        s->enable |= val << 32;
        break;
    case PLICU_EN_CLR:
        s->enable &= ~val;
        break;
    case PLICU_EN_CLR + 4:
        s->enable &= ~(val << 32);
        break;
    default:
        if (off < sizeof(s->regs)) {
            s->regs[off / 4] = val;
        }
    }
    d815_plicu_update(s);
}

static const MemoryRegionOps d815_plicu_ops = {
    .read = d815_plicu_read,
    .write = d815_plicu_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid.min_access_size = 4,
    .valid.max_access_size = 4,
};

static void d815_plicu_init(Object *obj)
{
    D815PlicuState *s = D815_PLICU(obj);

    memory_region_init_io(&s->mmio, obj, &d815_plicu_ops, s, "d815-plicu",
                          0x100);
    sysbus_init_mmio(SYS_BUS_DEVICE(obj), &s->mmio);
    sysbus_init_irq(SYS_BUS_DEVICE(obj), &s->out);
    qdev_init_gpio_in(DEVICE(obj), d815_plicu_set, PLICU_LINES);
}

static void d815_plicu_reset(DeviceState *dev)
{
    D815PlicuState *s = D815_PLICU(dev);

    s->latch = s->enable = 0;
    memset(s->regs, 0, sizeof(s->regs));
    d815_plicu_update(s);
}

static void d815_plicu_class_init(ObjectClass *oc, const void *data)
{
    device_class_set_legacy_reset(DEVICE_CLASS(oc), d815_plicu_reset);
}

static const TypeInfo d815_plicu_info = {
    .name = TYPE_D815_PLICU,
    .parent = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(D815PlicuState),
    .instance_init = d815_plicu_init,
    .class_init = d815_plicu_class_init,
};

/* ---- UART ---------------------------------------------------------------- */

#define TYPE_D815_UART "d815-uart"
OBJECT_DECLARE_SIMPLE_TYPE(D815UartState, D815_UART)

#define UART_TX         0x2c
#define UART_STATUS     0x34
#define UART_ST_EMPTY   (1 << 0)
#define UART_ST_RXEMPTY (1 << 8)
#define UART_RX         0x30
#define UART_INT_STAT   0x18
#define UART_INT_EN     0x1c
#define UART_INT_CLR    0x20
#define UART_INT_RX     (1 << 9)
#define UART_INT_TX     (3 << 0)
#define UART_FIFO       64

struct D815UartState {
    SysBusDevice parent_obj;
    MemoryRegion mmio;
    CharFrontend chr;
    qemu_irq irq;
    uint16_t regs[0x100];
    uint8_t rx[UART_FIFO];
    unsigned rx_head, rx_count;
};

static void d815_uart_update(D815UartState *s)
{
    uint16_t stat = UART_INT_TX | (s->rx_count ? UART_INT_RX : 0);

    s->regs[UART_INT_STAT / 2] = stat;
    qemu_set_irq(s->irq, !!(stat & s->regs[UART_INT_EN / 2]));
}

static int d815_uart_can_receive(void *opaque)
{
    D815UartState *s = opaque;

    return UART_FIFO - s->rx_count;
}

static void d815_uart_receive(void *opaque, const uint8_t *buf, int size)
{
    D815UartState *s = opaque;
    int i;

    for (i = 0; i < size && s->rx_count < UART_FIFO; i++) {
        s->rx[(s->rx_head + s->rx_count++) % UART_FIFO] = buf[i];
    }
    d815_uart_update(s);
}

static uint64_t d815_uart_read(void *opaque, hwaddr off, unsigned size)
{
    D815UartState *s = opaque;

    if (off == UART_STATUS) {
        return UART_ST_EMPTY | (s->rx_count ? 0 : UART_ST_RXEMPTY);
    }
    if (off == UART_RX) {
        uint8_t c = 0;

        if (s->rx_count) {
            c = s->rx[s->rx_head];
            s->rx_head = (s->rx_head + 1) % UART_FIFO;
            s->rx_count--;
            d815_uart_update(s);
            qemu_chr_fe_accept_input(&s->chr);
        }
        return c;
    }
    return off < sizeof(s->regs) ? s->regs[off / 2] : 0;
}

static void d815_uart_write(void *opaque, hwaddr off, uint64_t val,
                            unsigned size)
{
    D815UartState *s = opaque;
    uint8_t c = val;

    if (off == UART_TX) {
        qemu_chr_fe_write_all(&s->chr, &c, 1);
    } else if (off < sizeof(s->regs)) {
        s->regs[off / 2] = val;
        d815_uart_update(s);
    }
}

static const MemoryRegionOps d815_uart_ops = {
    .read = d815_uart_read,
    .write = d815_uart_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid.min_access_size = 1,
    .valid.max_access_size = 4,
    .impl.min_access_size = 2,
    .impl.max_access_size = 2,
};

static void d815_uart_realize(DeviceState *dev, Error **errp)
{
    D815UartState *s = D815_UART(dev);

    memory_region_init_io(&s->mmio, OBJECT(dev), &d815_uart_ops, s,
                          "d815-uart", 0x200);
    sysbus_init_mmio(SYS_BUS_DEVICE(dev), &s->mmio);
    sysbus_init_irq(SYS_BUS_DEVICE(dev), &s->irq);
    qemu_chr_fe_set_handlers(&s->chr, d815_uart_can_receive, d815_uart_receive,
                             NULL, NULL, s, NULL, true);
}

static const Property d815_uart_props[] = {
    DEFINE_PROP_CHR("chardev", D815UartState, chr),
};

static void d815_uart_reset(DeviceState *dev)
{
    D815UartState *s = D815_UART(dev);

    memset(s->regs, 0, sizeof(s->regs));
    s->rx_head = s->rx_count = 0;
    qemu_set_irq(s->irq, 0);
}

static void d815_uart_class_init(ObjectClass *oc, const void *data)
{
    DeviceClass *dc = DEVICE_CLASS(oc);

    dc->realize = d815_uart_realize;
    device_class_set_legacy_reset(dc, d815_uart_reset);
    device_class_set_props(dc, d815_uart_props);
}

static const TypeInfo d815_uart_info = {
    .name = TYPE_D815_UART,
    .parent = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(D815UartState),
    .class_init = d815_uart_class_init,
};

static void d815_uart_create(hwaddr base, qemu_irq irq, Chardev *chr)
{
    DeviceState *d = qdev_new(TYPE_D815_UART);

    qdev_prop_set_chr(d, "chardev", chr);
    sysbus_realize_and_unref(SYS_BUS_DEVICE(d), &error_fatal);
    sysbus_mmio_map(SYS_BUS_DEVICE(d), 0, base);
    sysbus_connect_irq(SYS_BUS_DEVICE(d), 0, irq);
}

/* ---- RTC, which is also the sched_clock source ---------------------------- */

#define TYPE_D815_RTC "d815-rtc"
OBJECT_DECLARE_SIMPLE_TYPE(D815RtcState, D815_RTC)

#define RTC_COUNT       0x14
#define RTC_STEP        1024
#define RTC_HZ          50000000    /* what the clock tree reports */

struct D815RtcState {
    SysBusDevice parent_obj;
    MemoryRegion mmio;
    uint32_t regs[0x40];
};

static uint64_t d815_rtc_read(void *opaque, hwaddr off, unsigned size)
{
    D815RtcState *s = opaque;

    if (off == RTC_COUNT) {
        /*
         * The driver reads until two reads agree, so the counter must hold
         * still between reads: it advances in steps of about 20 us.
         */
        return muldiv64(qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL), RTC_HZ,
                        NANOSECONDS_PER_SECOND) & ~(RTC_STEP - 1);
    }
    return off < sizeof(s->regs) ? s->regs[off / 4] : 0;
}

static void d815_rtc_write(void *opaque, hwaddr off, uint64_t val,
                           unsigned size)
{
    D815RtcState *s = opaque;

    if (off < sizeof(s->regs)) {
        s->regs[off / 4] = val;
    }
}

static const MemoryRegionOps d815_rtc_ops = {
    .read = d815_rtc_read,
    .write = d815_rtc_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid.min_access_size = 4,
    .valid.max_access_size = 4,
};

static void d815_rtc_init(Object *obj)
{
    D815RtcState *s = D815_RTC(obj);

    memory_region_init_io(&s->mmio, obj, &d815_rtc_ops, s, "d815-rtc", 0x100);
    sysbus_init_mmio(SYS_BUS_DEVICE(obj), &s->mmio);
}

static const TypeInfo d815_rtc_info = {
    .name = TYPE_D815_RTC,
    .parent = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(D815RtcState),
    .instance_init = d815_rtc_init,
};

/* ---- NAND flash controller ------------------------------------------------ */

#define TYPE_D815_NFC "d815-nfc"
OBJECT_DECLARE_SIMPLE_TYPE(D815NfcState, D815_NFC)

/*
 * A sequencer: the driver loads commands and addresses, writes START, and the
 * block runs the whole transaction, moving data by DMA to a buffer it was
 * given. Everything therefore happens at START here.
 */
#define NFC_INT_CLR     0x08
#define NFC_INT_STAT    0x10
#define NFC_CFG         0x14
#define NFC_COL         0x18
#define NFC_ROW         0x1c
#define NFC_CMD         0x20
#define NFC_COUNT_OOB   0x3c
#define NFC_COUNT       0x40
#define NFC_DMA_MAIN    0x44
#define NFC_DMA_OOB     0x48
#define NFC_START       0x58
#define NFC_STATUS      0x60

#define NFC_CFG_DATA    (1 << 10)
#define NFC_CFG_INT2    (1 << 12)
#define NFC_INT_DONE    (1 << 0)
#define NFC_INT_XFER2   (1 << 1)
#define NFC_INT_DATA    (1 << 17)

#define NFC_PAGE        2048
#define NFC_OOB         64
#define NFC_RAW         (NFC_PAGE + NFC_OOB)
#define NFC_PAGES       131072
#define NFC_PPB         64
#define NFC_BYTES       ((uint64_t)NFC_PAGES * NFC_RAW)

/* 256 MiB, 2 KiB pages, 128 KiB blocks, 8 bit. */
static const uint8_t d815_nand_id[5] = { 0x2c, 0xda, 0x90, 0x95, 0x06 };

struct D815NfcState {
    SysBusDevice parent_obj;
    MemoryRegion mmio;
    BlockBackend *blk;
    qemu_irq irq;
    uint8_t *store;
    uint32_t regs[0x40];
    uint32_t stat;
};

#define NFC_REG(s, r) ((s)->regs[(r) / 4])

static void d815_nfc_flush(D815NfcState *s, uint64_t off, uint64_t len)
{
    if (s->blk && blk_pwrite(s->blk, off, len, s->store + off, 0) < 0) {
        error_report("d815-nfc: write to backing file failed");
    }
}

static void d815_nfc_dma_out(hwaddr addr, const void *buf, size_t len)
{
    address_space_write(&address_space_memory, addr, MEMTXATTRS_UNSPECIFIED,
                        buf, len);
}

static bool buffer_is_all_ff(const uint8_t *p, size_t len)
{
    return p[0] == 0xff && !memcmp(p, p + 1, len - 1);
}

static void d815_nfc_run(D815NfcState *s)
{
    uint32_t cfg = NFC_REG(s, NFC_CFG);
    uint8_t cmd = NFC_REG(s, NFC_CMD);
    unsigned col = NFC_REG(s, NFC_COL) & 0xffff;
    uint32_t row = (NFC_REG(s, NFC_ROW) & 0xffffff) % NFC_PAGES;
    size_t len = NFC_REG(s, NFC_COUNT) & 0x1fff;
    size_t oob = 0;
    hwaddr dma = NFC_REG(s, NFC_DMA_MAIN), dma2 = NFC_REG(s, NFC_DMA_OOB);
    uint64_t off = (uint64_t)row * NFC_RAW;
    uint8_t status = 0xc0;
    g_autofree uint8_t *zero = NULL;
    size_t i;

    /*
     * With hardware ECC the count registers hold a sector size, the sector
     * count minus one in the top nibble, and per-sector spare bytes.
     */
    if (NFC_REG(s, NFC_COUNT_OOB) >> 28) {
        len = (NFC_REG(s, NFC_COUNT_OOB) & 0x1fff) *
              ((NFC_REG(s, NFC_COUNT_OOB) >> 28) + 1);
        oob = NFC_OOB;
    }

    switch (cmd) {
    case 0x90:                  /* read ID */
        for (i = 0; i < len; i++) {
            d815_nfc_dma_out(dma + i, &d815_nand_id[i % sizeof(d815_nand_id)],
                             1);
        }
        break;
    case 0xec:                  /* ONFI parameters: chip has none */
        zero = g_malloc0(MAX(len, 1));
        d815_nfc_dma_out(dma, zero, len);
        break;
    case 0x70:
        d815_nfc_dma_out(dma, &status, 1);
        break;
    case 0x00:
    case 0x50:
        if (col < NFC_RAW) {
            d815_nfc_dma_out(dma, s->store + off + col,
                             MIN(len, NFC_RAW - col));
        }
        if (oob) {
            uint8_t spare[NFC_OOB];

            /*
             * The driver treats a page whose spare marker is not zero as
             * erased and counts its zero bits as errors. Hardware writes that
             * marker; here any page holding data reads back as marked. Byte 0
             * is the bad-block marker and keeps its stored value.
             */
            memcpy(spare, s->store + off + NFC_PAGE, sizeof(spare));
            if (!buffer_is_all_ff(s->store + off, NFC_PAGE)) {
                memset(spare + 1, 0, sizeof(spare) - 1);
            }
            d815_nfc_dma_out(dma2, spare, MIN(oob, NFC_OOB));
        }
        break;
    case 0x80: {
        uint8_t page[NFC_RAW];

        memset(page, 0xff, sizeof(page));
        if (col < NFC_RAW) {
            address_space_read(&address_space_memory, dma,
                               MEMTXATTRS_UNSPECIFIED, page + col,
                               MIN(len, NFC_RAW - col));
        }
        if (oob) {
            address_space_read(&address_space_memory, dma2,
                               MEMTXATTRS_UNSPECIFIED, page + NFC_PAGE,
                               MIN(oob, NFC_OOB));
        }
        for (i = 0; i < NFC_RAW; i++) {
            s->store[off + i] &= page[i];
        }
        d815_nfc_flush(s, off, NFC_RAW);
        break;
    }
    case 0x60:
        off = (uint64_t)(row & ~(NFC_PPB - 1)) * NFC_RAW;
        memset(s->store + off, 0xff, NFC_PPB * NFC_RAW);
        d815_nfc_flush(s, off, NFC_PPB * NFC_RAW);
        break;
    }

    NFC_REG(s, NFC_STATUS) = status;
    s->stat |= NFC_INT_DONE;
    if (cfg & NFC_CFG_DATA) {
        s->stat |= NFC_INT_DATA;
    }
    if (cfg & NFC_CFG_INT2) {
        s->stat |= NFC_INT_XFER2;
    }
    qemu_set_irq(s->irq, !!s->stat);
}

static uint64_t d815_nfc_read(void *opaque, hwaddr off, unsigned size)
{
    D815NfcState *s = opaque;

    if (off == NFC_INT_STAT) {
        return s->stat;
    }
    return off < sizeof(s->regs) ? s->regs[off / 4] : 0;
}

static void d815_nfc_write(void *opaque, hwaddr off, uint64_t val,
                           unsigned size)
{
    D815NfcState *s = opaque;

    if (off == NFC_INT_CLR) {
        s->stat &= ~val;
        qemu_set_irq(s->irq, !!s->stat);
    } else if (off == NFC_START) {
        d815_nfc_run(s);
    } else if (off < sizeof(s->regs)) {
        s->regs[off / 4] = val;
    }
}

static const MemoryRegionOps d815_nfc_ops = {
    .read = d815_nfc_read,
    .write = d815_nfc_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid.min_access_size = 4,
    .valid.max_access_size = 4,
};

static void d815_nfc_realize(DeviceState *dev, Error **errp)
{
    D815NfcState *s = D815_NFC(dev);

    s->store = g_malloc(NFC_BYTES);
    memset(s->store, 0xff, NFC_BYTES);
    if (s->blk) {
        if (blk_set_perm(s->blk, BLK_PERM_CONSISTENT_READ | BLK_PERM_WRITE,
                         BLK_PERM_ALL, errp) < 0) {
            return;
        }
        if (blk_getlength(s->blk) != NFC_BYTES) {
            error_setg(errp, "NAND image must be %" PRIu64 " bytes", NFC_BYTES);
            return;
        }
        if (blk_pread(s->blk, 0, NFC_BYTES, s->store, 0) < 0) {
            error_setg(errp, "cannot read NAND image");
            return;
        }
    }
    memory_region_init_io(&s->mmio, OBJECT(dev), &d815_nfc_ops, s, "d815-nfc",
                          0x200);
    sysbus_init_mmio(SYS_BUS_DEVICE(dev), &s->mmio);
    sysbus_init_irq(SYS_BUS_DEVICE(dev), &s->irq);
}

static const Property d815_nfc_props[] = {
    DEFINE_PROP_DRIVE("drive", D815NfcState, blk),
};

static void d815_nfc_reset(DeviceState *dev)
{
    D815NfcState *s = D815_NFC(dev);

    memset(s->regs, 0, sizeof(s->regs));
    s->stat = 0;
    qemu_set_irq(s->irq, 0);
}

static void d815_nfc_class_init(ObjectClass *oc, const void *data)
{
    DeviceClass *dc = DEVICE_CLASS(oc);

    dc->realize = d815_nfc_realize;
    device_class_set_legacy_reset(dc, d815_nfc_reset);
    device_class_set_props(dc, d815_nfc_props);
}

static const TypeInfo d815_nfc_info = {
    .name = TYPE_D815_NFC,
    .parent = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(D815NfcState),
    .class_init = d815_nfc_class_init,
};

/* ---- LCD controller ------------------------------------------------------- */

#define TYPE_D815_LCD "d815-lcd"
OBJECT_DECLARE_SIMPLE_TYPE(D815LcdState, D815_LCD)

#define LCD_WIDTH       480
#define LCD_HEIGHT      272
#define LCD_BASE_HI     0xa0
#define LCD_BASE_LO     0xa4
#define LCD_STRIDE      0xa8

struct D815LcdState {
    SysBusDevice parent_obj;
    MemoryRegion mmio;
    QemuConsole *con;
    uint32_t regs[0x800];
};

static uint64_t d815_lcd_read(void *opaque, hwaddr off, unsigned size)
{
    D815LcdState *s = opaque;

    return off < sizeof(s->regs) ? s->regs[off / 4] : 0;
}

static void d815_lcd_write(void *opaque, hwaddr off, uint64_t val,
                           unsigned size)
{
    D815LcdState *s = opaque;

    if (off < sizeof(s->regs)) {
        s->regs[off / 4] = val;
    }
}

static const MemoryRegionOps d815_lcd_ops = {
    .read = d815_lcd_read,
    .write = d815_lcd_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid.min_access_size = 4,
    .valid.max_access_size = 4,
};

/* Scanout is 24-bit RGB; the two address registers hold 16 bits each. */
static bool d815_lcd_update(void *opaque)
{
    D815LcdState *s = opaque;
    DisplaySurface *surf = qemu_console_surface(s->con);
    hwaddr base = (s->regs[LCD_BASE_HI / 4] << 16) | s->regs[LCD_BASE_LO / 4];
    uint32_t stride = s->regs[LCD_STRIDE / 4];
    uint8_t line[LCD_WIDTH * 3];
    uint32_t *dst;
    int x, y;

    if (!surf || !base || stride < sizeof(line)) {
        return true;
    }
    for (y = 0; y < LCD_HEIGHT; y++) {
        address_space_read(&address_space_memory, base + y * stride,
                           MEMTXATTRS_UNSPECIFIED, line, sizeof(line));
        dst = (uint32_t *)((uint8_t *)surface_data(surf) +
                           y * surface_stride(surf));
        for (x = 0; x < LCD_WIDTH; x++) {
            dst[x] = line[x * 3 + 2] | (line[x * 3 + 1] << 8) |
                     (line[x * 3] << 16);
        }
    }
    qemu_console_update_full(s->con);
    return true;
}

static void d815_lcd_invalidate(void *opaque)
{
}

static const GraphicHwOps d815_lcd_gfx_ops = {
    .invalidate = d815_lcd_invalidate,
    .gfx_update = d815_lcd_update,
};

static void d815_lcd_realize(DeviceState *dev, Error **errp)
{
    D815LcdState *s = D815_LCD(dev);

    memory_region_init_io(&s->mmio, OBJECT(dev), &d815_lcd_ops, s, "d815-lcd",
                          sizeof(s->regs));
    sysbus_init_mmio(SYS_BUS_DEVICE(dev), &s->mmio);
    s->con = qemu_graphic_console_create(dev, 0, &d815_lcd_gfx_ops, s);
    qemu_console_resize(s->con, LCD_WIDTH, LCD_HEIGHT);
}

static void d815_lcd_class_init(ObjectClass *oc, const void *data)
{
    DEVICE_CLASS(oc)->realize = d815_lcd_realize;
}

static const TypeInfo d815_lcd_info = {
    .name = TYPE_D815_LCD,
    .parent = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(D815LcdState),
    .class_init = d815_lcd_class_init,
};

/* ---- Keypad matrix -------------------------------------------------------- */

#define TYPE_D815_KEYPAD "d815-keypad"
OBJECT_DECLARE_SIMPLE_TYPE(D815KeypadState, D815_KEYPAD)

/*
 * The driver drives columns through KP_DRIVE and reads rows from KP_SENSE, one
 * column at a time, and leaves all columns driven while idle. A pressed key
 * joins its row to its column, and the interrupt follows the sense lines.
 * Device tree keymap entries are (row << 24) | (col << 16) | Linux code.
 */
#define KP_SENSE        0x04
#define KP_DRIVE        0x08
#define KP_ROWS         7
#define KP_COLS         8

struct D815KeypadState {
    SysBusDevice parent_obj;
    MemoryRegion mmio;
    qemu_irq irq;
    uint32_t drive, other;
    uint8_t pressed[KP_COLS];   /* row bits per column */
};

/* Host keys to matrix positions, found by pressing each one in lcsD815. */
static const struct {
    unsigned host;
    uint8_t row, col;
} d815_keymap[] = {
    { KEY_UP, 4, 7 },
    { KEY_DOWN, 3, 4 },
    { KEY_ENTER, 4, 4 },        /* OK */
    { KEY_ESC, 1, 6 },          /* back */
    { KEY_F1, 5, 4 },           /* Call History */
    { KEY_F2, 1, 2 },           /* Directory */
    { KEY_F3, 3, 6 },           /* function key panel */
};

static uint32_t d815_keypad_sense(D815KeypadState *s)
{
    uint32_t v = 0;
    int c;

    for (c = 0; c < KP_COLS; c++) {
        if (s->drive & (1u << c)) {
            v |= s->pressed[c];
        }
    }
    return v;
}

static void d815_keypad_update(D815KeypadState *s)
{
    qemu_set_irq(s->irq, !!d815_keypad_sense(s));
}

static void d815_keypad_event(DeviceState *dev, QemuConsole *src,
                              QemuInputEvent *evt)
{
    D815KeypadState *s = D815_KEYPAD(dev);
    unsigned i;

    /* Debug: host key 2 + n presses position n (column n / 7, row n % 7). */
    if (getenv("SNOM_KEYPROBE")) {
        unsigned n = evt->key.key - 2;

        if (evt->key.key >= 2 && n < KP_ROWS * KP_COLS) {
            uint8_t bit = 1 << (n % KP_ROWS);

            if (evt->key.down) {
                s->pressed[n / KP_ROWS] |= bit;
            } else {
                s->pressed[n / KP_ROWS] &= ~bit;
            }
            d815_keypad_update(s);
        }
        return;
    }
    for (i = 0; i < ARRAY_SIZE(d815_keymap); i++) {
        if (d815_keymap[i].host == evt->key.key) {
            uint8_t bit = 1 << d815_keymap[i].row;

            if (evt->key.down) {
                s->pressed[d815_keymap[i].col] |= bit;
            } else {
                s->pressed[d815_keymap[i].col] &= ~bit;
            }
            d815_keypad_update(s);
        }
    }
}

static const QemuInputHandler d815_keypad_input = {
    .name = "d815 keypad",
    .mask = INPUT_EVENT_MASK_KEY,
    .event = d815_keypad_event,
};

static uint64_t d815_keypad_read(void *opaque, hwaddr off, unsigned size)
{
    D815KeypadState *s = opaque;

    switch (off) {
    case KP_SENSE:
        return d815_keypad_sense(s);
    case KP_DRIVE:
        return s->drive;
    }
    return s->other;
}

static void d815_keypad_write(void *opaque, hwaddr off, uint64_t val,
                              unsigned size)
{
    D815KeypadState *s = opaque;

    if (off == KP_DRIVE) {
        s->drive = val;
        d815_keypad_update(s);
    } else {
        s->other = val;
    }
}

static const MemoryRegionOps d815_keypad_ops = {
    .read = d815_keypad_read,
    .write = d815_keypad_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid.min_access_size = 4,
    .valid.max_access_size = 4,
};

static void d815_keypad_realize(DeviceState *dev, Error **errp)
{
    D815KeypadState *s = D815_KEYPAD(dev);

    memory_region_init_io(&s->mmio, OBJECT(dev), &d815_keypad_ops, s,
                          "d815-keypad", 0xc);
    sysbus_init_mmio(SYS_BUS_DEVICE(dev), &s->mmio);
    sysbus_init_irq(SYS_BUS_DEVICE(dev), &s->irq);
    qemu_input_handler_register(dev, &d815_keypad_input);
}

static void d815_keypad_reset(DeviceState *dev)
{
    D815KeypadState *s = D815_KEYPAD(dev);

    memset(s->pressed, 0, sizeof(s->pressed));
    s->drive = s->other = 0;
    qemu_set_irq(s->irq, 0);
}

static void d815_keypad_class_init(ObjectClass *oc, const void *data)
{
    DEVICE_CLASS(oc)->realize = d815_keypad_realize;
    device_class_set_legacy_reset(DEVICE_CLASS(oc), d815_keypad_reset);
}

static const TypeInfo d815_keypad_info = {
    .name = TYPE_D815_KEYPAD,
    .parent = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(D815KeypadState),
    .class_init = d815_keypad_class_init,
};

/* ---- Board --------------------------------------------------------------- */

static struct arm_boot_info d815_binfo;

static void snom_d815_init(MachineState *machine)
{
    Object *cpuobj = object_new(machine->cpu_type);
    DeviceState *plicu, *tmr, *nfc, *gmac;
    DriveInfo *dinfo;
    SnomIoStubState *io;

    qdev_realize(DEVICE(cpuobj), NULL, &error_fatal);
    memory_region_add_subregion(get_system_memory(), D815_RAM_BASE,
                                machine->ram);

    plicu = sysbus_create_varargs(TYPE_D815_PLICU, D815_PLICU_BASE,
                                  qdev_get_gpio_in(DEVICE(cpuobj), ARM_CPU_IRQ),
                                  NULL);
    d815_uart_create(D815_UART0, qdev_get_gpio_in(plicu, D815_IRQ_UART0),
                     serial_hd(0));
    d815_uart_create(D815_UART1, qdev_get_gpio_in(plicu, D815_IRQ_UART1),
                     serial_hd(1));
    sysbus_create_simple(TYPE_D815_RTC, D815_RTC_BASE, NULL);
    sysbus_create_simple(TYPE_D815_LCD, D815_LCD_BASE, NULL);
    sysbus_create_simple(TYPE_D815_KEYPAD, D815_KEYPAD_BASE,
                         qdev_get_gpio_in(plicu, D815_IRQ_KEYPAD));

    nfc = qdev_new(TYPE_D815_NFC);
    dinfo = drive_get(IF_MTD, 0, 0);
    if (dinfo) {
        qdev_prop_set_drive_err(nfc, "drive", blk_by_legacy_dinfo(dinfo),
                                &error_fatal);
    }
    sysbus_realize_and_unref(SYS_BUS_DEVICE(nfc), &error_fatal);
    sysbus_mmio_map(SYS_BUS_DEVICE(nfc), 0, D815_NFC_BASE);
    sysbus_connect_irq(SYS_BUS_DEVICE(nfc), 0,
                       qdev_get_gpio_in(plicu, D815_IRQ_NFC));

    tmr = qdev_new("sp804");
    qdev_prop_set_uint32(tmr, "freq0", D815_TMR_HZ);
    qdev_prop_set_uint32(tmr, "freq1", D815_TMR_HZ);
    sysbus_realize_and_unref(SYS_BUS_DEVICE(tmr), &error_fatal);
    sysbus_mmio_map(SYS_BUS_DEVICE(tmr), 0, D815_TMR);
    sysbus_connect_irq(SYS_BUS_DEVICE(tmr), 0,
                       qdev_get_gpio_in(plicu, D815_IRQ_TMR));

    /* Same Synopsys GMAC as the stmmac driver expects, PHY included. */
    gmac = qdev_new("npcm-gmac");
    qemu_configure_nic_device(gmac, true, NULL);
    sysbus_realize_and_unref(SYS_BUS_DEVICE(gmac), &error_fatal);
    sysbus_mmio_map(SYS_BUS_DEVICE(gmac), 0, D815_GMAC);
    sysbus_connect_irq(SYS_BUS_DEVICE(gmac), 0,
                       qdev_get_gpio_in(plicu, D815_IRQ_GMAC));

    io = snom_map_stub("d815io", D815_IO_BASE, D815_IO_SIZE);

    /* Clock unit: the three PLLs report lock, the switch reports done. */
    snom_stub_fixed(io, D815_CCU + 0x00, 0x00040000);
    snom_stub_fixed(io, D815_CCU + 0x04, 0x00040000);
    snom_stub_fixed(io, D815_CCU + 0x08, 0x00040000);
    snom_stub_fixed(io, D815_CCU + 0x3c, 0x00000020);
    /* dvf_reset() writes two magic words here; the second one takes effect. */
    snom_stub_reset_on(io, D815_CCU + 0x40, 0xffffffff, 0xb5c9c674);

    d815_binfo.loader_start = D815_RAM_BASE;
    d815_binfo.ram_size = machine->ram_size;
    d815_binfo.board_id = -1;
    arm_load_kernel(ARM_CPU(cpuobj), machine, &d815_binfo);
}

static void snom_d815_class_init(ObjectClass *oc, const void *data)
{
    MachineClass *mc = MACHINE_CLASS(oc);

    mc->desc = "snom D815 desk phone (DSP Group DVF99, ARM926EJ-S)";
    mc->init = snom_d815_init;
    mc->ignore_memory_transaction_failures = true;
    mc->default_cpu_type = ARM_CPU_TYPE_NAME("arm926");
    mc->default_ram_id = "snom.ram";
    mc->default_ram_size = 512 * MiB;
}

static const TypeInfo snom_d815_type = {
    .name = MACHINE_TYPE_NAME("snom-d815"),
    .parent = TYPE_MACHINE,
    .class_init = snom_d815_class_init,
    .interfaces = arm_machine_interfaces,
};

static void snom_d815_register_types(void)
{
    type_register_static(&d815_plicu_info);
    type_register_static(&d815_uart_info);
    type_register_static(&d815_rtc_info);
    type_register_static(&d815_nfc_info);
    type_register_static(&d815_lcd_info);
    type_register_static(&d815_keypad_info);
    type_register_static(&snom_d815_type);
}

type_init(snom_d815_register_types)
