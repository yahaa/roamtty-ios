#include "CNative.h"
#include <opus/opus.h>
#include <stdlib.h>

struct roam_opus_encoder {
    OpusEncoder *enc;
    int bitrate;
    int loss_perc;
};

struct roam_opus_decoder {
    OpusDecoder *dec;
};

roam_opus_encoder *roam_opus_encoder_create(int sample_rate, int bitrate, int enable_dtx) {
    int err = OPUS_OK;
    OpusEncoder *enc = opus_encoder_create(sample_rate, 1, OPUS_APPLICATION_VOIP, &err);
    if (!enc || err != OPUS_OK) {
        return NULL;
    }
    opus_encoder_ctl(enc, OPUS_SET_BITRATE(bitrate));
    opus_encoder_ctl(enc, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
    opus_encoder_ctl(enc, OPUS_SET_COMPLEXITY(5));
    opus_encoder_ctl(enc, OPUS_SET_INBAND_FEC(1));
    opus_encoder_ctl(enc, OPUS_SET_PACKET_LOSS_PERC(5));
    opus_encoder_ctl(enc, OPUS_SET_DTX(enable_dtx ? 1 : 0));

    roam_opus_encoder *w = (roam_opus_encoder *)calloc(1, sizeof(roam_opus_encoder));
    if (!w) {
        opus_encoder_destroy(enc);
        return NULL;
    }
    w->enc = enc;
    w->bitrate = bitrate;
    w->loss_perc = 5;
    return w;
}

void roam_opus_encoder_set_params(roam_opus_encoder *enc, int bitrate, int loss_perc) {
    if (!enc || !enc->enc) return;
    if (bitrate != enc->bitrate) {
        enc->bitrate = bitrate;
        opus_encoder_ctl(enc->enc, OPUS_SET_BITRATE(bitrate));
    }
    if (loss_perc < 0) loss_perc = 0;
    if (loss_perc > 100) loss_perc = 100;
    if (loss_perc != enc->loss_perc) {
        enc->loss_perc = loss_perc;
        opus_encoder_ctl(enc->enc, OPUS_SET_PACKET_LOSS_PERC(loss_perc));
    }
}

void roam_opus_encoder_reset(roam_opus_encoder *enc) {
    if (!enc || !enc->enc) return;
    opus_encoder_ctl(enc->enc, OPUS_RESET_STATE);
}

int roam_opus_encoder_encode(roam_opus_encoder *enc, const int16_t *pcm, int frame_samples, unsigned char *out, int out_cap) {
    if (!enc || !enc->enc || !pcm || !out || frame_samples <= 0 || out_cap <= 0) return -1;
    return opus_encode(enc->enc, pcm, frame_samples, out, out_cap);
}

void roam_opus_encoder_destroy(roam_opus_encoder *enc) {
    if (!enc) return;
    if (enc->enc) opus_encoder_destroy(enc->enc);
    free(enc);
}

roam_opus_decoder *roam_opus_decoder_create(int sample_rate) {
    int err = OPUS_OK;
    OpusDecoder *dec = opus_decoder_create(sample_rate, 1, &err);
    if (!dec || err != OPUS_OK) {
        return NULL;
    }
    roam_opus_decoder *w = (roam_opus_decoder *)calloc(1, sizeof(roam_opus_decoder));
    if (!w) {
        opus_decoder_destroy(dec);
        return NULL;
    }
    w->dec = dec;
    return w;
}

void roam_opus_decoder_reset(roam_opus_decoder *dec) {
    if (!dec || !dec->dec) return;
    opus_decoder_ctl(dec->dec, OPUS_RESET_STATE);
}

int roam_opus_decoder_decode(roam_opus_decoder *dec, const unsigned char *data, int len, int16_t *out, int frame_samples, int decode_fec) {
    if (!dec || !dec->dec || !out || frame_samples <= 0) return -1;
    return opus_decode(dec->dec, data, len, out, frame_samples, decode_fec ? 1 : 0);
}

void roam_opus_decoder_destroy(roam_opus_decoder *dec) {
    if (!dec) return;
    if (dec->dec) opus_decoder_destroy(dec->dec);
    free(dec);
}
