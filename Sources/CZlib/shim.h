/* Linux-only shim exposing the system zlib headers to StoutCore's gzip wrapper.
 * On Apple platforms the SDK already provides a `zlib` module, so this target is
 * compiled only when os(Linux) (see Package.swift). */
#include <zlib.h>
