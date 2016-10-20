#!/bin/bash
# Thomas Emmerling - Maastricht University - 2015-03-27
# This script assumes that there is a project folder with subfolders for every subject
# (named as written in the $SUBJECTS variable) and a subfolder "rawData" with in turn
# two subfolders "anatomy" and "pd" with the DICOM files inside.
#
# If needed, make sure to install current CUDA drivers
# (for OSX: http://www.nvidia.com/object/mac-driver-archive.html)
#
# If mail notifications should be used please make sure t0 check the settings
# (especially the API key)

if [ $# -eq 1 ]; then
  echo $1
else
  echo "$0 requires 1 argument - settings.txt";
  echo "Example: ./$0 settings.txt";
  exit 1;
fi

# Settings
scriptPath=pwd
# import settings from first parameter given
source "$1"

# Colors
red='\033[0;31m'
green='\033[0;32m'
NC='\033[0m'

if [ "$useGPU" = true ]; then
  GPU="-use-gpu "
else
  GPU=""
fi

# Functions
notifyMail() {
  if [ "$useMail" = true ]; then
    msg='{ "async": false, "key": "'$mandrill_key'", "message": { "from_email": "'$from_email'", "from_name": "'$from_name'", "headers": { "Reply-To": "'$reply_to'" }, "return_path_domain": null, "subject": "'$mail_subject'", "text": "'$1'", "to": [ { "email": "'$to_email'", "type": "to" } ] } }'
    results=$(curl -A 'Mandrill-Curl/1.0' -d "$msg" 'https://mandrillapp.com/api/1.0/messages/send.json' -s 2>&1);
    echo "$results" | grep "sent" -q;
    if [ $? -ne 0 ]; then
      echo "An error occured: $results";
    fi
  fi
}

printStep() {
  echo -e $green"=============================================================\n"
  echo -e "$1\n"
  echo -e "=============================================================\n"$NC
}

printQuestion() {
  echo -e $red"=============================================================\n"
  echo -e "$1\n"
  echo -e "=============================================================\n"$NC
}

printAction() {
  echo -e $green$1$NC
}

printWarn() {
  echo -e $red$1$NC
}

readStatus() {
  # Read in fs.status file (or create it)
  if [ -f $SUBJECTS_DIR$F$SUBJ$F"fs.status" ]; then
    STATUS=$(cat $SUBJECTS_DIR$F$SUBJ$F"fs.status")
  else
    touch $SUBJECTS_DIR$F$SUBJ$F"fs.status"
    echo 0 > $SUBJECTS_DIR$F$SUBJ$F"fs.status"
    STATUS=0
  fi
}

writeStatus() {
  if [ ! -f $SUBJECTS_DIR$F$SUBJ$F"fs.status" ]; then
    touch $SUBJECTS_DIR$F$SUBJ$F"fs.status"
  fi
  echo $1 > $SUBJECTS_DIR$F$SUBJ$F"fs.status"
  STATUS=$1
}

# Run topup for several subjects
printStep "Freesurfer recon-all pipeline optimized for 7T data"

export SUBJECTS_DIR=$PROJECTBASEPATH$F"fs"

printAction "Checking if subjects folder is existing..."
if [ ! -d $SUBJECTS_DIR ]; then
  printAction "...subjects folder does not seem to exist! I will create it now..."
  mkdir $SUBJECTS_DIR
fi

if [ "$flag_conversion" = true ]; then
# Iterate through subjects
printStep "Convert DICOM images for each subject (skipping already existing files!)"
for subject in $SUBJECTS
  do
    printAction "Convert DICOMS for subect "$subject"..."
    cd $PROJECTBASEPATH$F$subject$F"rawData"

    if [ ! -f $PROJECTBASEPATH$F$subject$F"fs"$F"anatomy.mgz" ]; then
      printAction "Convert anatomy scan..."
      unpacksdcmdir -src $PROJECTBASEPATH$F$subject$F"rawData"$F"anatomy" \
        -targ $PROJECTBASEPATH$F$subject$F"fs" -generic -run $runAnatomy . mgz "anatomy.mgz"
    fi

    if [ ! -f $PROJECTBASEPATH$F$subject$F"fs"$F"pd.mgz" ]; then
      printAction "Convert pd scan..."
      unpacksdcmdir -src $PROJECTBASEPATH$F$subject$F"rawData"$F"pd" \
        -targ $PROJECTBASEPATH$F$subject$F"fs" -generic -run $runPD . mgz "pd.mgz"
    fi

    cd $PROJECTBASEPATH$F$subject$F"fs"

    if [ "$flag_alignPD" = true ]; then
      if [ ! -f $PROJECTBASEPATH$F$subject$F"fs"$F"pdToAnatomy.mgz" ]; then
        printAction "Convert anatomy and pd scan to nii.gz for alignment..."
        # mri_robust_register --mov pd.mgz --dst anatomy.mgz --lta pdToAnatomy.lta --mapmov pdToAnatomy.mgz --weights pdToAnatomy-weights.mgz --iscale --satit
        if [ ! -f $PROJECTBASEPATH$F$subject$F"fs"$F"pd.nii.gz" ]; then
          mri_convert pd.mgz pd.nii.gz
        fi
        if [ ! -f $PROJECTBASEPATH$F$subject$F"fs"$F"anatomy.nii.gz" ]; then
          mri_convert anatomy.mgz anatomy.nii.gz
        fi
        printAction "Co-register pd scan to the anatomy..."
        if [ ! -f $PROJECTBASEPATH$F$subject$F"fs"$F"pdToAnatomy.nii.gz" ]; then
          flirt -in pd.nii.gz -ref anatomy.nii.gz -out pdToAnatomy.nii.gz
          mri_convert pdToAnatomy.nii.gz pd.mgz
        fi
      fi
    fi
    if [ ! -f $PROJECTBASEPATH$F$subject$F"fs"$F"divPD.mgz" ]; then
      printAction "Divide the anatomy by the pd scan..."
      fscalc anatomy.mgz div pd.mgz mul 100 --o divPD.mgz
    fi

    if [ ! -f $PROJECTBASEPATH$F$subject$F"fs"$F"pdm.mgz" ]; then
      printAction "Make a mask from the pd scan (>20)"
      mri_binarize --i pd.mgz --min 20 --o pdm.mgz
    fi

    if [ ! -f $PROJECTBASEPATH$F$subject$F"fs"$F"divPDm.mgz" ]; then
      printAction "Mask the divPD with the created mask"
      mri_mask divPD.mgz pdm.mgz divPDm.mgz
    fi
  done
fi

if [ "$flag_reconRegister" = true ]; then
# Iterate through subjects
printStep "Register mgz images for each subject - normal and downsampled"
for subject in $SUBJECTS
  do
    printAction "Register mgz images for subect "$subject"..."
    if [ ! -d $SUBJECTS_DIR$F$subject$F"mri" ]; then
      recon-all -i $PROJECTBASEPATH$F$subject$F"fs"$F"divPDm.mgz" -subjid $subject
    fi
    if [ ! -d $SUBJECTS_DIR$F$subject"_1mm"$F"mri" ]; then
      recon-all -i $PROJECTBASEPATH$F$subject$F"fs"$F"divPDm.mgz" -subjid $subject"_1mm"
    fi
  done
fi


# =============================================================================
# Recon pipeline for downsampled (1mm) data
# =============================================================================

if [ "$flag_reconDownsampled" = true ]; then
# Iterate through subjects
for subject in $SUBJECTS
  do
    printStep "Run recon-all for downsampled (1mm) data for subject "$subject
    export SUBJ=$subject"_1mm"

    readStatus
    if [ $STATUS -lt 1 ] && [ $STATUS -lt $ENDSTATUS1mm ]; then
      printStep "Step 1: motion correction and talairach transformation..."
      recon-all -motioncor -talairach -tal-check $GPU-openmp $nProc -subjid $SUBJ

      if [ "$flag_askQuestions" = true ]; then
        #freeview -v $SUBJECTS_DIR$F$SUBJ$F"mri"$F"orig.mgz":reg=$SUBJECTS_DIR$F$SUBJ$F"mri"$F"transforms"$F"talairach.xfm" &
        notifyMail "Subject $SUBJ - Step 1: motion correction and talairach transformation was completed. Please check talairach transformation!"
        tkregister2 --mgz --s $SUBJ --fstal > /dev/null 2>&1 &
        tkr_PID=$!
        printQuestion "Does the talairach transformation look OK? (Click the COMPARE button in tkregister2)"
        PS3='Please enter your choice: '
        options=("Yes, continue" "No, copy the auto correction" "No, cancel!")
        select opt in "${options[@]}"
        do
            case $opt in
                "Yes, continue")
                    printAction "OK, I will continue..."
                    kill $tkr_PID
                    break
                    ;;
                "No, copy the auto correction")
                    printWarn "OK, I will copy the automatic correction! Please check again..."
                    cp $SUBJECTS_DIR$F$SUBJ$F"mri"$F"transforms"$F"talairach.auto.xfm" \
                      $SUBJECTS_DIR$F$SUBJ$F"mri"$F"transforms"$F"talairach.xfm"
                    recon-all -tal-check -s $SUBJ
                    printQuestion "Does the talairach transformation look OK? (Click the COMPARE button in tkregister2)"
                    kill $tkr_PID
                    tkregister2 --mgz --s $SUBJ --fstal > /dev/null 2>&1 &
                    ;;
                "No, cancel!")
                    printWarn "OK, I will abort the script!"
                    kill $fw_PID
                    exit
                    ;;
                *) echo invalid option;;
            esac
        done
      fi
      cp $SUBJECTS_DIR$F$SUBJ$F"mri"$F"transforms"$F"talairach.auto.xfm" \
        $SUBJECTS_DIR$F$SUBJ$F"mri"$F"transforms"$F"talairach.xfm"
      writeStatus 1
    fi

    readStatus
    if [ $STATUS -lt 2 ] && [ $STATUS -lt $ENDSTATUS1mm ]; then
      printStep "Step 2: nu correction (go, get a coffee, this will take a while)..."
      mri_nu_correct.mni --i $SUBJECTS_DIR$F$SUBJ$F"mri"$F"orig.mgz" \
        --o $SUBJECTS_DIR$F$SUBJ$F"mri"$F"nu.mgz" --proto-iters 1000 \
        --distance 15 --fwhm 0.15 --n 1
        --uchar $SUBJECTS_DIR$F$SUBJ$F"mri"$F"transforms"$F"talairach.xfm"
      writeStatus 2
    fi

    readStatus
    if [ $STATUS -lt 3 ] && [ $STATUS -lt $ENDSTATUS1mm ]; then
      printStep "Step 3: normalization..."
      recon-all -mprage -normalization $GPU-openmp $nProc -subjid $SUBJ
      writeStatus 3
    fi

    readStatus
    if [ $STATUS -lt 4 ] && [ $STATUS -lt $ENDSTATUS1mm ]; then
      printStep "Step 4: skull stripping..."
      recon-all -mprage -skullstrip $GPU-openmp $nProc -subjid $SUBJ

      if [ "$flag_askQuestions" = true ]; then
        notifyMail "Subject $SUBJ - Step 3: skull stripping was completed. Please check skull strip!"
        freeview -v $SUBJECTS_DIR$F$SUBJ$F"mri"$F"brainmask.mgz" &
        fw_PID=$!

        printQuestion "Does the skull stripping look OK?"
        PS3='Please enter your choice: '
        options=("Yes, continue" "No, try a different watershed preflooding height percentage" "No, try mri_gcut" "No, cancel!")
        select opt in "${options[@]}"
        do
            case $opt in
                "Yes, continue")
                    printAction "OK, I will continue..."
                    kill $fw_PID
                    break
                    ;;
                "No, try a different watershed preflooding height percentage")
                    printWarn "OK, which watershed preflooding height percentage should I use? (default: 25; lower percentage is more aggressive)"
                    printWarn "Enter the value (0-100) and press [ENTER]: "
                    read ws
                    if [ $ws -lt 0 ] || [ $ws -gt 100 ]; then
                      printWarn "A percentage needs to be between 0 and 100!"
                    else
                      mri_watershed -T1 -atlas -h $ws -brain_atlas \
                        $FREESURFER_HOME/average/RB_all_withskull_2008-03-26.gca \
                        $SUBJECTS_DIR$F$SUBJ$F"mri"$F"transforms"$F"talairach_with_skull.lta" \
                        $SUBJECTS_DIR$F$SUBJ$F"mri"$F"T1.mgz" \
                        $SUBJECTS_DIR$F$SUBJ$F"mri"$F"brainmask.auto.mgz"

                      printWarn "Does skull stripping look OK now?"
                      kill $fw_PID
                      freeview -v $SUBJECTS_DIR$F$SUBJ$F"mri"$F"brainmask.auto.mgz" &
                    fi
                    ;;
                    "No, try mri_gcut")
                        printWarn "OK, I will use the skull stripping algorithm based on graph cuts"
                        mri_gcut -110 -mult $SUBJECTS_DIR$F$SUBJ$F"mri"$F"brainmask.auto.mgz" \
                          $SUBJECTS_DIR$F$SUBJ$F"mri"$F"T1.mgz" \
                          $SUBJECTS_DIR$F$SUBJ$F"mri"$F"brainmask.auto.mgz"
                        printWarn "Does skull stripping look OK now?"
                        kill $fw_PID
                        freeview -v $SUBJECTS_DIR$F$SUBJ$F"mri"$F"brainmask.auto.mgz" &
                        ;;
                "No, cancel!")
                    printWarn "OK, I will abort the script!"
                    kill $fw_PID
                    exit
                    ;;
                *) echo invalid option;;
            esac
        done
      fi
      cp $SUBJECTS_DIR$F$SUBJ$F"mri"$F"brainmask.auto.mgz" $SUBJECTS_DIR$F$SUBJ$F"mri"$F"brainmask.mgz"
      writeStatus 4
    fi

    readStatus
    if [ $STATUS -lt 5 ] && [ $STATUS -lt $ENDSTATUS1mm ]; then
      printStep "Step 5: autorecon2 and autorecon3 (go, get a coffee, this will take a while)..."
      recon-all -autorecon2 -autorecon3 -mprage $GPU-openmp $nProc -subjid $SUBJ
      writeStatus 5
    fi

    notifyMail "Subject $SUBJ - All steps completed (downsampled dataset)"
  done
fi


# =============================================================================
# Recon pipeline for normal (0.5mm) data
# =============================================================================


if [ "$flag_recon" = true ]; then
# Iterate through subjects
for subject in $SUBJECTS
  do
    printStep "Run recon-all for normal (0.5mm) data for subject "$subject

    export SUBJ=$subject
    export SUBJd=$subject"_1mm"

    readStatus
    if [ $STATUS -lt 1 ] && [ $STATUS -lt $ENDSTATUS ]; then
      printStep "Step 1: motion correction and talairach transformation..."
      recon-all -motioncor -talairach -tal-check $GPU-openmp $nProc -subjid $SUBJ

      if [ "$flag_askQuestions" = true ]; then
        #freeview -v $SUBJECTS_DIR$F$SUBJ$F"mri"$F"orig.mgz":reg=$SUBJECTS_DIR$F$SUBJ$F"mri"$F"transforms"$F"talairach.xfm" &
        notifyMail "Subject $SUBJ - Step 1: motion correction and talairach transformation was completed. Please check talairach transformation!"
        tkregister2 --mgz --s $SUBJ --fstal > /dev/null 2>&1 &
        tkr_PID=$!
        printQuestion "Does the talairach transformation look OK? (Click the COMPARE button in tkregister2)"
        PS3='Please enter your choice: '
        options=("Yes, continue" "No, copy the auto correction" "No, cancel!")
        select opt in "${options[@]}"
        do
            case $opt in
                "Yes, continue")
                    printAction "OK, I will continue..."
                    kill $tkr_PID
                    break
                    ;;
                "No, copy the auto correction")
                    printWarn "OK, I will copy the automatic correction! Please check again..."
                    cp $SUBJECTS_DIR$F$SUBJ$F"mri"$F"transforms"$F"talairach.auto.xfm" \
                      $SUBJECTS_DIR$F$SUBJ$F"mri"$F"transforms"$F"talairach.xfm"
                    recon-all -tal-check -s $SUBJ
                    printWarn "Does the talairach transformation look OK? (Click the COMPARE button in tkregister2)"
                    kill $tkr_PID
                    tkregister2 --mgz --s $SUBJ --fstal > /dev/null 2>&1 &
                    ;;
                "No, cancel!")
                    printWarn "OK, I will abort the script!"
                    kill $fw_PID
                    exit
                    ;;
                *) echo invalid option;;
            esac
        done
      fi
      cp $SUBJECTS_DIR$F$SUBJ$F"mri"$F"transforms"$F"talairach.auto.xfm" \
        $SUBJECTS_DIR$F$SUBJ$F"mri"$F"transforms"$F"talairach.xfm"
      writeStatus 1
    fi

    readStatus
    if [ $STATUS -lt 2 ] && [ $STATUS -lt $ENDSTATUS ]; then
      printStep "Step 2: nu correction (go, get a coffee, this will take a while)..."
      mri_nu_correct.mni --cm --i $SUBJECTS_DIR$F$SUBJ$F"mri"$F"orig.mgz" \
        --o $SUBJECTS_DIR$F$SUBJ$F"mri"$F"nu.mgz" --proto-iters 1000 \
        --distance 15 --fwhm 0.15 --n 1
        --uchar $SUBJECTS_DIR$F$SUBJ$F"mri"$F"transforms"$F"talairach.xfm"
      writeStatus 2
    fi

    readStatus
    if [ $STATUS -lt 3 ] && [ $STATUS -lt $ENDSTATUS ]; then
      printStep "Step 3: normalization..."
      recon-all -cm -mprage -normalization $GPU-openmp $nProc -subjid $SUBJ
      writeStatus 3
    fi

    readStatus
    if [ $STATUS -lt 4 ] && [ $STATUS -lt $ENDSTATUS ]; then
      printStep "Step 4: skull stripping..."

      printAction "This upsamples the aseg.auto_noCCseg.mgz of the formerly downsampled dataset and places it in the according folder of the high resolution data."

      mri_convert -rl $SUBJECTS_DIR$F$SUBJ$F"mri"$F"orig.mgz" \
        -rt nearest $SUBJECTS_DIR$F$SUBJd$F"mri"$F"aseg.auto_noCCseg.mgz" \
        $SUBJECTS_DIR$F$SUBJ$F"mri"$F"aseg.auto_noCCseg.mgz"

      printAction "This upsamples the aseg.mgz of the formerly downsampled dataset and places it in the according folder of the high resolution data."
      mri_convert -rl $SUBJECTS_DIR$F$SUBJ$F"mri"$F"orig.mgz" \
        -rt nearest $SUBJECTS_DIR$F$SUBJd$F"mri"$F"aseg.mgz" \
        $SUBJECTS_DIR$F$SUBJ$F"mri"$F"aseg.mgz"

      printAction "This upsamples the brainmask.mgz of the formerly downsampled dataset and places it in the according folder of the high resolution data."
      mri_convert -rl $SUBJECTS_DIR$F$SUBJ$F"mri"$F"orig.mgz" \
        -rt nearest $SUBJECTS_DIR$F$SUBJd$F"mri"$F"brain.mgz" \
        $SUBJECTS_DIR$F$SUBJ$F"mri"$F"brainmask.hires.mgz"

      printAction "This creates the brainmask.mgz of the high resolution data by masking the high resolution T1.mgz by the upsampled brainmask of the formerly downsampled dataset."
      mri_mask $SUBJECTS_DIR$F$SUBJ$F"mri"$F"T1.mgz" \
        $SUBJECTS_DIR$F$SUBJ$F"mri"$F"brainmask.hires.mgz" \
        $SUBJECTS_DIR$F$SUBJ$F"mri"$F"brainmask.mgz"

      writeStatus 4
    fi

    readStatus
    if [ $STATUS -lt 5 ] && [ $STATUS -lt $ENDSTATUS ]; then
      printStep "Step 5: gcareg and canorm..."
      recon-all -gcareg -canorm $GPU-openmp $nProc -subjid $SUBJ
      writeStatus 5
    fi

    readStatus
    if [ $STATUS -lt 6 ] && [ $STATUS -lt $ENDSTATUS ]; then
      printStep "Step 6: normalize..."
      mri_normalize -mprage -noconform \
        -mask $SUBJECTS_DIR$F$SUBJ$F"mri"$F"brainmask.mgz" \
        $SUBJECTS_DIR$F$SUBJ$F"mri"$F"norm.mgz" \
        $SUBJECTS_DIR$F$SUBJ$F"mri"$F"brain.mgz"
      writeStatus 6
    fi

    readStatus
    if [ $STATUS -lt 7 ] && [ $STATUS -lt $ENDSTATUS ]; then
      printStep "Step 7: maskbfs and segmentation..."
      recon-all -maskbfs -segmentation -fill -tessellate $GPU-openmp $nProc -subjid $SUBJ
      writeStatus 7
    fi

    readStatus
    if [ $STATUS -lt 8 ] && [ $STATUS -lt $ENDSTATUS ]; then
      printStep "Step 8: Smooth and inflate for LH and RH..."
      recon-all -smooth1 -inflate1 -qsphere -hemi lh \
        -log $SUBJECTS_DIR$F$SUBJ$F"scripts"$F"recon-all.lh.log" \
        $GPU-openmp $nProc -subjid $SUBJ &
      recon-all -smooth1 -inflate1 -qsphere -hemi rh \
        -log $SUBJECTS_DIR$F$SUBJ$F"scripts"$F"recon-all.rh.log" \
        $GPU-openmp $nProc -subjid $SUBJ &
      wait

      # This is just a poor work-around as the stage "fix" of recon-all might take weeks to finish...
      cp $SUBJECTS_DIR$F$SUBJ$F"surf"$F"lh.orig.nofix" \
        $SUBJECTS_DIR$F$SUBJ$F"surf"$F"lh.orig"
      cp $SUBJECTS_DIR$F$SUBJ$F"surf"$F"rh.orig.nofix" \
        $SUBJECTS_DIR$F$SUBJ$F"surf"$F"rh.orig"
      writeStatus 8
    fi

    readStatus
    if [ $STATUS -lt 9 ] && [ $STATUS -lt $ENDSTATUS ]; then
      printStep "Step 9: smooth and autorecon3..."
      recon-all -white -smooth2 -inflate2 -autorecon3 -hemi lh \
        -log $SUBJECTS_DIR$F$SUBJ$F"scripts"$F"recon-all.lh.log" \
        $GPU-openmp $nProc -subjid $SUBJ &
      recon-all -white -smooth2 -inflate2 -autorecon3 -hemi rh \
        -log $SUBJECTS_DIR$F$SUBJ$F"scripts"$F"recon-all.rh.log" \
        $GPU-openmp $nProc -subjid $SUBJ &

      wait
      writeStatus 9
    fi

    notifyMail "Subject $SUBJ - All steps completed (normal dataset)"
  done
fi

if [ "$flag_backTransform" = true ]; then
# Iterate through subjects
for subject in $SUBJECTS
  do
    printStep "Start to back-transform mgz images (normal dataset) for subject "$subject
    export SUBJ=$subject
    MDIR=$SUBJECTS_DIR$F$SUBJ$F"mri"$F
    FDIR=$PROJECTBASEPATH$F$subject$F"fs"$F

    if [ "$flag_backTransformT1" = true ]; then
      printAction "Export the T1.mgz file for BrainVoyager"
      # make the WM voxels 160 for BVQX (from 110 in freesurfer)
      fscalc $MDIR"T1.mgz" mul 1.4545454545454546 \
        --o $MDIR"T1b.mgz"
      mri_vol2vol --cubic --mov $MDIR"T1b.mgz" \
        --targ $MDIR"rawavg.mgz" \
        --regheader --o $MDIR"T1b-in-native.mgz" \
        --no-save-reg
      mri_convert $MDIR"T1b-in-native.mgz" \
      $FDIR$SUBJ"_divPD.nii.gz"
      gunzip $FDIR$SUBJ"_divPD.nii.gz"
    fi

    if [ "$flag_backTransformRibbon" = true ]; then
      printAction "Export ribbon.mgz file to Brainvoyager"
      mri_binarize --i $MDIR"ribbon.mgz" --match 2 --binval 240 \
        --o $MDIR"wm_lh.mgz"
      mri_binarize --i $MDIR"ribbon.mgz" --match 41 --binval 240 \
        --o $MDIR"wm_rh.mgz"
      mri_binarize --i $MDIR"ribbon.mgz" --match 2 41 --binval 150 \
        --o $MDIR"wm_both.mgz"

      mri_binarize --i $MDIR"ribbon.mgz" --match 3 --binval 100 \
        --o $MDIR"gm_lh.mgz"
      mri_binarize --i $MDIR"ribbon.mgz" --match 42 --binval 100 \
        --o $MDIR"gm_rh.mgz"
      mri_binarize --i $MDIR"ribbon.mgz" --match 3 42 --binval 100 \
        --merge $MDIR"wm_both.mgz" --o $MDIR"wm_gm_both.mgz"

      mri_vol2vol --nearest --mov $MDIR"wm_lh.mgz" \
       --targ $MDIR"rawavg.mgz" \
       --regheader --o $MDIR"wm_lh-in-native.mgz" \
       --no-save-reg
      mri_vol2vol --nearest --mov $MDIR"wm_rh.mgz" \
       --targ $MDIR"rawavg.mgz" \
       --regheader --o $MDIR"wm_rh-in-native.mgz" \
       --no-save-reg
      mri_vol2vol --nearest --mov $MDIR"wm_gm_both.mgz" \
       --targ $MDIR"rawavg.mgz" \
       --regheader --o $MDIR"wm_gm_both-in-native.mgz" \
       --no-save-reg

      mri_convert $MDIR"wm_lh-in-native.mgz" \
        $FDIR$SUBJ"_wm_lh.nii.gz"
      mri_convert $MDIR"wm_rh-in-native.mgz" \
        $FDIR$SUBJ"_wm_rh.nii.gz"
      mri_convert $MDIR"wm_gm_both-in-native.mgz" \
        $FDIR$SUBJ"_wm_gm_both.nii.gz"

      gunzip $FDIR$SUBJ"_wm_rh.nii.gz"
      gunzip $FDIR$SUBJ"_wm_lh.nii.gz"
      gunzip $FDIR$SUBJ"_wm_gm_both.nii.gz"
    fi
  done
fi

printAction "...done with all steps and subjects!"
notifyMail "All subjects completed! Script exits."
