# Building and installing account-utils

## Building with Meson

account-utils requires Meson 0.61.0 or newer.

Building with Meson is quite simple:

```shell
$ meson setup build
$ meson compile -C build
$ meson test -C build
$ sudo meson install -C build
```

On openSUSE or SUSE Linux Enterprise, you should add `-Ddistribution=suse` to get adjusted PAM configuration files.

If you want to build with the address sanitizer enabled, add `-Db_sanitize=address` as an argument to `meson setup`.
