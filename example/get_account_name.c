//SPDX-License-Identifier: GPL-2.0-or-later

#include "pwaccess.h"

#include "basics.h"

int
main(int argc, char **argv)
{
  _cleanup_free_ char *error = NULL;
  _cleanup_free_ char *name = NULL;
  uid_t uid;
  int r;

  if (argc == 1)
    uid = getuid();
  else if (argc == 2)
    uid = atol(argv[1]);
  else
    {
      fprintf(stderr, "Usage: get_account_name <uid>\n");
      return 1;
    }

  r = pwaccess_get_account_name(uid, &name, &error);
  if (r < 0)
    {
      if (error)
        fprintf(stderr, "%s\n", error);
      else
        fprintf(stderr, "check_expired failed: %s\n", strerror(-r));
      return 1;
    }

  printf("Your account name: %s\n", name);

  return 0;
}
