/*
	CFUniCharBitmapData.h
	Copyright (c) 1999-2021, Apple Inc. and the Swift project authors. All rights reserved.
	This file is generated. Don't touch this file directly.
*/

#ifndef _cfunichar_bitmap_data_h
#define _cfunichar_bitmap_data_h

#include "_CStdlib.h"

// `_plane0` is the 8192-byte bitmap of plane 0, or NULL when the set has no bitmap for it.
// Each other plane is 256 pages of 32 bytes. `_planes[plane]` holds the index of each page in `__CFUniCharBitmapPages`, or is NULL when the set has no bitmap for the plane. `_planes[0]` is NULL.
typedef struct {
    uint32_t _numPlanes;
    uint8_t const * const _plane0;
    uint16_t const * const * const _planes;
} __CFUniCharBitmapData;

#endif /* _cfunichar_bitmap_data_h */
