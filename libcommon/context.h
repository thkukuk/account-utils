// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <systemd/sd-event.h>
#include "read_config.h"

struct context_t {
  struct config_t cfg;
  sd_event *loop;
};
