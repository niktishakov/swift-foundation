/*
	CFUniCharBitmapData.h
	Copyright (c) 1999-2021, Apple Inc. and the Swift project authors. All rights reserved.
	This file is generated. Don't touch this file directly.
*/

#ifndef _cfunichar_bitmap_data_h
#define _cfunichar_bitmap_data_h

#include "_CStdlib.h"

// A plane is 256 pages of 32 bytes. `_planes[plane]` holds the index of each page in `__CFUniCharBitmapPages`, or is NULL when the set has no bitmap for the plane.
typedef struct {
    uint32_t _numPlanes;
    uint16_t const * const * const _planes;
} __CFUniCharBitmapData;

#endif /* _cfunichar_bitmap_data_h */
