// SPDX-License-Identifier: BSD-2-Clause

#include "config.h"

#include <string.h>
#include <systemd/sd-bus.h>

#include "basics.h"
#include "pam_unix_ng.h"

typedef struct {
  pam_handle_t *pamh;
  const char *unit;
  int finished;
  int success;
} job_ctx_t;

#define TIMEOUT_USEC 2 * 1000000 // 2 seconds

// Callback triggered whenever systemd removes ANY job from its queue.
static int
on_job_removed_cb(sd_bus_message *m, void *userdata,
		  sd_bus_error *ret_error _unused_)
{
  job_ctx_t *ctx = userdata;
  uint32_t id;
  const char *path, *unit, *result;
  int r;

  // The JobRemoved signal signature is: uoss (id, object_path, unit_name, result)
  r = sd_bus_message_read(m, "uoss", &id, &path, &unit, &result);
  if (r < 0)
    return 0; // Ignore unparseable signals

  // Is this the unit we are waiting for?
  if (streq(unit, ctx->unit))
    {
      ctx->finished = 1;

      if (streq(result, "done"))
	ctx->success = 1;
      else
	{
	  pam_syslog(ctx->pamh, LOG_ERR, "Job for %s failed with result: %s", unit, result);
	  ctx->success = 0;
        }
    }

  return 0;
}

int
start_pwaccessd(pam_handle_t *pamh, uint32_t ctrl)
{
  job_ctx_t ctx = {
    .pamh = pamh,
    .unit = "pwaccessd.socket",
    .finished = 0,
    .success = 0
    };
  sd_bus_error error = SD_BUS_ERROR_NULL;
  _cleanup_(sd_bus_message_unrefp) sd_bus_message *reply = NULL;
  _cleanup_(sd_bus_slot_unrefp) sd_bus_slot *slot = NULL;
  _cleanup_(sd_bus_flush_close_unrefp) sd_bus *bus = NULL;
  int r;

  if (ctrl & ARG_DEBUG)
    pam_syslog(pamh, LOG_DEBUG, "Trying to start pwaccessd.socket...");

  r = sd_bus_default_system(&bus);
  if (r < 0)
    {
      pam_syslog(pamh, LOG_ERR, "Failed to connect to dbus: %s", strerror(-r));
      return r;
    }

  r = sd_bus_match_signal(bus,
			  &slot,                              // Slot object for easy cleanup
			  "org.freedesktop.systemd1",         // Sender
			  "/org/freedesktop/systemd1",        // Object path
			  "org.freedesktop.systemd1.Manager", // Interface
			  "JobRemoved",                       // Signal name
			  on_job_removed_cb,
			  &ctx);
  if (r < 0)
    {
      pam_syslog(pamh, LOG_ERR, "Failed to subscribe to 'JobRemoved' DBus signal: %s", strerror(-r));
      return r;
    }

  r = sd_bus_call_method(bus,
			 "org.freedesktop.systemd1",         // Destination service
			 "/org/freedesktop/systemd1",        // Object path
			 "org.freedesktop.systemd1.Manager", // Interface name
			 "StartUnit",                        // Method name
			 &error,                             // Error return object
			 &reply,                             // Reply message
			 "ss",                               // Input signature (two strings)
			 "pwaccessd.socket",                 // Arg 1: Unit name
			 "replace"                           // Arg 2: Job mode
			 );
  if (r < 0)
    {
      pam_syslog(pamh, LOG_ERR, "Failed to start pwaccessd.socket: %s", error.message);
      return r;
    }
  else if (ctrl & ARG_DEBUG)
    pam_syslog(pamh, LOG_DEBUG, "Start job queued. Waiting for %s.", ctx.unit);

  while (!ctx.finished)
    {
      // Process any pending bus messages (this will fire our callback if the signal arrived)
      r = sd_bus_process(bus, NULL);
      if (r < 0)
	{
	  pam_syslog(pamh, LOG_ERR, "DBus processing failed: %s", strerror(-r));
	  return r;
        }
      else if (r > 0) // success, check if ctx.finished is 1
	continue;

      r = sd_bus_wait(bus, TIMEOUT_USEC);
      if (r < 0)
	{
	  pam_syslog(pamh, LOG_ERR, "DBus wait failed: %s", strerror(-r));
	  return r;
        }
      if (r == 0)
	{
	  pam_syslog(pamh, LOG_ERR, "DBus timeout, starting pwaccessd failed");
	  return -ETIME;
	}
    }

  if (!ctx.success)
    return -ENOENT;

  if (ctrl & ARG_DEBUG)
    pam_syslog(pamh, LOG_DEBUG, "pwaccessd successfully started");
  return 0;
}
