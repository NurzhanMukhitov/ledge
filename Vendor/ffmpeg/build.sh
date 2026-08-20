#!/bin/bash
# Минимальная LGPL-сборка: только то, чего не умеет macOS, плюс аппаратный кодировщик.
ARCH="$1"; PREFIX="$2"
./configure \
  --prefix="$PREFIX" \
  --disable-everything --disable-autodetect --disable-doc --disable-debug \
  --disable-network --disable-gpl --disable-nonfree --disable-shared --enable-static \
  --enable-small --disable-ffplay --disable-ffprobe \
  --enable-videotoolbox \
  --enable-protocol=file,pipe \
  --enable-demuxer=asf,matroska,webm_dash_manifest,flv,avi,mov,mp3,wav,aac,ogg,mpegts,mpegps \
  --enable-decoder=wmv1,wmv2,wmv3,vc1,msmpeg4v1,msmpeg4v2,msmpeg4v3,mpeg4,h264,hevc,mpeg2video,vp8,vp9,flv,wmav1,wmav2,wmapro,wmalossless,mp3,aac,ac3,vorbis,opus,pcm_s16le,pcm_s16be,pcm_u8,pcm_f32le,flac \
  --enable-encoder=h264_videotoolbox,aac,pcm_s16le,alac \
  --enable-muxer=mp4,mov,wav,ipod \
  --enable-parser=h264,hevc,vp8,vp9,mpeg4video,vc1,aac,mpegaudio,flac \
  --enable-bsf=extract_extradata,h264_mp4toannexb,aac_adtstoasc \
  --enable-filter=aresample,aformat,anull,null,scale,format \
  --enable-swresample --enable-swscale \
  --arch="$ARCH" --enable-cross-compile --target-os=darwin --disable-x86asm \
  --extra-cflags="-arch $ARCH -Os" --extra-ldflags="-arch $ARCH" \
  >/dev/null 2>&1
