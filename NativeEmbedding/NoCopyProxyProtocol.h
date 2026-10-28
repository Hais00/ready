/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef READY_NO_COPY_PROXY_PROTOCOL_H
#define READY_NO_COPY_PROXY_PROTOCOL_H
#import <mach/mach.h>
#import <stdint.h>
enum {NC_HELLO=1,NC_ACQUIRE=2,NC_PRESENT=3,NC_DONE=4};
typedef struct {mach_msg_header_t h;uint32_t op,frame,surface;double gpu;} NCRequest;
typedef struct {mach_msg_header_t h;mach_msg_body_t body;mach_msg_port_descriptor_t port;uint32_t status,frame,window,width,height,surface;} NCReply;
typedef struct {NCRequest message;mach_msg_max_trailer_t trailer;} NCRequestReceive;
typedef struct {NCReply message;mach_msg_max_trailer_t trailer;} NCReplyReceive;
#endif
