#!/bin/bash

. ./cmd.sh
. ./path.sh

# You may set 'mic' to:
#  ihm [individual headset mic- the default which gives best results]
#  sdmN [single distant microphone- the current script allows you to select
#        any of 4 PZM microphones, D1...D4 in a diagram, best results are with D2]
#  mdm4 [multiple distant microphones-- currently we only support averaging over
#       the 2,3 or 4 single microphones].
# ... by calling this script as, for example,
# ./run.sh --mic ihm  (will build ihm systems from individual headset mics)
# ./run.sh --mic sdm4 (will build sdm systems from D2 mic - look ../README.txt if confused)
# ./run.sh --mic mdm4 (will build mdm systems from D1...D4 mics)
mic=ihm

# Train systems,
nj=30 # number of parallel jobs,
stage=0
. utils/parse_options.sh

base_mic=$(echo $mic | sed 's/[0-9]//g') # sdm, ihm or mdm
nmics=$(echo $mic | sed 's/[a-z]//g') # e.g. 8 for mdm8.

set -euo pipefail

SAFE_T_AUDIO_R20=/export/corpora5/opensat_corpora/LDC2020E10
SAFE_T_TEXTS_R20=/export/corpora5/opensat_corpora/LDC2020E09
SAFE_T_AUDIO_R11=/export/corpora5/opensat_corpora/LDC2019E37
SAFE_T_TEXTS_R11=/export/corpora5/opensat_corpora/LDC2019E36
SAFE_T_AUDIO_DEV1=/export/corpora5/opensat_corpora/LDC2019E53
SAFE_T_TEXTS_DEV1=/export/corpora5/opensat_corpora/LDC2019E53
SAFE_T_AUDIO_EVAL1=/export/corpora5/opensat_corpora/LDC2020E07
ICSI_TRANS=/export/corpora3/LDC/LDC2004T04/icsi_mr_transcr
ICSI_DIR=/export/corpora5/LDC/LDC2004S02/meeting_speech/speech
PROCESSED_ICSI_DIR=$ICSI_DIR
if [ $stage -le 0 ]; then
  local/safet_data_prep.sh ${SAFE_T_AUDIO_R11} ${SAFE_T_TEXTS_R11} data/safe_t_r11
  local/safet_data_prep.sh ${SAFE_T_AUDIO_R20} ${SAFE_T_TEXTS_R20} data/safe_t_r20
  local/safet_data_prep.sh ${SAFE_T_AUDIO_DEV1} ${SAFE_T_TEXTS_DEV1} data/safe_t_dev1
  local/safet_data_prep.sh ${SAFE_T_AUDIO_EVAL1} data/safe_t_eval1
fi

if [ $stage -le 1 ]; then
  rm -rf data/lang_nosp data/local/lang_nosp data/local/dict_nosp
  local/safet_get_cmu_dict.sh
  utils/prepare_lang.sh data/local/dict_nosp '<UNK>' data/local/lang_nosp data/lang_nosp
  utils/validate_lang.pl data/lang_nosp
fi

if [ $stage -le 2 ]; then
  #prepare annotations, note: dict is assumed to exist when this is called
  local/icsi_text_prep.sh $ICSI_TRANS data/local/annotations
  local/icsi_${base_mic}_data_prep.sh $PROCESSED_ICSI_DIR $mic
  local/icsi_${base_mic}_scoring_data_prep.sh $PROCESSED_ICSI_DIR $mic dev
  local/icsi_${base_mic}_scoring_data_prep.sh $PROCESSED_ICSI_DIR $mic eval
fi

if [ $stage -le 3 ]; then
  for dset in train dev eval; do
    # this splits up the speakers (which for sdm and mdm just correspond
    # to recordings) into 30-second chunks.  It's like a very brain-dead form
    # of diarization; we can later replace it with 'real' diarization.
    seconds_per_spk_max=30
    [ "$mic" == "ihm" ] && seconds_per_spk_max=120  # speaker info for ihm is real,
                                                    # so organize into much bigger chunks.

    # Note: the 30 on the next line should have been $seconds_per_spk_max
    # (thanks: Pavel Denisov.  This is a bug but before fixing it we'd have to
    # test the WER impact.  I suspect it will be quite small and maybe hard to
    # measure consistently.
    utils/data/modify_speaker_info.sh --seconds-per-spk-max 30 \
      data/$mic/${dset}_orig data/$mic/$dset
  done
fi

if [ $stage -le 4 ]; then
  for dset in train dev eval; do
    cat data/$mic/$dset/text | awk '{printf $1""FS;for(i=2; i<=NF; ++i) printf "%s",tolower($i)""FS; print""}'  > data/$mic/$dset/texttmp
    mv data/$mic/$dset/text data/$mic/$dset/textupper
    mv data/$mic/$dset/texttmp data/$mic/$dset/text
  done
fi

if [ $stage -le 5 ]; then
  mkdir -p exp/cleanup_stage_1
  (
    local/safet_cleanup_transcripts.py data/local/lexicon.txt data/safe_t_r11/transcripts data/safe_t_r11/transcripts.clean
    local/safet_cleanup_transcripts.py data/local/lexicon.txt data/safe_t_r20/transcripts data/safe_t_r20/transcripts.clean
  ) | sort > exp/cleanup_stage_1/oovs

  local/safet_cleanup_transcripts.py --no-unk-replace  data/local/lexicon.txt \
    data/safe_t_dev1/transcripts data/safe_t_dev1/transcripts.clean > exp/cleanup_stage_1/oovs.dev1
  local/safet_build_data_dir.sh data/safe_t_r11/ data/safe_t_r11/transcripts.clean
  local/safet_build_data_dir.sh data/safe_t_r20/ data/safe_t_r20/transcripts.clean
  local/safet_build_data_dir.sh data/safe_t_dev1/ data/safe_t_dev1/transcripts
fi

if [ $stage -le 6 ] ; then
  utils/data/combine_data.sh data/train data/safe_t_r20 data/safe_t_r11
  local/safet_train_lms_srilm.sh \
    --train_text data/train/text --dev_text data/safe_t_dev1/text  \
    data/ data/local/srilm

  utils/format_lm.sh  data/lang_nosp/ data/local/srilm/lm.gz\
    data/local/lexicon.txt  data/lang_nosp_test
fi

if [ $stage -le 7 ]; then
  echo "$0: preparing directory for low-resolution speed-perturbed data (for alignment)"
  utils/data/perturb_data_dir_speed_3way.sh data/train data/train_sp
fi

exit

if [ $stage -le 4 ] ; then
  utils/data/combine_data.sh data/$mic/train /export/c02/aarora8/kaldi2/egs/opensat2020/s5b_aug/data/train_cleaned_sp \ 
       /export/c02/aarora8/kaldi/egs/ami/s5b/data/ihm/train /export/c02/aarora8/kaldi/egs/icsi/s5/data/ihm/train_icsi
fi

# Feature extraction,
if [ $stage -le 4 ]; then
  for dset in train dev eval; do
    steps/make_mfcc.sh --nj 15 --cmd "$train_cmd" data/$mic/$dset
    steps/compute_cmvn_stats.sh data/$mic/$dset
    utils/fix_data_dir.sh data/$mic/$dset
  done
fi

# monophone training
if [ $stage -le 5 ]; then
  # Full set 77h, reduced set 10.8h,
  utils/subset_data_dir.sh data/$mic/train 15000 data/$mic/train_15k

  steps/train_mono.sh --nj $nj --cmd "$train_cmd" \
    data/$mic/train_15k data/lang exp/$mic/mono
  steps/align_si.sh --nj $nj --cmd "$train_cmd" \
    data/$mic/train data/lang exp/$mic/mono exp/$mic/mono_ali
fi

# context-dep. training with delta features.
if [ $stage -le 6 ]; then
  steps/train_deltas.sh --cmd "$train_cmd" \
    5000 80000 data/$mic/train data/lang exp/$mic/mono_ali exp/$mic/tri1
  steps/align_si.sh --nj $nj --cmd "$train_cmd" \
    data/$mic/train data/lang exp/$mic/tri1 exp/$mic/tri1_ali
fi

if [ $stage -le 7 ]; then
  # LDA_MLLT
  steps/train_lda_mllt.sh --cmd "$train_cmd" \
    --splice-opts "--left-context=3 --right-context=3" \
    5000 80000 data/$mic/train data/lang exp/$mic/tri1_ali exp/$mic/tri2
  steps/align_fmllr.sh --nj $nj --cmd "$train_cmd" \
    data/$mic/train data/lang exp/$mic/tri2 exp/$mic/tri2_ali
  # Decode
  graph_dir=exp/$mic/tri2/graph_${LM}
  $decode_cmd --mem 4G $graph_dir/mkgraph.log \
    utils/mkgraph.sh data/lang_${LM} exp/$mic/tri2 $graph_dir
  steps/decode.sh --nj $nj --cmd "$decode_cmd" --config conf/decode.conf \
    $graph_dir data/$mic/dev exp/$mic/tri2/decode_dev_${LM}
  steps/decode.sh --nj $nj --cmd "$decode_cmd" --config conf/decode.conf \
    $graph_dir data/$mic/eval exp/$mic/tri2/decode_eval_${LM}
fi


if [ $stage -le 8 ]; then
  # LDA+MLLT+SAT
  steps/train_sat.sh --cmd "$train_cmd" \
    5000 80000 data/$mic/train data/lang exp/$mic/tri2_ali exp/$mic/tri3
  steps/align_fmllr.sh --nj $nj --cmd "$train_cmd" \
    data/$mic/train data/lang exp/$mic/tri3 exp/$mic/tri3_ali
fi

if [ $stage -le 9 ]; then
  # Decode the fMLLR system.
  graph_dir=exp/$mic/tri3/graph_${LM}
  $decode_cmd --mem 4G $graph_dir/mkgraph.log \
    utils/mkgraph.sh data/lang_${LM} exp/$mic/tri3 $graph_dir
  steps/decode_fmllr.sh --nj $nj --cmd "$decode_cmd" --config conf/decode.conf \
    $graph_dir data/$mic/dev exp/$mic/tri3/decode_dev_${LM}
  steps/decode_fmllr.sh --nj $nj --cmd "$decode_cmd" --config conf/decode.conf \
    $graph_dir data/$mic/eval exp/$mic/tri3/decode_eval_${LM}
fi

if [ $stage -le 10 ]; then
  # The following script cleans the data and produces cleaned data
  # in data/$mic/train_cleaned, and a corresponding system
  # in exp/$mic/tri3_cleaned.  It also decodes.
  #
  # Note: local/run_cleanup_segmentation.sh defaults to using 50 jobs,
  # you can reduce it using the --nj option if you want.
  #local/run_cleanup_segmentation.sh --mic $mic
  echo "For ICSI we do not clean segmentations, as those are manual by default, so should be OK."
  #but perhaps running such experiment would make sense, for now I want to keep this recipe as
  #close to the baseline one as possibe
fi

train_set=train_icsiami
aug_list="noise_low noise_high clean"

if [ $stage -le 11 ]; then
  utils/data/get_reco2dur.sh data/ihm/${train_set}
  steps/data/augment_data_dir.py --utt-prefix "noise_low" --modify-spk-id "true" \
    --bg-snrs "85:80:75:70" --num-bg-noises "1" --bg-noise-dir "/export/c12/aarora8/OpenSAT/safet_noise_wavfile/" \
    data/$mic/${train_set} data/$mic/${train_set}_noise_low

  steps/data/augment_data_dir.py --utt-prefix "noise_high" --modify-spk-id "true" \
    --bg-snrs "15:10:5:3:0" --num-bg-noises "1" --bg-noise-dir "/export/c12/aarora8/OpenSAT/safet_noise_wavfile/" \
    data/$mic/${train_set} data/$mic/${train_set}_noise_high

  utils/combine_data.sh data/$mic/train_aug data/$mic/${train_set}_noise_low data/$mic/${train_set}_noise_high data/$mic/train
fi


if [ $stage -le 12 ]; then
  # obtain the alignment of augmented data from clean data
  include_original=false
  prefixes=""
  for n in $aug_list; do
    if [ "$n" != "clean" ]; then
      prefixes="$prefixes "$n
    else
      # The original train directory will not have any prefix
      # include_original flag will take care of copying the original alignments
      include_original=true
    fi
  done

  echo "Starting SAT+FMLLR training."
  steps/align_si.sh --nj 30 --cmd "$train_cmd" \
      --use-graphs true data/$mic/train data/lang exp/$mic/tri3 exp/$mic/tri3_train_ali

  echo "$0: Creating alignments of aug data by copying alignments of clean data"
  steps/copy_ali_dir.sh --nj 30 --cmd "$train_cmd" \
    --include-original "$include_original" --prefixes "$prefixes" \
    data/$mic/train_aug exp/$mic/tri3_train_ali exp/$mic/tri3_train_ali_aug
fi

if [ $stage -le 13 ]; then
   for f in data/$mic/${train_set}_noise_low data/$mic/${train_set}_noise_high ; do
    steps/make_mfcc.sh --cmd "$train_cmd" --nj 80 $f
    steps/compute_cmvn_stats.sh $f
  done
fi

if [ $stage -le 14 ] ; then
  utils/data/combine_data.sh data/$mic/train_aug data/$mic/${train_set}_noise_low data/$mic/${train_set}_noise_high data/$mic/train
  steps/compute_cmvn_stats.sh data/$mic/train_aug
fi

#if [ $stage -le 13 ]; then
#  # Extract low-resolution MFCCs for the augmented data
#  # To be used later to generate alignments for augmented data
#  echo "$0: Extracting low-resolution MFCCs for the augmented data. Useful for generating alignments"
#  steps/make_mfcc.sh --cmd "$train_cmd" --nj 80 data/$mic/train_aug
#  steps/compute_cmvn_stats.sh data/$mic/train_aug
#  utils/fix_data_dir.sh data/$mic/train_aug
#fi

if [ $stage -le 14 ]; then
  for dataset in train_aug; do
    echo "$0: Creating hi resolution MFCCs for dir data/$dataset"
    utils/copy_data_dir.sh data/$mic/$dataset data/$mic/${dataset}_hires
    utils/data/perturb_data_dir_volume.sh data/$mic/${dataset}_hires

    steps/make_mfcc.sh --nj 80 --mfcc-config conf/mfcc_hires.conf \
        --cmd "$train_cmd" data/$mic/${dataset}_hires
    steps/compute_cmvn_stats.sh data/$mic/${dataset}_hires
    utils/fix_data_dir.sh data/$mic/${dataset}_hires;
  done
fi


#if [ $stage -le 11 ]; then
#  ali_opt=
#  [ "$mic" != "ihm" ] && ali_opt="--use-ihm-ali true"
#  local/chain/run_tdnn.sh $ali_opt --mic $mic
#fi

#if [ $stage -le 12 ]; then
#  the following shows how you would run the nnet3 system; we comment it out
#  because it's not as good as the chain system.
#  ali_opt=
#  [ "$mic" != "ihm" ] && ali_opt="--use-ihm-ali false"
#  local/nnet3/run_tdnn.sh $ali_opt --mic $mic 
#fi

exit 0
