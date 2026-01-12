//SPDX-License-Identifier: LGPL-2.1-or-later

#include "config.h"

#include <stdbool.h>

#include "check_caller_perms.h"

/*  Do not allow access if the query does not originate from root
    or the entry does not belong to the calling user.
    Exception: if the peer uid is in the list of exceptions.
    "Lex mariadb": user mysql/mariadb needs to authenticate as
    database user so that the database user can get access to the
    database. */
bool
check_caller_perms(uid_t peer_uid, uid_t target_uid, uid_t *allowed)
{
  if (peer_uid == 0)
    return true;

  if (peer_uid == target_uid)
    return true;

  if (!allowed)
    return false;

  for (size_t i = 0; allowed[i] != 0; i++)
    if (peer_uid == allowed[i])
      return true;

  return false;
}
