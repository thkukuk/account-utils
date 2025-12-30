// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <stdint.h>

struct map_range {
  int64_t upper; /* first ID inside the namespace */
  int64_t lower; /* first ID outside the namespace */
  int64_t count; /* Length of the inside and outside ranges */
};

extern void map_range_freep(struct map_range **var);
