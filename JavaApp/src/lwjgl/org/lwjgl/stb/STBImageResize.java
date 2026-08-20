/*
 * Copyright LWJGL. All rights reserved.
 * License terms: https://www.lwjgl.org/license
 *
 * iOS compatibility patch:
 * LWJGL 3.4.1 split nstbir_resize_uint8 (which returned int) into
 * nstbir_resize_uint8_srgb / nstbir_resize_uint8_linear (which return long).
 * MC 1.21.1 (compiled against LWJGL 3.3.3-SNAPSHOT) still calls the old method signature,
 * int nstbir_resize_uint8(long, int, int, int, long, int, int, int, int)，
 * producing hundreds of NoSuchMethodError lines per second.
 *
 * This class copies upstream LWJGL 3.4.1's STBImageResize verbatim and adds the compatibility method
 * nstbir_resize_uint8, which delegates to nstbir_resize_uint8_srgb.
 */
package org.lwjgl.stb;

import java.nio.Buffer;
import java.nio.ByteBuffer;
import java.nio.FloatBuffer;
import java.nio.ShortBuffer;

import org.lwjgl.system.Checks;
import org.lwjgl.system.MemoryUtil;
import org.lwjgl.system.Pointer;

public class STBImageResize {
    public static final int STBIR_1CHANNEL = 1;
    public static final int STBIR_2CHANNEL = 2;
    public static final int STBIR_RGB = 3;
    public static final int STBIR_BGR = 0;
    public static final int STBIR_4CHANNEL = 5;
    public static final int STBIR_RGBA = 4;
    public static final int STBIR_BGRA = 6;
    public static final int STBIR_ARGB = 7;
    public static final int STBIR_ABGR = 8;
    public static final int STBIR_RA = 9;
    public static final int STBIR_AR = 10;
    public static final int STBIR_RGBA_PM = 11;
    public static final int STBIR_BGRA_PM = 12;
    public static final int STBIR_ARGB_PM = 13;
    public static final int STBIR_ABGR_PM = 14;
    public static final int STBIR_RA_PM = 15;
    public static final int STBIR_AR_PM = 16;
    public static final int STBIR_RGBA_NO_AW = 11;
    public static final int STBIR_BGRA_NO_AW = 12;
    public static final int STBIR_ARGB_NO_AW = 13;
    public static final int STBIR_ABGR_NO_AW = 14;
    public static final int STBIR_RA_NO_AW = 15;
    public static final int STBIR_AR_NO_AW = 16;
    public static final int STBIR_EDGE_CLAMP = 0;
    public static final int STBIR_EDGE_REFLECT = 1;
    public static final int STBIR_EDGE_WRAP = 2;
    public static final int STBIR_EDGE_ZERO = 3;
    public static final int STBIR_FILTER_DEFAULT = 0;
    public static final int STBIR_FILTER_BOX = 1;
    public static final int STBIR_FILTER_TRIANGLE = 2;
    public static final int STBIR_FILTER_CUBICBSPLINE = 3;
    public static final int STBIR_FILTER_CATMULLROM = 4;
    public static final int STBIR_FILTER_MITCHELL = 5;
    public static final int STBIR_FILTER_POINT_SAMPLE = 6;
    public static final int STBIR_FILTER_OTHER = 7;
    public static final int STBIR_TYPE_UINT8 = 0;
    public static final int STBIR_TYPE_UINT8_SRGB = 1;
    public static final int STBIR_TYPE_UINT8_SRGB_ALPHA = 2;
    public static final int STBIR_TYPE_UINT16 = 3;
    public static final int STBIR_TYPE_FLOAT = 4;
    public static final int STBIR_TYPE_HALF_FLOAT = 5;

    private static final int[] stbir_pixel_layout_channels;
    private static final int[] stbir_type_size;

    protected STBImageResize() {
        throw new UnsupportedOperationException();
    }

    // ========================================================================
    // Compatibility method: the old API signature MC 1.21.1 calls
    // Old LWJGL: int nstbir_resize_uint8(long, int, int, int, long, int, int, int, int)
    // New LWJGL 3.4.1: long nstbir_resize_uint8_srgb(same parameters)
    // Delegates to the srgb variant, converting the long pointer return value into an int (0=failure, 1=success)
    // ========================================================================
    public static int nstbir_resize_uint8(long input_pixels, int input_w, int input_h, int input_stride_in_bytes,
                                           long output_pixels, int output_w, int output_h, int output_stride_in_bytes,
                                           int pixel_type) {
        long result = nstbir_resize_uint8_srgb(input_pixels, input_w, input_h, input_stride_in_bytes,
                                                output_pixels, output_w, output_h, output_stride_in_bytes,
                                                pixel_type);
        return result != 0L ? 1 : 0;
    }

    // ========================================================================
    // Compatibility layer for the stb_image_resize v1 API (LWJGL 3.3.1 and older)
    //
    // Minecraft 1.20.1 and 1.19.x ship LWJGL 3.3.1, whose STBImageResize exposes
    // stb_image_resize v1. LWJGL 3.3.3 replaced it with the v2 rewrite and deleted every
    // v1 entry point. Mods compiled against 1.20.1 therefore call methods this class no
    // longer has and die with NoSuchMethodError - JourneyMap does exactly that while
    // building its minimap frame, which aborts the whole Forge deferred work queue and
    // takes the game down on the loading screen.
    //
    // The methods below restore the v1 signatures on top of the v2 implementation. They
    // are overloads, not replacements: every v1 form differs in arity or return type from
    // its v2 counterpart, so the v2 API above is untouched.
    //
    // Three details of the translation are easy to get wrong:
    //   - v1 edge modes are 1-based (CLAMP=1..ZERO=4), v2 are 0-based (CLAMP=0..ZERO=3).
    //   - v1 describes pixels as (num_channels, alpha_channel, flags); v2 uses a single
    //     pixel-layout enum, so the three are folded into one below.
    //   - LWJGL 3.3.1 declares both STBIR_FLAG_ALPHA_* constants as -1 rather than 1 and 2.
    //     A mod passing one of them hands over -1, which has every bit set, so a plain
    //     bitmask test would read it as premultiplied. Only positive flags are examined.
    //
    // Filter values are unchanged between the two versions and pass through as they are.
    // The v1 region and subpixel families are not restored: they take floating point source
    // rectangles that v2 only reaches through the extended STBIR_RESIZE API, and no
    // Minecraft mod is known to call them.
    // ========================================================================

    private static final int STBIR_V1_ALPHA_CHANNEL_NONE = -1;
    private static final int STBIR_V1_COLORSPACE_SRGB = 1;

    /** Folds the v1 (num_channels, alpha_channel, flags) triple into a v2 pixel layout. */
    private static int v1PixelLayout(int num_channels, int alpha_channel, int flags) {
        // Only a positive flag word is a real bitmask; see the note about -1 above.
        boolean premultiplied = flags > 0 && (flags & 1) != 0;
        boolean weightByAlpha = alpha_channel != STBIR_V1_ALPHA_CHANNEL_NONE;
        switch (num_channels) {
            case 1:  return STBIR_1CHANNEL;
            case 2:  return weightByAlpha ? (premultiplied ? STBIR_RA_PM : STBIR_RA) : STBIR_2CHANNEL;
            case 3:  return STBIR_RGB;
            case 4:  return weightByAlpha ? (premultiplied ? STBIR_RGBA_PM : STBIR_RGBA) : STBIR_4CHANNEL;
            default: return STBIR_RGBA;
        }
    }

    /** v1 edge modes start at 1, v2 at 0. Anything unrecognised falls back to clamping. */
    private static int v1EdgeMode(int edge) {
        return (edge >= 1 && edge <= 4) ? edge - 1 : STBIR_EDGE_CLAMP;
    }

    /** Filter values are identical in both versions; guard the range anyway. */
    private static int v1Filter(int filter) {
        return (filter >= 0 && filter <= 7) ? filter : STBIR_FILTER_DEFAULT;
    }

    private static int v1DataType(int colorspace) {
        return colorspace == STBIR_V1_COLORSPACE_SRGB ? STBIR_TYPE_UINT8_SRGB : STBIR_TYPE_UINT8;
    }

    // --- v1: stbir_resize_uint8 ---------------------------------------------------------
    // The native half already exists above for MC 1.21.1; this is the buffer form, which
    // 1.20.1 mods call and which was missing.

    public static boolean stbir_resize_uint8(ByteBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes,
                                             ByteBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes,
                                             int num_channels) {
        return nstbir_resize_uint8(MemoryUtil.memAddress(input_pixels), input_w, input_h, input_stride_in_bytes,
                                   MemoryUtil.memAddressSafe(output_pixels), output_w, output_h, output_stride_in_bytes,
                                   v1PixelLayout(num_channels, num_channels - 1, 0)) != 0;
    }

    // --- v1: stbir_resize_uint8_generic --------------------------------------------------
    // This is the one JourneyMap calls.

    public static int nstbir_resize_uint8_generic(long input_pixels, int input_w, int input_h, int input_stride_in_bytes,
                                                  long output_pixels, int output_w, int output_h, int output_stride_in_bytes,
                                                  int num_channels, int alpha_channel, int flags,
                                                  int edge_wrap_mode, int filter, int space, long alloc_context) {
        long result = nstbir_resize(input_pixels, input_w, input_h, input_stride_in_bytes,
                                    output_pixels, output_w, output_h, output_stride_in_bytes,
                                    v1PixelLayout(num_channels, alpha_channel, flags), v1DataType(space),
                                    v1EdgeMode(edge_wrap_mode), v1Filter(filter));
        return result != 0L ? 1 : 0;
    }

    public static boolean stbir_resize_uint8_generic(ByteBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes,
                                                     ByteBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes,
                                                     int num_channels, int alpha_channel, int flags,
                                                     int edge_wrap_mode, int filter, int space) {
        return nstbir_resize_uint8_generic(MemoryUtil.memAddress(input_pixels), input_w, input_h, input_stride_in_bytes,
                                           MemoryUtil.memAddressSafe(output_pixels), output_w, output_h, output_stride_in_bytes,
                                           num_channels, alpha_channel, flags, edge_wrap_mode, filter, space, 0L) != 0;
    }

    // --- v1: stbir_resize_uint8_srgb (11 arguments, distinct from the 9-argument v2 form) --

    public static int nstbir_resize_uint8_srgb(long input_pixels, int input_w, int input_h, int input_stride_in_bytes,
                                               long output_pixels, int output_w, int output_h, int output_stride_in_bytes,
                                               int num_channels, int alpha_channel, int flags) {
        long result = nstbir_resize(input_pixels, input_w, input_h, input_stride_in_bytes,
                                    output_pixels, output_w, output_h, output_stride_in_bytes,
                                    v1PixelLayout(num_channels, alpha_channel, flags), STBIR_TYPE_UINT8_SRGB,
                                    STBIR_EDGE_CLAMP, STBIR_FILTER_DEFAULT);
        return result != 0L ? 1 : 0;
    }

    public static boolean stbir_resize_uint8_srgb(ByteBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes,
                                                  ByteBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes,
                                                  int num_channels, int alpha_channel, int flags) {
        return nstbir_resize_uint8_srgb(MemoryUtil.memAddress(input_pixels), input_w, input_h, input_stride_in_bytes,
                                        MemoryUtil.memAddressSafe(output_pixels), output_w, output_h, output_stride_in_bytes,
                                        num_channels, alpha_channel, flags) != 0;
    }

    // --- v1: stbir_resize_uint8_srgb_edgemode --------------------------------------------

    public static int nstbir_resize_uint8_srgb_edgemode(long input_pixels, int input_w, int input_h, int input_stride_in_bytes,
                                                        long output_pixels, int output_w, int output_h, int output_stride_in_bytes,
                                                        int num_channels, int alpha_channel, int flags, int edge_wrap_mode) {
        long result = nstbir_resize(input_pixels, input_w, input_h, input_stride_in_bytes,
                                    output_pixels, output_w, output_h, output_stride_in_bytes,
                                    v1PixelLayout(num_channels, alpha_channel, flags), STBIR_TYPE_UINT8_SRGB,
                                    v1EdgeMode(edge_wrap_mode), STBIR_FILTER_DEFAULT);
        return result != 0L ? 1 : 0;
    }

    public static boolean stbir_resize_uint8_srgb_edgemode(ByteBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes,
                                                           ByteBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes,
                                                           int num_channels, int alpha_channel, int flags, int edge_wrap_mode) {
        return nstbir_resize_uint8_srgb_edgemode(MemoryUtil.memAddress(input_pixels), input_w, input_h, input_stride_in_bytes,
                                                 MemoryUtil.memAddressSafe(output_pixels), output_w, output_h, output_stride_in_bytes,
                                                 num_channels, alpha_channel, flags, edge_wrap_mode) != 0;
    }

    // --- v1: stbir_resize_float / stbir_resize_float_generic -----------------------------

    public static int nstbir_resize_float_generic(long input_pixels, int input_w, int input_h, int input_stride_in_bytes,
                                                  long output_pixels, int output_w, int output_h, int output_stride_in_bytes,
                                                  int num_channels, int alpha_channel, int flags,
                                                  int edge_wrap_mode, int filter, int space, long alloc_context) {
        long result = nstbir_resize(input_pixels, input_w, input_h, input_stride_in_bytes,
                                    output_pixels, output_w, output_h, output_stride_in_bytes,
                                    v1PixelLayout(num_channels, alpha_channel, flags), STBIR_TYPE_FLOAT,
                                    v1EdgeMode(edge_wrap_mode), v1Filter(filter));
        return result != 0L ? 1 : 0;
    }

    public static boolean stbir_resize_float_generic(FloatBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes,
                                                     FloatBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes,
                                                     int num_channels, int alpha_channel, int flags,
                                                     int edge_wrap_mode, int filter, int space) {
        return nstbir_resize_float_generic(MemoryUtil.memAddress(input_pixels), input_w, input_h, input_stride_in_bytes,
                                            MemoryUtil.memAddressSafe(output_pixels), output_w, output_h, output_stride_in_bytes,
                                            num_channels, alpha_channel, flags, edge_wrap_mode, filter, space, 0L) != 0;
    }

    public static int nstbir_resize_float(long input_pixels, int input_w, int input_h, int input_stride_in_bytes,
                                          long output_pixels, int output_w, int output_h, int output_stride_in_bytes,
                                          int num_channels) {
        long result = nstbir_resize(input_pixels, input_w, input_h, input_stride_in_bytes,
                                    output_pixels, output_w, output_h, output_stride_in_bytes,
                                    v1PixelLayout(num_channels, num_channels - 1, 0), STBIR_TYPE_FLOAT,
                                    STBIR_EDGE_CLAMP, STBIR_FILTER_DEFAULT);
        return result != 0L ? 1 : 0;
    }

    public static boolean stbir_resize_float(FloatBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes,
                                             FloatBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes,
                                             int num_channels) {
        return nstbir_resize_float(MemoryUtil.memAddress(input_pixels), input_w, input_h, input_stride_in_bytes,
                                    MemoryUtil.memAddressSafe(output_pixels), output_w, output_h, output_stride_in_bytes,
                                    num_channels) != 0;
    }

    // --- v1: stbir_resize (the full form, with per-axis edge and filter) -----------------
    // v1 numbered its data types UINT8=0, UINT16=1, UINT32=2, FLOAT=3. v2 inserted the two
    // sRGB types after UINT8, so everything above UINT8 shifted. v2 also takes a single edge
    // and filter rather than one per axis; the horizontal value is used, which is what the
    // callers of this function pass for both in every case worth supporting.

    private static int v1DataTypeFull(int datatype, int colorspace) {
        switch (datatype) {
            case 0:  return colorspace == STBIR_V1_COLORSPACE_SRGB ? STBIR_TYPE_UINT8_SRGB : STBIR_TYPE_UINT8;
            case 1:  return STBIR_TYPE_UINT16;
            case 2:  return STBIR_TYPE_UINT16; // v1 UINT32 has no v2 counterpart; 16-bit is the closest
            case 3:  return STBIR_TYPE_FLOAT;
            default: return STBIR_TYPE_UINT8;
        }
    }

    public static int nstbir_resize(long input_pixels, int input_w, int input_h, int input_stride_in_bytes,
                                    long output_pixels, int output_w, int output_h, int output_stride_in_bytes,
                                    int datatype, int num_channels, int alpha_channel, int flags,
                                    int edge_mode_horizontal, int edge_mode_vertical,
                                    int filter_horizontal, int filter_vertical,
                                    int space, long alloc_context) {
        long result = nstbir_resize(input_pixels, input_w, input_h, input_stride_in_bytes,
                                    output_pixels, output_w, output_h, output_stride_in_bytes,
                                    v1PixelLayout(num_channels, alpha_channel, flags),
                                    v1DataTypeFull(datatype, space),
                                    v1EdgeMode(edge_mode_horizontal), v1Filter(filter_horizontal));
        return result != 0L ? 1 : 0;
    }

    public static boolean stbir_resize(ByteBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes,
                                       ByteBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes,
                                       int datatype, int num_channels, int alpha_channel, int flags,
                                       int edge_mode_horizontal, int edge_mode_vertical,
                                       int filter_horizontal, int filter_vertical, int space) {
        return nstbir_resize(MemoryUtil.memAddress(input_pixels), input_w, input_h, input_stride_in_bytes,
                             MemoryUtil.memAddressSafe(output_pixels), output_w, output_h, output_stride_in_bytes,
                             datatype, num_channels, alpha_channel, flags,
                             edge_mode_horizontal, edge_mode_vertical,
                             filter_horizontal, filter_vertical, space, 0L) != 0;
    }

    // --- v1: stbir_resize_uint16_generic --------------------------------------------------

    public static int nstbir_resize_uint16_generic(long input_pixels, int input_w, int input_h, int input_stride_in_bytes,
                                                   long output_pixels, int output_w, int output_h, int output_stride_in_bytes,
                                                   int num_channels, int alpha_channel, int flags,
                                                   int edge_wrap_mode, int filter, int space, long alloc_context) {
        long result = nstbir_resize(input_pixels, input_w, input_h, input_stride_in_bytes,
                                    output_pixels, output_w, output_h, output_stride_in_bytes,
                                    v1PixelLayout(num_channels, alpha_channel, flags), STBIR_TYPE_UINT16,
                                    v1EdgeMode(edge_wrap_mode), v1Filter(filter));
        return result != 0L ? 1 : 0;
    }

    public static boolean stbir_resize_uint16_generic(ShortBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes,
                                                      ShortBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes,
                                                      int num_channels, int alpha_channel, int flags,
                                                      int edge_wrap_mode, int filter, int space) {
        return nstbir_resize_uint16_generic(MemoryUtil.memAddress(input_pixels), input_w, input_h, input_stride_in_bytes,
                                             MemoryUtil.memAddressSafe(output_pixels), output_w, output_h, output_stride_in_bytes,
                                             num_channels, alpha_channel, flags, edge_wrap_mode, filter, space, 0L) != 0;
    }

    // ========================================================================
    // Upstream LWJGL 3.4.1 native methods (kept as they are)
    // ========================================================================

    public static native long nstbir_resize_uint8_srgb(long var0, int var2, int var3, int var4, long var5, int var7, int var8, int var9, int var10);

    public static ByteBuffer stbir_resize_uint8_srgb(ByteBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes, ByteBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes, int pixel_type) {
        int length = calculateBufferSize(output_w, output_h, output_stride_in_bytes, pixel_type, 1);
        if (Checks.CHECKS) {
            Checks.checkSafe((Buffer)output_pixels, (int)length);
        }
        long __result = nstbir_resize_uint8_srgb(MemoryUtil.memAddress((ByteBuffer)input_pixels), input_w, input_h, input_stride_in_bytes, MemoryUtil.memAddressSafe((ByteBuffer)output_pixels), output_w, output_h, output_stride_in_bytes, pixel_type);
        return MemoryUtil.memByteBufferSafe((long)__result, (int)length);
    }

    public static ByteBuffer stbir_resize_uint8_srgb(ByteBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes, ByteBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes, int pixel_type, long length) {
        if (Checks.CHECKS) {
            Checks.checkSafe((Buffer)output_pixels, (long)length);
        }
        long __result = nstbir_resize_uint8_srgb(MemoryUtil.memAddress((ByteBuffer)input_pixels), input_w, input_h, input_stride_in_bytes, MemoryUtil.memAddressSafe((ByteBuffer)output_pixels), output_w, output_h, output_stride_in_bytes, pixel_type);
        return MemoryUtil.memByteBufferSafe((long)__result, (int)((int)length));
    }

    public static native long nstbir_resize_uint8_linear(long var0, int var2, int var3, int var4, long var5, int var7, int var8, int var9, int var10);

    public static ByteBuffer stbir_resize_uint8_linear(ByteBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes, ByteBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes, int pixel_type) {
        int length = calculateBufferSize(output_w, output_h, output_stride_in_bytes, pixel_type, 1);
        if (Checks.CHECKS) {
            Checks.checkSafe((Buffer)output_pixels, (int)length);
        }
        long __result = nstbir_resize_uint8_linear(MemoryUtil.memAddress((ByteBuffer)input_pixels), input_w, input_h, input_stride_in_bytes, MemoryUtil.memAddressSafe((ByteBuffer)output_pixels), output_w, output_h, output_stride_in_bytes, pixel_type);
        return MemoryUtil.memByteBufferSafe((long)__result, (int)length);
    }

    public static ByteBuffer stbir_resize_uint8_linear(ByteBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes, ByteBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes, int pixel_type, long length) {
        if (Checks.CHECKS) {
            Checks.checkSafe((Buffer)output_pixels, (long)length);
        }
        long __result = nstbir_resize_uint8_linear(MemoryUtil.memAddress((ByteBuffer)input_pixels), input_w, input_h, input_stride_in_bytes, MemoryUtil.memAddressSafe((ByteBuffer)output_pixels), output_w, output_h, output_stride_in_bytes, pixel_type);
        return MemoryUtil.memByteBufferSafe((long)__result, (int)((int)length));
    }

    public static native long nstbir_resize_float_linear(long var0, int var2, int var3, int var4, long var5, int var7, int var8, int var9, int var10);

    public static FloatBuffer stbir_resize_float_linear(FloatBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes, FloatBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes, int pixel_type) {
        int length = calculateBufferSize(output_w, output_h, output_stride_in_bytes, pixel_type, 4);
        if (Checks.CHECKS) {
            Checks.checkSafe((Buffer)output_pixels, (int)length);
        }
        long __result = nstbir_resize_float_linear(MemoryUtil.memAddress((FloatBuffer)input_pixels), input_w, input_h, input_stride_in_bytes, MemoryUtil.memAddressSafe((FloatBuffer)output_pixels), output_w, output_h, output_stride_in_bytes, pixel_type);
        return MemoryUtil.memFloatBufferSafe((long)__result, (int)length);
    }

    public static FloatBuffer stbir_resize_float_linear(FloatBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes, FloatBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes, int pixel_type, long length) {
        if (Checks.CHECKS) {
            Checks.checkSafe((Buffer)output_pixels, (long)length);
        }
        long __result = nstbir_resize_float_linear(MemoryUtil.memAddress((FloatBuffer)input_pixels), input_w, input_h, input_stride_in_bytes, MemoryUtil.memAddressSafe((FloatBuffer)output_pixels), output_w, output_h, output_stride_in_bytes, pixel_type);
        return MemoryUtil.memFloatBufferSafe((long)__result, (int)((int)length));
    }

    public static native long nstbir_resize(long var0, int var2, int var3, int var4, long var5, int var7, int var8, int var9, int var10, int var11, int var12, int var13);

    public static ByteBuffer stbir_resize(ByteBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes, ByteBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes, int pixel_layout, int data_type, int edge, int filter) {
        int length = calculateBufferSize(output_w, output_h, output_stride_in_bytes, pixel_layout, stbir_type_size[data_type]);
        if (Checks.CHECKS) {
            Checks.checkSafe((Buffer)output_pixels, (int)length);
        }
        long __result = nstbir_resize(MemoryUtil.memAddress((ByteBuffer)input_pixels), input_w, input_h, input_stride_in_bytes, MemoryUtil.memAddressSafe((ByteBuffer)output_pixels), output_w, output_h, output_stride_in_bytes, pixel_layout, data_type, edge, filter);
        return MemoryUtil.memByteBufferSafe((long)__result, (int)length);
    }

    public static ByteBuffer stbir_resize(ByteBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes, ByteBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes, int pixel_layout, int data_type, int edge, int filter, long length) {
        if (Checks.CHECKS) {
            Checks.checkSafe((Buffer)output_pixels, (long)length);
        }
        long __result = nstbir_resize(MemoryUtil.memAddress((ByteBuffer)input_pixels), input_w, input_h, input_stride_in_bytes, MemoryUtil.memAddressSafe((ByteBuffer)output_pixels), output_w, output_h, output_stride_in_bytes, pixel_layout, data_type, edge, filter);
        return MemoryUtil.memByteBufferSafe((long)__result, (int)((int)length));
    }

    public static native void nstbir_resize_init(long var0, long var2, int var4, int var5, int var6, long var7, int var9, int var10, int var11, int var12, int var13);

    public static void stbir_resize_init(STBIR_RESIZE resize, ByteBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes, ByteBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes, int pixel_layout, int data_type) {
        if (Checks.CHECKS) {
            Checks.checkSafe((Buffer)output_pixels, (int)calculateBufferSize(output_w, output_h, output_stride_in_bytes, pixel_layout, stbir_type_size[data_type]));
        }
        nstbir_resize_init(resize.address(), MemoryUtil.memAddress((ByteBuffer)input_pixels), input_w, input_h, input_stride_in_bytes, MemoryUtil.memAddressSafe((ByteBuffer)output_pixels), output_w, output_h, output_stride_in_bytes, pixel_layout, data_type);
    }

    public static native void nstbir_set_datatypes(long var0, int var2, int var3);

    public static void stbir_set_datatypes(STBIR_RESIZE resize, int input_type, int output_type) {
        nstbir_set_datatypes(resize.address(), input_type, output_type);
    }

    public static native void nstbir_set_pixel_callbacks(long var0, long var2, long var4);

    public static void stbir_set_pixel_callbacks(STBIR_RESIZE resize, STBIRInputCallbackI input_cb, STBIROutputCallbackI output_cb) {
        nstbir_set_pixel_callbacks(resize.address(), MemoryUtil.memAddressSafe((Pointer)input_cb), MemoryUtil.memAddressSafe((Pointer)output_cb));
    }

    public static native void nstbir_set_user_data(long var0, long var2);

    public static void stbir_set_user_data(STBIR_RESIZE resize, long user_data) {
        nstbir_set_user_data(resize.address(), user_data);
    }

    public static native void nstbir_set_buffer_ptrs(long var0, long var2, int var4, long var5, int var7);

    public static void stbir_set_buffer_ptrs(STBIR_RESIZE resize, ByteBuffer input_pixels, int input_stride_in_bytes, ByteBuffer output_pixels, int output_stride_in_bytes) {
        nstbir_set_buffer_ptrs(resize.address(), MemoryUtil.memAddress((ByteBuffer)input_pixels), input_stride_in_bytes, MemoryUtil.memAddressSafe((ByteBuffer)output_pixels), output_stride_in_bytes);
    }

    public static native int nstbir_set_pixel_layouts(long var0, int var2, int var3);

    public static int stbir_set_pixel_layouts(STBIR_RESIZE resize, int input_pixel_layout, int output_pixel_layout) {
        return nstbir_set_pixel_layouts(resize.address(), input_pixel_layout, output_pixel_layout);
    }

    public static native int nstbir_set_edgemodes(long var0, int var2, int var3);

    public static int stbir_set_edgemodes(STBIR_RESIZE resize, int horizontal_edge, int vertical_edge) {
        return nstbir_set_edgemodes(resize.address(), horizontal_edge, vertical_edge);
    }

    public static native int nstbir_set_filters(long var0, int var2, int var3);

    public static int stbir_set_filters(STBIR_RESIZE resize, int horizontal_filter, int vertical_filter) {
        return nstbir_set_filters(resize.address(), horizontal_filter, vertical_filter);
    }

    public static native int nstbir_set_filter_callbacks(long var0, long var2, long var4, long var6, long var8);

    public static int stbir_set_filter_callbacks(STBIR_RESIZE resize, STBIRKernelCallbackI horizontal_filter, STBIRSupportCallbackI horizontal_support, STBIRKernelCallbackI vertical_filter, STBIRSupportCallbackI vertical_support) {
        return nstbir_set_filter_callbacks(resize.address(), MemoryUtil.memAddressSafe((Pointer)horizontal_filter), MemoryUtil.memAddressSafe((Pointer)horizontal_support), MemoryUtil.memAddressSafe((Pointer)vertical_filter), MemoryUtil.memAddressSafe((Pointer)vertical_support));
    }

    public static native int nstbir_set_pixel_subrect(long var0, int var2, int var3, int var4, int var5);

    public static int stbir_set_pixel_subrect(STBIR_RESIZE resize, int subx, int suby, int subw, int subh) {
        return nstbir_set_pixel_subrect(resize.address(), subx, suby, subw, subh);
    }

    public static native int nstbir_set_input_subrect(long var0, double var2, double var4, double var6, double var8);

    public static int stbir_set_input_subrect(STBIR_RESIZE resize, double s0, double t0, double s1, double t1) {
        return nstbir_set_input_subrect(resize.address(), s0, t0, s1, t1);
    }

    public static native int nstbir_set_output_pixel_subrect(long var0, int var2, int var3, int var4, int var5);

    public static int stbir_set_output_pixel_subrect(STBIR_RESIZE resize, int subx, int suby, int subw, int subh) {
        return nstbir_set_output_pixel_subrect(resize.address(), subx, suby, subw, subh);
    }

    public static native int nstbir_set_non_pm_alpha_speed_over_quality(long var0, int var2);

    public static int stbir_set_non_pm_alpha_speed_over_quality(STBIR_RESIZE resize, boolean non_pma_alpha_speed_over_quality) {
        return nstbir_set_non_pm_alpha_speed_over_quality(resize.address(), non_pma_alpha_speed_over_quality ? 1 : 0);
    }

    public static native int nstbir_build_samplers(long var0);

    public static int stbir_build_samplers(STBIR_RESIZE resize) {
        return nstbir_build_samplers(resize.address());
    }

    public static native void nstbir_free_samplers(long var0);

    public static void stbir_free_samplers(STBIR_RESIZE resize) {
        nstbir_free_samplers(resize.address());
    }

    public static native int nstbir_resize_extended(long var0);

    public static int stbir_resize_extended(STBIR_RESIZE resize) {
        return nstbir_resize_extended(resize.address());
    }

    public static native int nstbir_build_samplers_with_splits(long var0, int var2);

    public static int stbir_build_samplers_with_splits(STBIR_RESIZE resize, int try_splits) {
        return nstbir_build_samplers_with_splits(resize.address(), try_splits);
    }

    public static native int nstbir_resize_extended_split(long var0, int var2, int var3);

    public static int stbir_resize_extended_split(STBIR_RESIZE resize, int split_start, int split_count) {
        return nstbir_resize_extended_split(resize.address(), split_start, split_count);
    }

    private static int calculateBufferSize(int width, int height, int stride_in_bytes, int pixel_type, int type_size) {
        return height * (stride_in_bytes == 0 ? width * stbir_pixel_layout_channels[pixel_type] * type_size : stride_in_bytes);
    }

    static {
        LibSTB.initialize();
        stbir_pixel_layout_channels = new int[]{3, 1, 2, 3, 4, 4, 4, 4, 4, 2, 2, 4, 4, 4, 4, 2, 2};
        stbir_type_size = new int[]{1, 1, 1, 2, 4, 2};
    }

    // ========================================================================================
    // The rest of the v1 surface: array forms, the allocator-context forms, and the two
    // functions that resize part of an image.
    //
    // v1 published a plain-array form of every resize alongside the buffer form, and a form
    // carrying an allocator context. The context is a pointer to an allocator v1 never used for
    // anything a caller could observe, and v2 has no equivalent, so it is accepted and ignored.
    //
    // region and subpixel were the earlier note's exception. They resize a sub-rectangle of the
    // source, which v2 does expose - through the extended STBIR_RESIZE object rather than a
    // single call - so they are implemented properly here rather than left out.
    // ========================================================================================

    private static ByteBuffer copyOf(float[] a) {
        ByteBuffer b = MemoryUtil.memAlloc(a.length * 4);
        b.asFloatBuffer().put(a);
        return b;
    }

    private static ByteBuffer copyOf(short[] a) {
        ByteBuffer b = MemoryUtil.memAlloc(a.length * 2);
        b.asShortBuffer().put(a);
        return b;
    }

    /** Resizes a sub-rectangle of the source, given as fractions of its width and height. */
    private static int resizeSubrect(long input_pixels, int input_w, int input_h, int input_stride_in_bytes,
                                     long output_pixels, int output_w, int output_h, int output_stride_in_bytes,
                                     int datatype, int num_channels, int alpha_channel, int flags,
                                     int edge_h, int edge_v, int filter_h, int filter_v, int space,
                                     float s0, float t0, float s1, float t1) {
        STBIR_RESIZE resize = STBIR_RESIZE.calloc();
        try {
            nstbir_resize_init(resize.address(), input_pixels, input_w, input_h, input_stride_in_bytes,
                               output_pixels, output_w, output_h, output_stride_in_bytes,
                               v1PixelLayout(num_channels, alpha_channel, flags),
                               v1DataTypeFull(datatype, space));
            nstbir_set_edgemodes(resize.address(), v1EdgeMode(edge_h), v1EdgeMode(edge_v));
            nstbir_set_filters(resize.address(), v1Filter(filter_h), v1Filter(filter_v));
            nstbir_set_input_subrect(resize.address(), s0, t0, s1, t1);
            return nstbir_resize_extended(resize.address());
        } finally {
            resize.free();
        }
    }

    // --- region: the sub-rectangle given directly ------------------------------------------

    public static int nstbir_resize_region(long input_pixels, int input_w, int input_h, int input_stride_in_bytes,
            long output_pixels, int output_w, int output_h, int output_stride_in_bytes,
            int datatype, int num_channels, int alpha_channel, int flags,
            int edge_mode_horizontal, int edge_mode_vertical,
            int filter_horizontal, int filter_vertical, int space, long alloc_context,
            float s0, float t0, float s1, float t1) {
        return resizeSubrect(input_pixels, input_w, input_h, input_stride_in_bytes,
                             output_pixels, output_w, output_h, output_stride_in_bytes,
                             datatype, num_channels, alpha_channel, flags,
                             edge_mode_horizontal, edge_mode_vertical,
                             filter_horizontal, filter_vertical, space, s0, t0, s1, t1);
    }

    public static boolean stbir_resize_region(ByteBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes,
            ByteBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes,
            int datatype, int num_channels, int alpha_channel, int flags,
            int edge_mode_horizontal, int edge_mode_vertical,
            int filter_horizontal, int filter_vertical, int space,
            float s0, float t0, float s1, float t1) {
        return stbir_resize_region(input_pixels, input_w, input_h, input_stride_in_bytes,
                output_pixels, output_w, output_h, output_stride_in_bytes, datatype, num_channels,
                alpha_channel, flags, edge_mode_horizontal, edge_mode_vertical,
                filter_horizontal, filter_vertical, space, 0L, s0, t0, s1, t1);
    }

    public static boolean stbir_resize_region(ByteBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes,
            ByteBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes,
            int datatype, int num_channels, int alpha_channel, int flags,
            int edge_mode_horizontal, int edge_mode_vertical,
            int filter_horizontal, int filter_vertical, int space, long alloc_context,
            float s0, float t0, float s1, float t1) {
        return nstbir_resize_region(MemoryUtil.memAddress(input_pixels), input_w, input_h, input_stride_in_bytes,
                MemoryUtil.memAddressSafe(output_pixels), output_w, output_h, output_stride_in_bytes,
                datatype, num_channels, alpha_channel, flags, edge_mode_horizontal, edge_mode_vertical,
                filter_horizontal, filter_vertical, space, alloc_context, s0, t0, s1, t1) != 0;
    }

    // --- subpixel: a scale and an offset, converted into the same sub-rectangle -------------
    //
    // v1 described the source window as how much to scale by and where to start. The window that
    // describes is the output size divided by the scale, beginning at the offset, which is the
    // rectangle below once expressed as fractions of the source.

    public static int nstbir_resize_subpixel(long input_pixels, int input_w, int input_h, int input_stride_in_bytes,
            long output_pixels, int output_w, int output_h, int output_stride_in_bytes,
            int datatype, int num_channels, int alpha_channel, int flags,
            int edge_mode_horizontal, int edge_mode_vertical,
            int filter_horizontal, int filter_vertical, int space, long alloc_context,
            float x_scale, float y_scale, float x_offset, float y_offset) {
        if (x_scale == 0.0f || y_scale == 0.0f || input_w == 0 || input_h == 0) return 0;
        float s0 = (x_offset / x_scale) / input_w;
        float t0 = (y_offset / y_scale) / input_h;
        float s1 = s0 + (output_w / x_scale) / input_w;
        float t1 = t0 + (output_h / y_scale) / input_h;
        return resizeSubrect(input_pixels, input_w, input_h, input_stride_in_bytes,
                             output_pixels, output_w, output_h, output_stride_in_bytes,
                             datatype, num_channels, alpha_channel, flags,
                             edge_mode_horizontal, edge_mode_vertical,
                             filter_horizontal, filter_vertical, space, s0, t0, s1, t1);
    }

    public static boolean stbir_resize_subpixel(ByteBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes,
            ByteBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes,
            int datatype, int num_channels, int alpha_channel, int flags,
            int edge_mode_horizontal, int edge_mode_vertical,
            int filter_horizontal, int filter_vertical, int space,
            float x_scale, float y_scale, float x_offset, float y_offset) {
        return stbir_resize_subpixel(input_pixels, input_w, input_h, input_stride_in_bytes,
                output_pixels, output_w, output_h, output_stride_in_bytes, datatype, num_channels,
                alpha_channel, flags, edge_mode_horizontal, edge_mode_vertical,
                filter_horizontal, filter_vertical, space, 0L, x_scale, y_scale, x_offset, y_offset);
    }

    public static boolean stbir_resize_subpixel(ByteBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes,
            ByteBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes,
            int datatype, int num_channels, int alpha_channel, int flags,
            int edge_mode_horizontal, int edge_mode_vertical,
            int filter_horizontal, int filter_vertical, int space, long alloc_context,
            float x_scale, float y_scale, float x_offset, float y_offset) {
        return nstbir_resize_subpixel(MemoryUtil.memAddress(input_pixels), input_w, input_h, input_stride_in_bytes,
                MemoryUtil.memAddressSafe(output_pixels), output_w, output_h, output_stride_in_bytes,
                datatype, num_channels, alpha_channel, flags, edge_mode_horizontal, edge_mode_vertical,
                filter_horizontal, filter_vertical, space, alloc_context, x_scale, y_scale, x_offset, y_offset) != 0;
    }

    // --- the allocator-context form of the full resize ------------------------------------

    public static boolean stbir_resize(ByteBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes,
            ByteBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes,
            int datatype, int num_channels, int alpha_channel, int flags,
            int edge_mode_horizontal, int edge_mode_vertical,
            int filter_horizontal, int filter_vertical, int space, long alloc_context) {
        return stbir_resize(input_pixels, input_w, input_h, input_stride_in_bytes,
                output_pixels, output_w, output_h, output_stride_in_bytes, datatype, num_channels,
                alpha_channel, flags, edge_mode_horizontal, edge_mode_vertical,
                filter_horizontal, filter_vertical, space);
    }

    public static boolean stbir_resize_uint8_generic(ByteBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes,
            ByteBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes,
            int num_channels, int alpha_channel, int flags,
            int edge_wrap_mode, int filter, int space, long alloc_context) {
        return stbir_resize_uint8_generic(input_pixels, input_w, input_h, input_stride_in_bytes,
                output_pixels, output_w, output_h, output_stride_in_bytes,
                num_channels, alpha_channel, flags, edge_wrap_mode, filter, space);
    }

    // --- float and 16-bit forms, including the plain-array versions -------------------------

    public static int nstbir_resize_float(float[] input_pixels, int input_w, int input_h, int input_stride_in_bytes,
            float[] output_pixels, int output_w, int output_h, int output_stride_in_bytes, int num_channels) {
        ByteBuffer in = copyOf(input_pixels), out = MemoryUtil.memAlloc(output_pixels.length * 4);
        try {
            int r = nstbir_resize_float(MemoryUtil.memAddress(in), input_w, input_h, input_stride_in_bytes,
                    MemoryUtil.memAddress(out), output_w, output_h, output_stride_in_bytes, num_channels);
            out.asFloatBuffer().get(output_pixels);
            return r;
        } finally {
            MemoryUtil.memFree(in);
            MemoryUtil.memFree(out);
        }
    }

    public static boolean stbir_resize_float(float[] input_pixels, int input_w, int input_h, int input_stride_in_bytes,
            float[] output_pixels, int output_w, int output_h, int output_stride_in_bytes, int num_channels) {
        return nstbir_resize_float(input_pixels, input_w, input_h, input_stride_in_bytes,
                output_pixels, output_w, output_h, output_stride_in_bytes, num_channels) != 0;
    }

    public static int nstbir_resize_float_generic(float[] input_pixels, int input_w, int input_h, int input_stride_in_bytes,
            float[] output_pixels, int output_w, int output_h, int output_stride_in_bytes,
            int num_channels, int alpha_channel, int flags,
            int edge_wrap_mode, int filter, int space, long alloc_context) {
        ByteBuffer in = copyOf(input_pixels), out = MemoryUtil.memAlloc(output_pixels.length * 4);
        try {
            int r = nstbir_resize_float_generic(MemoryUtil.memAddress(in), input_w, input_h, input_stride_in_bytes,
                    MemoryUtil.memAddress(out), output_w, output_h, output_stride_in_bytes,
                    num_channels, alpha_channel, flags, edge_wrap_mode, filter, space, alloc_context);
            out.asFloatBuffer().get(output_pixels);
            return r;
        } finally {
            MemoryUtil.memFree(in);
            MemoryUtil.memFree(out);
        }
    }

    public static boolean stbir_resize_float_generic(float[] input_pixels, int input_w, int input_h, int input_stride_in_bytes,
            float[] output_pixels, int output_w, int output_h, int output_stride_in_bytes,
            int num_channels, int alpha_channel, int flags, int edge_wrap_mode, int filter, int space) {
        return nstbir_resize_float_generic(input_pixels, input_w, input_h, input_stride_in_bytes,
                output_pixels, output_w, output_h, output_stride_in_bytes,
                num_channels, alpha_channel, flags, edge_wrap_mode, filter, space, 0L) != 0;
    }

    public static boolean stbir_resize_float_generic(float[] input_pixels, int input_w, int input_h, int input_stride_in_bytes,
            float[] output_pixels, int output_w, int output_h, int output_stride_in_bytes,
            int num_channels, int alpha_channel, int flags, int edge_wrap_mode, int filter, int space, long alloc_context) {
        return nstbir_resize_float_generic(input_pixels, input_w, input_h, input_stride_in_bytes,
                output_pixels, output_w, output_h, output_stride_in_bytes,
                num_channels, alpha_channel, flags, edge_wrap_mode, filter, space, alloc_context) != 0;
    }

    public static boolean stbir_resize_float_generic(FloatBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes,
            FloatBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes,
            int num_channels, int alpha_channel, int flags, int edge_wrap_mode, int filter, int space, long alloc_context) {
        return stbir_resize_float_generic(input_pixels, input_w, input_h, input_stride_in_bytes,
                output_pixels, output_w, output_h, output_stride_in_bytes,
                num_channels, alpha_channel, flags, edge_wrap_mode, filter, space);
    }

    public static int nstbir_resize_uint16_generic(short[] input_pixels, int input_w, int input_h, int input_stride_in_bytes,
            short[] output_pixels, int output_w, int output_h, int output_stride_in_bytes,
            int num_channels, int alpha_channel, int flags,
            int edge_wrap_mode, int filter, int space, long alloc_context) {
        ByteBuffer in = copyOf(input_pixels), out = MemoryUtil.memAlloc(output_pixels.length * 2);
        try {
            int r = nstbir_resize_uint16_generic(MemoryUtil.memAddress(in), input_w, input_h, input_stride_in_bytes,
                    MemoryUtil.memAddress(out), output_w, output_h, output_stride_in_bytes,
                    num_channels, alpha_channel, flags, edge_wrap_mode, filter, space, alloc_context);
            out.asShortBuffer().get(output_pixels);
            return r;
        } finally {
            MemoryUtil.memFree(in);
            MemoryUtil.memFree(out);
        }
    }

    public static boolean stbir_resize_uint16_generic(short[] input_pixels, int input_w, int input_h, int input_stride_in_bytes,
            short[] output_pixels, int output_w, int output_h, int output_stride_in_bytes,
            int num_channels, int alpha_channel, int flags, int edge_wrap_mode, int filter, int space) {
        return nstbir_resize_uint16_generic(input_pixels, input_w, input_h, input_stride_in_bytes,
                output_pixels, output_w, output_h, output_stride_in_bytes,
                num_channels, alpha_channel, flags, edge_wrap_mode, filter, space, 0L) != 0;
    }

    public static boolean stbir_resize_uint16_generic(short[] input_pixels, int input_w, int input_h, int input_stride_in_bytes,
            short[] output_pixels, int output_w, int output_h, int output_stride_in_bytes,
            int num_channels, int alpha_channel, int flags, int edge_wrap_mode, int filter, int space, long alloc_context) {
        return nstbir_resize_uint16_generic(input_pixels, input_w, input_h, input_stride_in_bytes,
                output_pixels, output_w, output_h, output_stride_in_bytes,
                num_channels, alpha_channel, flags, edge_wrap_mode, filter, space, alloc_context) != 0;
    }

    public static boolean stbir_resize_uint16_generic(ShortBuffer input_pixels, int input_w, int input_h, int input_stride_in_bytes,
            ShortBuffer output_pixels, int output_w, int output_h, int output_stride_in_bytes,
            int num_channels, int alpha_channel, int flags, int edge_wrap_mode, int filter, int space, long alloc_context) {
        return nstbir_resize_uint16_generic(MemoryUtil.memAddress(input_pixels), input_w, input_h, input_stride_in_bytes,
                MemoryUtil.memAddressSafe(output_pixels), output_w, output_h, output_stride_in_bytes,
                num_channels, alpha_channel, flags, edge_wrap_mode, filter, space, alloc_context) != 0;
    }
}
