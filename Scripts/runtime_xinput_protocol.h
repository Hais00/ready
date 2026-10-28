/* SPDX-License-Identifier: LGPL-2.1-or-later */
#ifndef READY_XINPUT_PROTOCOL_H
#define READY_XINPUT_PROTOCOL_H
/* Pointer-free layout is identical for PE32, PE64 and the native Unix library. */
struct ready_xinput_capture {
    unsigned int unix_pid;
    unsigned int active;
    unsigned int visible;
    unsigned int command_sequence_low;
    unsigned int command_sequence_high;
    unsigned int reason;
    unsigned int capture_epoch_low;
    unsigned int capture_epoch_high;
};
#endif
