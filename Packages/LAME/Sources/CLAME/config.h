/* Minimal config.h for building libmp3lame 3.100 on Apple platforms.
 *
 * Replaces the autoconf-generated config.h. Only the feature macros the
 * encoder sources actually test (see HAVE_* grep over libmp3lame/) are
 * defined here. Enabled with -DHAVE_CONFIG_H (see Package.swift).
 *
 * Deliberately NOT defined:
 *   HAVE_MPGLIB      - mpglib decode interface; the app only encodes.
 *   HAVE_NASM / HAVE_XMMINTRIN_H - x86 SIMD; iOS is ARM.
 */

#ifndef LAME_MINIMAL_CONFIG_H
#define LAME_MINIMAL_CONFIG_H

#define STDC_HEADERS 1
#define HAVE_ERRNO_H 1
#define HAVE_FCNTL_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_LIMITS_H 1
#define HAVE_MEMCPY 1
#define HAVE_STDINT_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRCHR 1
#define HAVE_STRING_H 1
#define HAVE_UNISTD_H 1

/* From config.h.in (AC_CHECK_TYPES): the system does not provide these. */
#ifndef HAVE_IEEE754_FLOAT32_T
typedef float ieee754_float32_t;
#endif
#ifndef HAVE_IEEE754_FLOAT64_T
typedef double ieee754_float64_t;
#endif

#endif /* LAME_MINIMAL_CONFIG_H */
