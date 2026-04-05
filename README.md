# Zig bindings for `efsw`

A lightweight Zig library binding [efsw][efsw], "a C++ cross-platform
file system watcher and notifier".

The module `efswz` wraps the C API bindings to accept and return more
Zig-native types.  The module is fairly short, and commented in such a
fashion as to serve as documentation.

There's a demo program which simply tells stdout what it saw.  There are
some platform-specific quirks in how filesystem watchers report, which
this tool can surface quickly.

## Scope

`efzw` watches directories, not individual files.  There is no native
facility for excluding subdirectories, or limiting recursion depth
beyond shallow or deep.  Nor have any such facilities been added to the
Zig bindings.

The watcher takes directory paths, not `Dir` objects.  These paths can
be relative or absolute.

## Status

`efswz` has been built and tested on macOS.  It has been successfully
cross-compiled for Linux and Windows targets, but not yet tested.

If you try it on one or more of the supported targets, and it works, let
me know so I can update the README.  If it _doesn't_ work, I'll take a
patch which claims to fix it, so long as it looks right, but am less
likely to fix it myself (Linux, maybe, Windows, almost certainly not).
But you can file an issue if you'd like, I might tag it or something.

Most of the C API wrapper has been wrapped in its turn, with lacunae
documented in comments.  If those facilities are of such interest to one
of you that you care to add them, a PR would be accepted.

[efsw]: https://github.com/SpartanJ/efsw
