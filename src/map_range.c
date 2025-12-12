// SPDX-License-Identifier: GPL-2.0-or-later

#include "basics.h"
#include "map_range.h"

void
map_range_freep(struct map_range **var)
{
  if (!var || !*var)
    return;

  *var = mfree(*var);
}

