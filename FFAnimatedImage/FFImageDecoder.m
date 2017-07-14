//
//  FFImageDecoder.m
//  FFAnimatedImageDemo
//
//  Created by yafengxn on 2017/7/12.
//  Copyright © 2017年 yafengxn. All rights reserved.
//

#import "FFImageDecoder.h"
#import <zlib.h>

/////////////////////////////////////////////////////////////////
#pragma mark - Utility (for little endian platform)

#define FF_FOUR_CC(c1,c2,c3,c4) ((uint32_t)(((c4) << 24) | ((c3) << 16) | ((c2) << 8) | (c1)))
#define FF_TWO_CC(c1,c2) ((uint16_t)(((c2) << 8) | (c1)))

static inline uint16_t ff_swap_endian_uint16(uint16_t value) {
    return
    (uint16_t) ((value & 0x00FF) << 8) |
    (uint16_t) ((value & 0xFF00) >> 8);
}

static inline uint32_t ff_swap_endian_uint32(uint32_t value) {
    return
    (uint32_t) ((value & 0x000000FFU) << 24) |
    (uint32_t) ((value & 0x0000FF00U) <<  8) |
    (uint32_t) ((value & 0x00FF0000U) >>  8) |
    (uint32_t) ((value & 0xFF000000U) >> 24);
}

/////////////////////////////////////////////////////////////////

typedef enum {
    FF_PNG_ALPHA_TYPE_PALEETE = 1 << 0,
    FF_PNG_ALPHA_TYPE_COLOR = 1 << 1,
    FF_PNG_ALPHA_TYPE_ALPHA = 1 << 2,
} ff_png_alpha_type;

typedef enum {
    FF_PNG_DISPOSE_OP_NONE = 0,
    FF_PNG_DISPOSE_OP_BACKGROUND = 1,
    FF_PNG_DISPOSE_OP_PREVIOUS = 2,
} ff_png_dispose_op;

typedef enum {
    FF_PNG_BLEND_OP_SOURCE = 0,
    FF_PNG_BLEND_OP_OVER = 1,
} ff_png_blend_op;

typedef struct {
    uint32_t width;             ///< pixel count, should not be zero
    uint32_t height;            ///< pixel count, should not be zero
    uint8_t bit_depth;          ///< expected: 1, 2, 4, 8, 16
    uint8_t color_type;         ///< see ff_png_alpha_type
    uint8_t compression_method; ///< 0 (deflate/inflate)
    uint8_t filter_method;      ///< 0 (adaptive filtering with five basic filter types)
    uint8_t interlace_method;   ///< 0 (no interlace) or 1 (Adam7 interlace)
} ff_png_chunk_IHDR;

typedef struct {
    uint32_t sequence_number;   ///< sequence number of the animation chunk, starting from 0
    uint32_t width;             ///< width of the following frame
    uint32_t height;            ///< height of the following frame
    uint32_t x_offset;          ///< x position at which to render the following frame
    uint32_t y_offset;          ///< y position at which to render the following frame
    uint16_t delay_num;         ///< frame delay fraction numberator
    uint16_t delay_den;         ///< frame delay fraction denominator
    uint8_t dispose_op;         ///< see ff_png_dispose_op
    uint8_t blend_op;           ///< see ff_png_dispose_op
} ff_png_chunk_fcTL;

typedef struct {
    uint32_t offset;    ///< chunk offset in PNG data
    uint32_t fourcc;    ///< chunk fourcc
    uint32_t length;    ///< data length
    uint32_t crc32;     ///< chunk crc32
} ff_png_chunk_info;

typedef struct {
    uint32_t chunk_index;   ///< the first 'fdAt'/'IDAT' chunk index
    uint32_t chunk_num;     ///< the first 'fdAt'/'IDAT' chunk count
    uint32_t chunk_size;    ///< the first 'fdAt'/'IDAT' chunk bytes
    ff_png_chunk_fcTL frame_control;
} ff_png_frame_info;

typedef struct {
    ff_png_chunk_IHDR header;   ///< png header
    ff_png_chunk_info *chunks;  ///< chunks
    uint32_t chunk_num;         ///< count of chunks
    
    ff_png_frame_info *apng_frames; ///< frame info, NULL if not apng
    uint32_t apng_frame_num;    ///< 0 if not apng
    uint32_t apng_loop_num;     ///0 indicates infinite looping
    
    uint32_t *apng_shared_chunk_indexs; ///< shared chunk index
    uint32_t apng_shared_chunk_num;     ///< shared chunk count
    uint32_t apng_shared_chunk_size;    ///< shared chunk bytes
    uint32_t apng_shared_insert_index;  ///< shared chunk insert index
    bool apng_first_frame_is_cover;     ///< the first frame is same as png (cover)
} ff_png_info;

static void ff_png_chunk_IHDR_read(ff_png_chunk_IHDR *IHDR, const uint8_t *data) {
    IHDR->width = ff_swap_endian_uint32(*((uint32_t *)(data)));
    IHDR->height = ff_swap_endian_uint32(*((uint32_t *)(data + 4)));
    IHDR->bit_depth = data[8];
    IHDR->color_type = data[9];
    IHDR->compression_method = data[10];
    IHDR->filter_method = data[11];
    IHDR->interlace_method = data[12];
}

static void ff_png_chunk_IHDR_write(ff_png_chunk_IHDR *IHDR, uint8_t *data) {
    *((uint32_t *)(data)) = ff_swap_endian_uint32(IHDR->width);
    *((uint32_t *)(data + 4)) = ff_swap_endian_uint32(IHDR->height);
    data[8] = IHDR->bit_depth;
    data[9] = IHDR->color_type;
    data[10] = IHDR->compression_method;
    data[11] = IHDR->filter_method;
    data[12] = IHDR->interlace_method;
}

static void ff_png_chunk_fcTL_read(ff_png_chunk_fcTL *fcTL, const uint8_t *data) {
    fcTL->sequence_number = ff_swap_endian_uint32(*((uint32_t *)(data)));
    fcTL->width = ff_swap_endian_uint32(*((uint32_t *)(data + 4)));
    fcTL->height = ff_swap_endian_uint32(*((uint32_t *)(data + 8)));
    fcTL->x_offset = ff_swap_endian_uint32(*((uint32_t *)(data + 12)));
    fcTL->y_offset = ff_swap_endian_uint32(*((uint32_t *)(data + 16)));
    fcTL->delay_num = ff_swap_endian_uint16(*((uint16_t *)(data + 20)));
    fcTL->delay_den = ff_swap_endian_uint16(*(uint16_t *)(data + 22));
    fcTL->dispose_op = data[24];
    fcTL->blend_op = data[25];
}

static void ff_png_chunk_fcTL_write(ff_png_chunk_fcTL *fcTL, uint8_t *data) {
    *((uint32_t *)(data)) = ff_swap_endian_uint32(fcTL->sequence_number);
    *((uint32_t *)(data + 4)) = ff_swap_endian_uint32(fcTL->width);
    *((uint32_t *)(data + 8)) = ff_swap_endian_uint32(fcTL->height);
    *((uint32_t *)(data + 12)) = ff_swap_endian_uint32(fcTL->x_offset);
    *((uint32_t *)(data + 16)) = ff_swap_endian_uint32(fcTL->y_offset);
    *((uint16_t *)(data + 20)) = ff_swap_endian_uint16(fcTL->delay_num);
    *((uint16_t *)(data + 22)) = ff_swap_endian_uint16(fcTL->delay_den);
    data[24] = fcTL->dispose_op;
    data[25] = fcTL->blend_op;
}

static void ff_png_delay_to_fraction(double duration, uint16_t *num, uint16_t *den) {
    if (duration >= 0xFF) {
        *num = 0xFF;
        *den = 1;
    } else if (duration <= 1.0 / (double)0xFF) {
        *num = 1;
        *den = 0xFF;
    } else {
        // Use continued fraction to calculate the num and den.
        long MAX = 10;
        double eps = (0.5 / (double)0xFF);
        long p[MAX], q[MAX], a[MAX], i, numl = 0, denl = 0;
        // The first tow convergents (and continued fraction)
        for (i = 2; i < MAX; i++) {
            a[i] = lrint(floor(duration));
            p[i] = a[i] * p[i - 1] + p[i - 2];
            q[i] = a[i] * p[i - 1] + q[i - 2];
            if (p[i] <= 0xFF && q[i] <= 0xFF) { // uint16_t
                numl = p[i];
                denl = q[i];
            } else break;
            if (fabs(duration - a[i]) < eps) break;
            duration = 1.0 / (duration - a[i]);
        }
        
        if (numl != 0 && denl != 0) {
            *num = numl;
            *den = denl;
        } else {
            *num = 1;
            *den = 100;
        }
    }
}

// convert fraction to double value
static double ff_png_dealy_to_seconds(uint16_t num, uint16_t den) {
    if (den == 0) {
        return num / 100.0;
    } else {
        return  (double)num / (double)den;
    }
}

static bool ff_png_validate_animation_chunk_order(ff_png_chunk_info *chunks,    /* input */
                                                  uint32_t chunk_num,           /* input */
                                                  uint32_t *first_idat_index,   /* output */
                                                  bool *first_frame_is_cover    /* output */) {
    /*
     PNG at least contains 3 chunks: IHDR, IDAT, IEND.
     `IHDR` must appear first.
     `IDAT` must appear consecutively.
     `IEND` must appear end.
     
     APNG must contains one `acTL` and at least one 'fcTL' and `fdAT`.
     `fdAT` must appear consecutively.
     `fcTL` must appear before `IDAT` or `fdAT`.
     */
    if (chunk_num <= 2) return false;
    if (chunks->fourcc != FF_FOUR_CC('I', 'H', 'D', 'R')) return false;
    if ((chunks + chunk_num - 1)->fourcc != FF_FOUR_CC('I', 'E', 'N', 'D')) return false;
        
    uint32_t prev_fourcc = 0;
    uint32_t IHDR_num = 0;
    uint32_t IDAT_num = 0;
    uint32_t acTL_num = 0;
    uint32_t fcTL_num = 0;
    uint32_t first_IDAT = 0;
    bool first_frame_cover = false;
    for (uint32_t i = 0; i < chunk_num; i++) {
        ff_png_chunk_info *chunk = chunks + i;
        switch (chunk->fourcc) {
            case FF_FOUR_CC('I', 'H', 'D', 'R'): {  // png header
                if (i != 0) return false;
                if (IHDR_num > 0)   return false;
                IHDR_num++;
            } break;
            case FF_FOUR_CC('I', 'D', 'A', 'T'): {  // png data
                if (prev_fourcc != FF_FOUR_CC('I', 'D', 'H', 'T')) {
                    if (IDAT_num == 0)
                        first_IDAT = i;
                    else
                        return false;
                }
            } break;
            case FF_FOUR_CC('a', 'c', 'T', 'L'): {  // apng control
                if (acTL_num > 0) return false;
                acTL_num++;
            } break;
            case FF_FOUR_CC('f', 'c', 'T', 'L'): {  // apng frame control
                if (i + 1 == chunk_num) return false;
                if ((chunk + 1)->fourcc != FF_FOUR_CC('f', 'd', 'A', 'T') &&
                    (chunk + 1)->fourcc != FF_FOUR_CC('I', 'D', 'A', 'T')) {
                    return false;
                }
                if (fcTL_num == 0) {
                    if ((chunk + 1)->fourcc == FF_FOUR_CC('I', 'D', 'A', 'T')) {
                        first_frame_cover = true;
                    }
                }
                fcTL_num++;
            } break;
            case FF_FOUR_CC('f', 'd', 'A', 'T'): {  // apng data
                if (prev_fourcc != FF_FOUR_CC('f', 'd', 'A', 'T') && prev_fourcc != FF_FOUR_CC('f', 'c', 'T', 'L')) {
                    return false;
                }
            } break;
        }
        prev_fourcc = chunk->fourcc;
    }
    if (IHDR_num != 1) return false;
    if (IDAT_num == 0) return false;
    if (acTL_num != 1) return false;
    if (fcTL_num < acTL_num) return false;
    *first_idat_index = first_IDAT;
    *first_frame_is_cover = first_frame_cover;
    return true;
}

static void ff_png_info_realease(ff_png_info *info) {
    if (info) {
        if (info->chunks) free(info->chunks);
        if (info->apng_frames) free(info->apng_frames);
        if (info->apng_shared_chunk_indexs) free(info->apng_shared_chunk_indexs);
        free(info);
    }
}

static ff_png_info *ff_png_info_create(const uint8_t *data, uint32_t length) {
    if (length < 32) return NULL;
    if (*((uint32_t *)data) != FF_FOUR_CC(0x89, 0x50, 0x4E, 0x47)) return NULL;
    if (*((uint32_t *)(data + 4)) != FF_FOUR_CC(0x0D, 0x0A, 0x1A, 0x0A)) return NULL;
    
    uint32_t chunk_realloc_num = 16;
    ff_png_chunk_info *chunks = malloc(sizeof(ff_png_chunk_info) * chunk_realloc_num);
    if (!chunks) return NULL;
    
    // parse png chunks
    uint32_t offset = 8;
    uint32_t chunk_num = 0;
    uint32_t chunk_capacity = chunk_realloc_num;
    uint32_t apng_loop_num = 0;
    int32_t apng_sequence_index = -1;
    int32_t apng_frame_index = 0;
    int32_t apng_frame_number = -1;
    bool apng_chunk_error = false;
    do {
        if (chunk_num >= chunk_capacity) {
            ff_png_chunk_info *new_chunks = realloc(chunks, sizeof(ff_png_chunk_info) * (chunk_capacity + chunk_realloc_num));
            if (!new_chunks) {
                free(chunks);
                return NULL;
            }
            chunks = new_chunks;
            chunk_capacity += chunk_realloc_num;
        }
        ff_png_chunk_info *chunk = chunks + chunk_num;
        const uint8_t *chunk_data = data + offset;
        chunk->offset = offset;
        chunk->length = ff_swap_endian_uint32(*((uint32_t *)chunk_data));
        if ((uint64_t)chunk->offset + (uint64_t)chunk->length + 12 > length) {
            free(chunks);
            return NULL;
        }
        
        chunk->fourcc = *((uint32_t *)(chunk_data + 4));
        if ((uint64_t)chunk->offset + 4 + chunk->length + 4 > (uint64_t)length) break;
        chunk->crc32 = ff_swap_endian_uint32(*((uint32_t *)(chunk_data + 8 + chunk->length)));
        chunk_num++;
        offset += 12 + chunk->length;
        
        switch (chunk->fourcc) {
            case FF_FOUR_CC('a', 'c', 'T', 'L'): {
                if (chunk->length == 8) {
                    apng_frame_number = ff_swap_endian_uint32(*((uint32_t *)(chunk_data + 8)));
                    apng_loop_num = ff_swap_endian_uint32(*((uint32_t *)(chunk_data + 12)));
                } else {
                    apng_chunk_error = true;
                }
            }break;
            case FF_FOUR_CC('f', 'c', 'T', 'L'):
            case FF_FOUR_CC('f', 'd', 'A', 'T'): {
                if (chunk->fourcc == FF_FOUR_CC('f', 'c', 'T', 'L')) {
                    if (chunk->length != 26) {
                        apng_chunk_error = true;
                    } else {
                        apng_frame_index++;
                    }
                }
                if (chunk->length > 4) {
                    uint32_t sequence = ff_swap_endian_uint32(*((uint32_t *)(chunk_data + 8)));
                    if (apng_sequence_index + 1 == sequence) {
                        apng_frame_index++;
                    } else {
                        apng_chunk_error = true;
                    }
                } else {
                    apng_chunk_error = true;
                }
            } break;
            case FF_FOUR_CC('I', 'E', 'N', 'D'): {
                offset = length;    // end, break do-while loop
            } break;
        }
    } while (offset + 12 <= length);
    
    if (chunk_num < 3 ||
        chunks->fourcc != FF_FOUR_CC('I', 'H', 'D', 'R') ||
        chunks->length != 13) {
        free(chunks);
        return NULL;
    }
    
    // png info
    ff_png_info *info = calloc(1, sizeof(ff_png_info));
    if (!info) {
        free(chunks);
        return NULL;
    }
    info->chunks = chunks;
    info->chunk_num = chunk_num;
    ff_png_chunk_IHDR_read(&info->header, data + chunks->offset + 8);
    
    // apng info
    if (!apng_chunk_error && apng_frame_number == apng_frame_index && apng_frame_number >= 1) {
        bool first_frame_is_cover = false;
        uint32_t first_IDAT_index = 0;
        if (!ff_png_validate_animation_chunk_order(info->chunks, info->chunk_num, &first_IDAT_index, &first_frame_is_cover)) {
            return info;    // ignore apng chunk
        }
        
        info->apng_loop_num = apng_loop_num;
        info->apng_frame_num = apng_frame_number;
        info->apng_first_frame_is_cover = first_frame_is_cover;
        info->apng_shared_insert_index = first_IDAT_index;
        info->apng_frames = calloc(apng_frame_number, sizeof(ff_png_frame_info));
        if (!info->apng_frames) {
            ff_png_info_realease(info);
            return NULL;
        }
        info->apng_shared_chunk_indexs = calloc(info->chunk_num, sizeof(uint32_t));
        if (!info->apng_shared_chunk_indexs) {
            ff_png_info_realease(info);
            return NULL;
        }
        
        int32_t frame_index = -1;
        uint32_t *shared_chunk_index = info->apng_shared_chunk_indexs;
        for (int32_t i = 0; i < info->chunk_num; i++) {
            ff_png_chunk_info *chunk = info->chunks + i;
            switch (chunk->fourcc) {
                case FF_FOUR_CC('I', 'D', 'A', 'T'): {
                    if (info->apng_shared_insert_index == 0) {
                        info->apng_shared_insert_index = i;
                    }
                    if (first_frame_is_cover) {
                        ff_png_frame_info *frame = info->apng_frames + frame_index;
                        frame->chunk_num++;
                        frame->chunk_size += chunk->length + 12;
                    }
                } break;
                case FF_FOUR_CC('a', 'c', 'T', 'L'): {
                } break;
                case FF_FOUR_CC('f', 'c', 'T', 'L'): {
                    frame_index++;
                    ff_png_frame_info *frame = info->apng_frames + frame_index;
                    frame->chunk_index = i + 1;
                    ff_png_chunk_fcTL_read(&frame->frame_control, data + chunk->offset + 8);
                } break;
                case FF_FOUR_CC('f', 'd', 'A', 'T'): {
                    ff_png_frame_info *frame = info->apng_frames + frame_index;
                    frame->chunk_num++;
                    frame->chunk_size += chunk->length + 12;
                } break;
                default: {
                    *shared_chunk_index = i;
                    shared_chunk_index++;
                    info->apng_shared_chunk_size += chunk->length + 12;
                    info->apng_shared_chunk_num++;
                } break;
            }
        }
    }
    return info;
}

static uint8_t *ff_png_copy_frame_data_at_index(const uint8_t *data,
                                                const ff_png_info *info,
                                                const uint32_t index,
                                                uint32_t *size) {
    if (index >= info->apng_frame_num) return NULL;
    
    ff_png_frame_info *frame_info =info->apng_frames + index;
    uint32_t frame_remux_size = 8 /* PNG Header */ + info->apng_shared_chunk_size + frame_info->chunk_size;
    if (!(info->apng_first_frame_is_cover && index == 0)) {
        frame_remux_size -= frame_info->chunk_num * 4;  // remove fdAT sequence number
    }
    uint8_t *frame_data = malloc(frame_remux_size);
    if(!frame_data) return NULL;
    *size = frame_remux_size;
    
    uint32_t data_offset = 0;
    bool inserted = false;
    memcpy(frame_data, data, 8);    // PNG File Header
    data_offset += 8;
    for (uint32_t i = 0; i < info->apng_shared_chunk_num; i++) {
        uint32_t shared_chunk_index = info->apng_shared_chunk_indexs[i];
        ff_png_chunk_info *shared_chunk_info = info->chunks + shared_chunk_index;
        
        if (shared_chunk_index >= info->apng_shared_insert_index  && !inserted) { // replace IDAT with fdAT
            inserted = true;
            for (uint32_t c = 0; c < frame_info->chunk_num; c++) {
                ff_png_chunk_info *insert_chunk_info  =info->chunks + frame_info->chunk_index + c;
                if (insert_chunk_info->fourcc == FF_FOUR_CC('f', 'd', 'A', 'T')) {
                    *((uint32_t *)(frame_data + data_offset)) = ff_swap_endian_uint32(insert_chunk_info->length - 4);
                    *((uint32_t *)(frame_data + data_offset + 4)) = FF_FOUR_CC('I', 'D', 'A', 'T');
                    memcpy(frame_data + data_offset + 8, data + insert_chunk_info->offset + 12, insert_chunk_info->length - 4);
                    uint32_t crc = (uint32_t)crc32(0, frame_data + data_offset + 4, insert_chunk_info->length);
                    *((uint32_t *)(frame_data + data_offset + insert_chunk_info->length + 4)) = ff_swap_endian_uint32(crc);
                    data_offset += insert_chunk_info->length + 8;
                } else {  // IDAT
                    memcpy(frame_data, data + insert_chunk_info->offset, insert_chunk_info->length + 12);
                    data_offset += insert_chunk_info->length + 12;
                }
            }
        }
        
        if (shared_chunk_info->fourcc == FF_FOUR_CC('I', 'H', 'D', 'R')) {
            uint8_t tmp[25] = {0};
            memcpy(tmp, data + shared_chunk_info->offset, 25);
            ff_png_chunk_IHDR IHDR = info->header;
            IHDR.width = frame_info->frame_control.width;
            IHDR.height = frame_info->frame_control.height;
            ff_png_chunk_IHDR_write(&IHDR, tmp + 8);
            *((uint32_t *)(tmp + 21)) = ff_swap_endian_uint32((uint32_t)crc32(0, tmp, 17));
            memcpy(frame_data + data_offset, tmp, 25);
            data_offset += 25;
        } else {
            memcpy(frame_data + data_offset, data + shared_chunk_info->offset, shared_chunk_info->length + 12);
            data_offset += shared_chunk_info->length + 12;
        }
    }
    return frame_data;
}

/////////////////////////////////////////////////////////////////////////////


@implementation FFImageDecoder

@end
