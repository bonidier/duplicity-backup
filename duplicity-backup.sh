#!/usr/bin/env bash
#
# Copyright (c) 2008-2010 Damon Timm.
# Copyright (c) 2010 Mario Santagiuliana.
# Copyright (c) 2012-2018 Marc Gallet.
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later
# version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
# details.
#
# You should have received a copy of the GNU General Public License along with
# this program.  If not, see <http://www.gnu.org/licenses/>.
#
# MORE ABOUT THIS SCRIPT AVAILABLE IN THE README AND AT:
#
# http://zertrin.org/projects/duplicity-backup/ (for this version)
# http://damontimm.com/code/dt-s3-backup (for the original program by Damon Timm)
#
# Latest code available at:
# http://github.com/zertrin/duplicity-backup.sh
#
# List of contributors:
# https://github.com/zertrin/duplicity-backup.sh/graphs/contributors
#
# ---------------------------------------------------------------------------- #

# Default config file (don't forget to copy duplicity-backup.conf.example to
# match that path)
#
# NOTE: It is RECOMMENDED to use the command line option -c to specify the
#       location of the config file. The CONFIG variable here is only used for
#       fallback purposes (look for the file named 'duplicity-backup.conf' in
#       the same folder as the script, if the option -c is not given).
#       It is DEPRECATED to edit this.

CONFIG="duplicity-backup.conf"

##############################################################
# Script Happens Below This Line - Shouldn't Require Editing #
##############################################################

DBSH_VERSION="v1.6.1-dev"

# make a backup of stdout and stderr for later
exec 6>&1
exec 7>&2

# ------------------------------------------------------------

usage(){
echo "USAGE:
  $(basename "$0") [options]

  Options:
    -c, --config CONFIG_FILE   specify the config file to use

    -b, --backup               runs an incremental backup
    -f, --full                 forces a full backup
    -v, --verify               verifies the backup
    -e, --cleanup              cleanup the backup (eg. broken sessions), by default using
                               duplicity --force flag, use --dry-run to actually log what
                               will be cleaned up without removing (see man duplicity
                               > ACTIONS > cleanup for details)
    -l, --list-current-files   lists the files currently backed up in the archive
    -s, --collection-status    show all the backup sets in the archive

        --restore [PATH]       restores the entire backup to [path]
        --restore-file [FILE_TO_RESTORE] [DESTINATION]
                               restore a specific file
        --restore-dir [DIR_TO_RESTORE] [DESTINATION]
                               restore a specific directory

    -t, --time TIME            specify the time from which to restore or list files
                               (see duplicity man page for the format)

    --backup-script            automatically backup the script and secret key(s) to
                               the current working directory

    -q, --quiet                silence most of output messages, except errors and output
                               that are intended for interactive usage. Silenced output
                               is still logged in the logfile.

    -n, --dry-run              perform a trial run with no changes made
    -V, --version              print version information about this script and duplicity
    -h, --help                 print this help and exit

  CURRENT SCRIPT VARIABLES:
  ========================
    DEST (backup destination)       = ${DEST}
    INCLIST (directories included)  = ${INCLIST[*]:0}
    EXCLIST (directories excluded)  = ${EXCLIST[*]:0}
    ROOT (root directory of backup) = ${ROOT}
    LOGFILE (log file path)         = ${LOGFILE}
" >&6
USAGE=1
}

DUPLICITY="$(command -v duplicity)"

if [ ! -x "${DUPLICITY}" ]; then
  echo "ERROR: duplicity not installed, that's gotta happen first!" >&2
  exit 1
fi

DUPLICITY_VERSION=$(${DUPLICITY} --version)
DUPLICITY_VERSION=${DUPLICITY_VERSION//[^0-9\.]/}

version_compare() {
    local l r s
    if [[ $1 =~ ^([0-9]+\.?)+$ && $2 =~ ^([0-9]+\.?)+$ ]]; then
        # shellcheck disable=SC2206
        l=(${1//./ }) r=(${2//./ }) s=${#l[@]}; [[ ${#r[@]} -gt ${#l[@]} ]] && s=${#r[@]}

        for i in $(seq 0 $((s - 1))); do
            [[ ${l[$i]} -gt ${r[$i]} ]] && return 1
            [[ ${l[$i]} -lt ${r[$i]} ]] && return 2
        done

        return 0
    else
        echo "Invalid version number given"
        exit 1
    fi
}

# set a flag if duplicity's version is lower than 0.7, for usage later in the script
version_compare "${DUPLICITY_VERSION}" 0.7
case $? in 2) LT07=1;; *) LT07=0;; esac

version(){
  echo "duplicity-backup.sh ${DBSH_VERSION}"
  echo "duplicity ${DUPLICITY_VERSION}"
  exit 0
}

# Some expensive argument parsing that allows the script to
# be insensitive to the order of appearance of the options
# and to handle correctly option parameters that are optional
while getopts ":c:t:bfvelsqnhV-:" opt; do
  case $opt in
    # parse long options (a bit tricky because builtin getopts does not
    # manage long options and I don't want to impose GNU getopt dependancy)
    -)
      case "${OPTARG}" in
        # --restore [restore dest]
        restore)
          COMMAND=${OPTARG}
          # We try to find the optional value [restore dest]
          if [ -n "${!OPTIND:0:1}" ] && [ ! "${!OPTIND:0:1}" = "-" ]; then
            RESTORE_DEST=${!OPTIND}
            OPTIND=$(( OPTIND + 1 )) # we found it, move forward in arg parsing
          fi
        ;;
        # --restore-file [file to restore] [restore dest]
        # --restore-dir [path to restore] [restore dest]
        restore-file|restore-dir)
          COMMAND=${OPTARG}
          # We try to find the first optional value [file to restore]
          if [ -n "${!OPTIND:0:1}" ] && [ ! "${!OPTIND:0:1}" = "-" ]; then
            FILE_TO_RESTORE=${!OPTIND}
            OPTIND=$(( OPTIND + 1 )) # we found it, move forward in arg parsing
          else
            continue # no value for the restore-file option, skip the rest
          fi
          # We try to find the second optional value [restore dest]
          if [ -n "${!OPTIND:0:1}" ] && [ ! "${!OPTIND:0:1}" = "-" ]; then
            RESTORE_DEST=${!OPTIND}
            OPTIND=$(( OPTIND + 1 )) # we found it, move forward in arg parsing
          fi
        ;;
        config) # set the config file from the command line
          # We try to find the config file
          if [ -n "${!OPTIND:0:1}" ] && [ ! "${!OPTIND:0:1}" = "-" ]; then
            CONFIG=${!OPTIND}
            OPTIND=$(( OPTIND + 1 )) # we found it, move forward in arg parsing
          fi
        ;;
        time) # set the restore time from the command line
          # We try to find the restore time
          if [ -n "${!OPTIND:0:1}" ] && [ ! "${!OPTIND:0:1}" = "-" ]; then
            TIME=${!OPTIND}
            OPTIND=$(( OPTIND + 1 )) # we found it, move forward in arg parsing
          fi
        ;;
        quiet)
          QUIET=1
        ;;
        dry-run)
          DRY_RUN="--dry-run"
        ;;
        help)
          usage
          exit 0
        ;;
        version)
          version
        ;;
        *)
          COMMAND=${OPTARG}
        ;;
        esac
    ;;
    # here are parsed the short options
    c) CONFIG=${OPTARG};; # set the config file from the command line
    t) TIME=${OPTARG};; # set the restore time from the command line
    b) COMMAND="backup";;
    f) COMMAND="full";;
    v) COMMAND="verify";;
    e) COMMAND="cleanup";;
    l) COMMAND="list-current-files";;
    s) COMMAND="collection-status";;
    q) QUIET=1;;
    n) DRY_RUN="--dry-run";; # dry run
    h)
      usage
      exit 0
    ;;
    V) version;;
    :)
      echo "Option -${OPTARG} requires an argument." >&2
      COMMAND=""
    ;;
    \?)
      echo "Invalid option: -${OPTARG}" >&2
      COMMAND=""
    ;;
  esac
done
#echo "Options parsed. COMMAND=${COMMAND}" # for debugging


# ----------------  Read config file if specified -----------------

if [ -n "${CONFIG}" ] && [ -f "${CONFIG}" ];
then
  # shellcheck source=duplicity-backup.conf.example
  . "${CONFIG}"
else
  echo "ERROR: can't find config file! (${CONFIG})" >&2
  usage
  exit 1
fi

# ----------------------- Setup logging ---------------------------

# Setup logging as soon as possible, in order to be able to perform i/o redirection

[[ ${LOGDIR} = "/home/foobar_user_name/logs/test2/" ]] && config_sanity_fail "LOGDIR must be configured"

# Ensure a trailing slash always exists in the log directory name
LOGDIR="${LOGDIR%/}/"

LOGFILE="${LOGDIR}${LOG_FILE}"

if [ ! -d "${LOGDIR}" ]; then
  echo "Attempting to create log directory ${LOGDIR} ..."
  if ! mkdir -p "${LOGDIR}"; then
    echo "Log directory ${LOGDIR} could not be created by this user: ${USER}" >&2
    echo "Aborting..." >&2
    exit 1
  else
    echo "Directory ${LOGDIR} successfully created."
  fi
  echo "Attempting to change owner:group of ${LOGDIR} to ${LOG_FILE_OWNER} ..."
  if ! chown "${LOG_FILE_OWNER}" "${LOGDIR}"; then
    echo "User ${USER} could not change the owner:group of ${LOGDIR} to ${LOG_FILE_OWNER}" >&2
    echo "Aborting..." >&2
    exit 1
  else
    echo "Directory ${LOGDIR} successfully changed to owner:group of ${LOG_FILE_OWNER}"
  fi
elif [ ! -w "${LOGDIR}" ]; then
  echo "Log directory ${LOGDIR} is not writeable by this user: ${USER}" >&2
  echo "Aborting..." >&2
  exit 1
fi

# -------------------- Setup I/O redirections --------------------
# Magic from
# http://superuser.com/questions/86915/force-bash-script-to-use-tee-without-piping-from-the-command-line
#
#  ##### Redirection matrix in the case when quiet mode is ON #####
#
#  QUIET mode ON  | shown on screen | not shown on screen
#  ---------------+-----------------+----------------------
#  logged         |    fd2, fd3     |      fd1, fd5
#  not logged     |      fd4        |         -
#
#  ##### Redirection matrix in the case when quiet mode is OFF #####
#
#  QUIET mode OFF | shown on screen | not shown on screen
#  ---------------+-----------------+----------------------
#  logged         | fd1, fd2, fd3   |        fd5
#  not logged     |      fd4        |         -
#
# fd1 is stdout and is always logged but only shown if not QUIET
# fd2 is stderr and is always shown on screen and logged
# fd3 is like stdout but always shown on screen (for interactive prompts)
# fd4 is always shown on screen but never logged (for the usage text)
# fd5 is never shown on screen but always logged (for delimiters in the log)
#

# fd2 and fd3 are always logged and shown on screen via tee
# for fd2 (original stderr) the output of tee needs to be redirected to stderr
exec 2> >(tee -ia "${LOGFILE}" >&2)
# create fd3 as a redirection to stdout and the logfile via tee
exec 3> >(tee -ia "${LOGFILE}")

# create fd4 as a copy of stdout, but that won't be redirected to tee
# so that it is always shown and never logged
exec 4>&1

# create fd5 as a direct redirection to the logfile
# so that the content is never shown on screen but always logged
exec 5>> "${LOGFILE}"

# finally we modify stdout (fd1) to always being logged (like fd3 and fd5)
# but only being shown on screen if quiet mode is not active
if [[ ${QUIET} == 1 ]]; then
  # Quiet mode: stdout not shown on screen but still logged via fd5
  exec 1>&5
else
  # Normal mode: stdout shown on screen and logged via fd3
  exec 1>&3
fi

# tests for debugging the magic
#echo "redirected to fd1"
#echo "redirected to fd2" >&2
#echo "redirected to fd3" >&3
#echo "redirected to fd4" >&4
#echo "redirected to fd5" >&5

# ------------------------- Setting up variables ------------------------

if [ -n "${DRY_RUN}" ]; then
  STATIC_OPTIONS="${DRY_RUN} ${STATIC_OPTIONS}"
fi

if [ -n "${STORAGECLASS}" ]; then
  STATIC_OPTIONS="${STATIC_OPTIONS} ${STORAGECLASS}"
fi

SIGN_PASSPHRASE=${PASSPHRASE}

export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export GS_ACCESS_KEY_ID
export GS_SECRET_ACCESS_KEY
export SWIFT_USERNAME
export SWIFT_PASSWORD
export SWIFT_AUTHURL
export SWIFT_AUTHVERSION
export SWIFT_TENANTNAME
export SWIFT_REGIONNAME
export DPBX_ACCESS_TOKEN
export PASSPHRASE
export SIGN_PASSPHRASE

if [[ -n "${FTP_PASSWORD}" ]]; then
  export FTP_PASSWORD
fi

if [[ -n "${tmpdir}" ]]; then
  export tmpdir
fi

# File to use as a lock. The lock is used to insure that only one instance of
# the script is running at a time.
LOCKFILE=${LOGDIR}backup.lock

if [ "${ENCRYPTION}" = "yes" ]; then
  ENCRYPT="--gpg-options \"${GPG_OPTIONS}\""
  if [ -n "${GPG_ENC_KEY}" ] && [ -n "${GPG_SIGN_KEY}" ]; then
    if [ "${HIDE_KEY_ID}" = "yes" ]; then
      ENCRYPT="${ENCRYPT} --hidden-encrypt-key=${GPG_ENC_KEY}"
      if [ "${COMMAND}" != "restore" ] && [ "${COMMAND}" != "restore-file" ] && [ "${COMMAND}" != "restore-dir" ]; then
        ENCRYPT="${ENCRYPT} --sign-key=${GPG_SIGN_KEY}"
      fi
    else
      ENCRYPT="${ENCRYPT} --encrypt-key=${GPG_ENC_KEY} --sign-key=${GPG_SIGN_KEY}"
    fi
    if [ -n "${SECRET_KEYRING}" ]; then
      KEYRING="--secret-keyring ${SECRET_KEYRING}"
      ENCRYPT="${ENCRYPT} --encrypt-secret-keyring=${SECRET_KEYRING}"
    fi
  elif [ -n "${PASSPHRASE}" ]; then
    ENCRYPT=""
  fi
elif [ "${ENCRYPTION}" = "no" ]; then
  ENCRYPT="--no-encryption"
fi

NO_GSCMD="WARNING: gsutil not found in PATH, remote file \
size information unavailable."
NO_GSCMD_CFG="WARNING: gsutil is not configured, run 'gsutil config' \
in order to retrieve remote file size information. Remote file \
size information unavailable."

NO_S3CMD="WARNING: s3cmd not found in PATH, remote file \
size information unavailable."
NO_S3CMD_CFG="WARNING: s3cmd is not configured, run 's3cmd --configure' \
in order to retrieve remote file size information. Remote file \
size information unavailable."

NO_B2CMD="WARNING: b2 not found in PATH, remote file size information \
unavailable. Is the python-b2 package installed?"

readonly DEST_PROTO=${DEST%"://"*}

case "${DEST_PROTO}" in
  "gs")
      GSCMD="$(command -v gsutil)"
      if [ ! -x "${GSCMD}" ]; then
        echo "${NO_GSCMD}"; GSCMD_AVAIL=false
      elif [ ! -f "${HOME}/.boto" ]; then
        echo "${NO_GSCMD_CFG}"; GSCMD_AVAIL=false
      else
        GSCMD_AVAIL=true
      fi
    ;;
   "s3"|"s3+http")
      S3CMD="$(command -v s3cmd)"
      if [ ! -x "${S3CMD}" ]; then
        echo "${NO_S3CMD}"; S3CMD_AVAIL=false
      elif [ -z "${S3CMD_CONF_FILE}" ] && [ ! -f "${HOME}/.s3cfg" ]; then
        S3CMD_CONF_FOUND=false
        echo "${NO_S3CMD_CFG}"; S3CMD_AVAIL=false
      elif [ -n "${S3CMD_CONF_FILE}" ] && [ ! -f "${S3CMD_CONF_FILE}" ]; then
        S3CMD_CONF_FOUND=false
        echo "${S3CMD_CONF_FILE} not found, check S3CMD_CONF_FILE variable in duplicity-backup's configuration!";
        echo "${NO_S3CMD_CFG}";
        S3CMD_AVAIL=false
      else
        S3CMD_AVAIL=true
        S3CMD_CONF_FOUND=true
        if [ -n "${S3CMD_CONF_FILE}" ] && [ -f "${S3CMD_CONF_FILE}" ]; then
          # if conf file specified and it exists then add it to the command line for s3cmd
          S3CMD="${S3CMD} -c ${S3CMD_CONF_FILE}"
        fi
      fi
    ;;
  "dpbx");;
  "b2")
    B2CMD_AVAIL=true
    B2CMD="$(command -v b2)"
    if [ ! -x "${B2CMD}" ]; then
      echo "${NO_B2CMD}"; B2CMD_AVAIL=false
    fi
    ;;
esac

config_sanity_fail()
{
  local explanation=$1
  local config_var_msg="Oops!! ${0} was unable to run!\nWe are missing one or more important variables in the configuration file.\nCheck your configuration because it appears that something has not been set yet."
  echo -e "${config_var_msg}\n  ${explanation}." >&2
  echo -e "---------------------    END    ---------------------\n" >&5
  exit 1
}

check_variables()
{
  local error_detail
  [[ -z "${ROOT}" ]] && error_detail="ROOT must be configured"
  [[ -z "${DEST}" || "${DEST}" == "s3+http://backup-foobar-bucket/backup-folder/" ]] && error_detail="DEST must be configured"
  [[ "${INCLIST[0]}" == "/home/foobar_user_name/Documents/" ]] && error_detail="INCLIST must be configured"
  [[ "${EXCLIST[0]}" == "/home/foobar_user_name/Documents/foobar-to-exclude" ]] && error_detail="EXCLIST must be configured"
  if [[ "${ENCRYPTION}" == "yes" ]]; then
    [[ "${GPG_ENC_KEY}" == "foobar_gpg_key" || "${GPG_SIGN_KEY}" == "foobar_gpg_key" || \
       "${PASSPHRASE}" == "foobar_gpg_passphrase" ]] && \
      error_detail="ENCRYPTION is set to 'yes', but GPG_ENC_KEY, GPG_SIGN_KEY, or PASSPHRASE have not been configured"
  fi

  case "${DEST_PROTO}" in
    "s3")
      [[ "${AWS_ACCESS_KEY_ID}" == "foobar_aws_key_id" || "${AWS_SECRET_ACCESS_KEY}" == "foobar_aws_access_key" ]] && \
        error_detail="An s3 DEST has been specified, but AWS_ACCESS_KEY_ID or AWS_SECRET_ACCESS_KEY have not been configured"
      ;;
    "gs")
      [[ "${GS_ACCESS_KEY_ID}" == "foobar_gcs_key_id" || "${GS_SECRET_ACCESS_KEY}" == "foobar_gcs_secret_id" ]] && \
        error_detail="A Google Cloud Storage DEST has been specified, but GS_ACCESS_KEY_ID or GS_SECRET_ACCESS_KEY have not been configured"
      ;;
    "dpbx")
      [[ "${DPBX_ACCESS_TOKEN}" == "foobar_dropbox_access_token" ]] && \
        error_detail="A Dropbox DEST has been specified, but DPBX_ACCESS_TOKEN has not been configured"
      ;;
  esac

  [[ -n "${INCEXCFILE}" && ! -f "${INCEXCFILE}" ]] && error_detail="The specified INCEXCFILE ${INCEXCFILE} does not exists"

  [[ -n "${error_detail}" ]] && config_sanity_fail "${error_detail}"

}

mailcmd_sendmail() {
  # based on http://linux.die.net/man/8/sendmail.sendmail
  echo -e "From: ${EMAIL_FROM}\nSubject: ${EMAIL_SUBJECT}\n" | cat - "${LOGFILE}" | ${MAILCMD} "${EMAIL_TO}"
}
mailcmd_ssmtp() {
  # based on http://linux.die.net/man/8/ssmtp
  echo -e "From: ${EMAIL_FROM}\nSubject: ${EMAIL_SUBJECT}\n" | cat - "${LOGFILE}" | ${MAILCMD} "${EMAIL_TO}"
}
mailcmd_msmtp() {
  # based on http://manpages.ubuntu.com/manpages/precise/en/man1/msmtp.1.html
  echo -e "Subject: ${EMAIL_SUBJECT}\n" | cat - "${LOGFILE}" | ${MAILCMD} -f "${EMAIL_FROM}" -- "${EMAIL_TO}"
}
mailcmd_bsd_mailx() {
  # based on http://man.he.net/man1/bsd-mailx
  ${MAILCMD} -s "${EMAIL_SUBJECT}" -a "From: ${EMAIL_FROM}" "${EMAIL_TO}" < "${LOGFILE}"
}
mailcmd_heirloom_mailx() {
  # based on http://heirloom.sourceforge.net/mailx/mailx.1.html
  ${MAILCMD} -s "${EMAIL_SUBJECT}" -S from="${EMAIL_FROM}" "${EMAIL_TO}" < "${LOGFILE}"
}
mailcmd_nail() {
  # based on http://linux.die.net/man/1/nail
  ${MAILCMD} -s "${EMAIL_SUBJECT}" -r "${EMAIL_FROM}" "${EMAIL_TO}" < "${LOGFILE}"
}
mailcmd_else() {
  ${MAILCMD} "${EMAIL_SUBJECT}" "${EMAIL_FROM}" "${EMAIL_TO}" < "${LOGFILE}"
}

email_logfile()
{
  echo "sending email..."
  if [ -n "${EMAIL_TO}" ]; then

      MAILCMD=$(command -v "${MAIL}")
      MAILCMD_REALPATH=$(readlink -e "${MAILCMD}")
      MAILCMD_BASENAME=${MAILCMD_REALPATH##*/}

      if [ ! -x "${MAILCMD}" ]; then
          echo -e "Email couldn't be sent. ${MAIL} not available." >&2
      else
          EMAIL_SUBJECT=${EMAIL_SUBJECT:="duplicity-backup ${BACKUP_STATUS:-"ERROR"} (${HOSTNAME}) ${LOG_FILE}"}
          case ${MAIL} in
            ssmtp)
              mailcmd_ssmtp;;
            msmtp)
              mailcmd_msmtp;;
            mail|mailx)
              case ${MAILCMD_BASENAME} in
                bsd-mailx|mail.mailutils)
                  mailcmd_bsd_mailx;;
                heirloom-mailx)
                  mailcmd_heirloom_mailx;;
                s-nail)
                  mailcmd_nail;;
                *)
                  mailcmd_else;;
              esac
              ;;
            sendmail)
              mailcmd_sendmail;;
            nail)
              mailcmd_nail;;
            *)
              mailcmd_else;;
          esac

          echo -e "Email notification sent to ${EMAIL_TO} using ${MAIL}"
      fi
  else
    echo "[skipped]: EMAIL_TO not set"
  fi
}

send_notification()
{
  echo "sending notification..."
  if [ -n "${NOTIFICATION_SERVICE}" ]; then
    echo "-----------[ Notification Request ]-----------"
    NOTIFICATION_CONTENT="duplicity-backup ${BACKUP_STATUS:-"ERROR"} [${HOSTNAME}] - \`${LOGFILE}\`"

    if [ "${NOTIFICATION_SERVICE}" = "slack" ]; then
      curl -X POST -H 'Content-type: application/json' --data "{\"text\": \"${NOTIFICATION_CONTENT}\", \"channel\": \"${SLACK_CHANNEL}\", \"username\": \"${SLACK_USERNAME}\", \"icon_emoji\": \":${SLACK_EMOJI}:\"}" "${SLACK_HOOK_URL}"
    elif [ "${NOTIFICATION_SERVICE}" = "ifttt" ]; then
      curl -X POST -H 'Content-type: application/json' --data "{\"value1\": \"${NOTIFICATION_CONTENT}\", \"value2\": \"${IFTTT_VALUE2}\"}" "${IFTTT_HOOK_URL}"
    elif [ "${NOTIFICATION_SERVICE}" = "pushover" ]; then
      curl -s \
      -F "token=${PUSHOVER_TOKEN}" \
      -F "user=${PUSHOVER_USER}" \
      -F "message=${NOTIFICATION_CONTENT}" \
      https://api.pushover.net/1/messages
    elif [ "${NOTIFICATION_SERVICE}" = "telegram" ]; then
      curl -s --max-time 10 -d "chat_id=${TELEGRAM_CHATID}&disable_web_page_preview=1&text=${NOTIFICATION_CONTENT}" "https://api.telegram.org/bot${TELEGRAM_KEY}/sendMessage" >/dev/null
    fi

    echo -e "\n----------------------------------------------\n"

    if [ "${NOTIFICATION_SERVICE}" = "slack" ]; then
      echo -e "Slack notification sent to channel ${SLACK_CHANNEL}"
    elif [ "${NOTIFICATION_SERVICE}" = "ifttt" ]; then
      echo -e "IFTTT notification sent to Maker channel event ${IFTTT_EVENT}"
    elif [ "${NOTIFICATION_SERVICE}" = "pushover" ]; then
      echo -e "Pushover notification sent"
    elif [ "${NOTIFICATION_SERVICE}" = "telegram" ]; then
      echo -e "Telegram notification sent"
    fi
  else
    echo "skipped: NOTIFICATION_SERVICE not set"
  fi
}

get_lock()
{
  echo "Attempting to acquire lock ${LOCKFILE}" >&5
  if ( set -o noclobber; echo "$$" > "${LOCKFILE}" ) 2> /dev/null; then
      # The lock succeeded. Create a signal handler to remove the lock file when the process terminates.
      trap 'EXITCODE=$?; echo "Removing lock. Exit code: ${EXITCODE}" >> ${LOGFILE}; rm -f "${LOCKFILE}"' EXIT
      echo "successfully acquired lock." >&5
  else
      # Write lock acquisition errors to log file and stderr
      echo "lock failed, could not acquire ${LOCKFILE}" >&2
      echo "lock held by $(cat "${LOCKFILE}")" >&2
      email_logfile
      send_notification
      exit 2
  fi
}

get_remote_file_size()
{
  echo "---------[ Destination Disk Use Information ]--------"
  local friendly_type_name tmpdest
  case "${DEST_PROTO}" in
    "ssh")
      friendly_type_name="SSH"

      tmpdest="${DEST#*://*/}"
      # shellcheck disable=SC2295
      tmpdest="${DEST%/${tmpdest}}"
      ssh_opt=$(echo "${STATIC_OPTIONS}" |awk -vo="--ssh-options=" '{s=index($0,o); if (s) {s=substr($0,s+length(o)); m=substr(s,0,1); for (i=2; i < length(s); i++) { if (substr(s,i,1) == m && substr(s,i-1,1) != "\\\\") break; } print substr(s,2,i-2)}}')

      # shellcheck disable=SC2295
      SIZE=$(${tmpdest%://*} "${ssh_opt}" "${tmpdest#*//}" du -hs "${DEST#${tmpdest}/}" | awk '{print $1}')
      # shellcheck disable=SC2295
      EMAIL_SUBJECT="${EMAIL_SUBJECT} ${SIZE} $(${tmpdest%://*} "${ssh_opt}" "${tmpdest#*//}" df -hP "${DEST#${tmpdest}/}" | awk '{tmp=$5 " used"}END{print tmp}')"
    ;;
    "file")
      friendly_type_name="File"
      tmpdest="${DEST#file://*}"
      SIZE=$(du -hs "${tmpdest}" | awk '{print $1}')
    ;;
    "gs")
      friendly_type_name="Google Cloud Storage"
      if ${GSCMD_AVAIL} ; then
        #tmpdest=$(echo "${DEST}" | sed -e "s/\/*$//" )
        tmpdest=${DEST//\/*$/}
        SIZE=$(gsutil du -hs "${tmpdest}" | awk '{print $1$2}')
      fi
    ;;
    "s3"|"s3+http")
      friendly_type_name="Amazon S3"
      if ${S3CMD_AVAIL} ; then
          tmpdest=$(echo "${DEST}" | cut -f 3- -d /)
          if [[ "${DEST_PROTO}" == "s3" ]]; then
              # Strip off the host name, too.
              tmpdest=$(echo "${tmpdest}" | cut -f 2- -d /)
          fi
          SIZE=$(${S3CMD} du -H s3://"${tmpdest}" | awk '{print $1}')
      else
          if ! ${S3CMD_CONF_FOUND} ; then
              SIZE="-s3cmd config not found-"
          else
              SIZE="-s3cmd not found in PATH-"
          fi
      fi
    ;;
    "b2")
      friendly_type_name="Backblaze B2"
      if ${B2CMD_AVAIL}; then
        if [[ -n ${FTP_PASSWORD} ]]; then
          APP_KEY=${FTP_PASSWORD}
        else
          APP_KEY=$(echo "${DEST}" | cut -d":" -f 3 | cut -d"@" -f 1)
        fi
        ACC_ID=$(echo "${DEST}" | cut -d"/" -f 3 | cut -d"@" -f 1 | cut -d ":" -f 1)
        BUCKET=$(echo "${DEST}" | cut -d"@" -f2 | cut -d"/" -f1)
        if [[ -z ${APP_KEY} ]] || [[ -z ${ACC_ID} ]]; then
          SIZE="-b2 authentication wrong-"
          return
        fi
        if [[ -z ${BUCKET} ]]; then
          SIZE="-b2 bucket wrong-"
          return
        fi
        if [[ $(${B2CMD} authorize-account "${ACC_ID}" "${APP_KEY}" >/dev/null 2>&1) -ne 0 ]]; then
          SIZE="-b2 authentication wrong-"
          return
        fi
        SIZE=$(${B2CMD} ls --long "${BUCKET}" | awk '{ print $5 }' | paste -sd+ | bc | numfmt --to=iec)
      else
              SIZE="-b2 not found in PATH-"
      fi
    ;;
    *)
      # not yet available for the other backends
      friendly_type_name=""
      echo "Destination disk use information is currently only available for the following storage backends:"
      echo "File, SSH, Amazon S3, Google Cloud and Backblaze B2"
    ;;
  esac

  if [[ -n "${friendly_type_name}" ]] ; then
      echo -e "${SIZE}\t${friendly_type_name} type backend\\n"
  fi
}

include_exclude()
{
  # Changes to handle spaces in directory names and filenames
  # and wrapping the files to include and exclude in quotes.
  OLDIFS=$IFS
  IFS=$(echo -en "\t\n")

  # Exclude device files?
  if [ -n "${EXDEVICEFILES}" ] && [ "${EXDEVICEFILES}" -ne 0 ]; then
    TMP=" --exclude-device-files"
    EXCLUDE=${EXCLUDE}${TMP}
  fi

  for include in "${INCLIST[@]}"
  do
    if [[ -n "$include" ]]; then
      TMP=" --include='$include'"
      INCLUDE=${INCLUDE}${TMP}
    fi
  done

  for exclude in "${EXCLIST[@]}"
  do
    if [[ -n "$exclude" ]]; then
      TMP=" --exclude '$exclude'"
      EXCLUDE=${EXCLUDE}${TMP}
    fi
  done

  # Include/Exclude globbing filelist
  if [ "${INCEXCFILE}" != '' ]; then
    if [ ${LT07} -eq 1 ]; then
      TMP=" --include-globbing-filelist '${INCEXCFILE}'"
    else
      TMP=" --include-filelist '${INCEXCFILE}'"
    fi
    INCLUDE=${INCLUDE}${TMP}
  fi

  # INCLIST and globbing filelist is empty so every file needs to be saved
  if [ ${#INCLIST[@]} -eq 0 ] && [ "${INCEXCFILE}" == '' ]; then
    EXCLUDEROOT=''
  else
    EXCLUDEROOT="--exclude=**"
  fi


  # Restore IFS
  IFS=$OLDIFS
}

_duplicity_cmd()
{
  local duplicity_cmd=
  duplicity_cmd=("${DUPLICITY}" "$*")
  # avoid to set this common variables anywhere
  duplicity_cmd+=("${STATIC_OPTIONS}" "${ENCRYPT}" "${DEST}")

  DUPLICITY_ERRCODE=${DUPLICITY_ERRCODE:-0}
  echo "executing: ${duplicity_cmd[*]}"
  if ! bash -c "${duplicity_cmd[*]}"; then
    DUPLICITY_ERRCODE=1
  fi
}

duplicity_cleanup()
{
  echo "----------------[ Duplicity Cleanup ]----------------"
  echo -e ":: Step 1 - Clean-up command: ${CLEAN_UP_TYPE}\\n"
  case "${CLEAN_UP_TYPE}" in
    "remove-older-than"|"remove-all-but-n-full")
      if [[ -n "${CLEAN_UP_VARIABLE}" ]]; then
        _duplicity_cmd "${CLEAN_UP_TYPE}" "${CLEAN_UP_VARIABLE}" --force
        echo
      else
        echo "[skipped]: CLEAN_UP_VARIABLE not set"
      fi
      ;;
    "none"|*)
      echo "disabled"
      ;;
  esac

  echo -e ":: Step 2 - Delete incremental sets of all backups sets older than the N:th last full backup\\n"
  if [[ -n "${REMOVE_INCREMENTALS_OLDER_THAN}" ]]; then
    echo "N=${REMOVE_INCREMENTALS_OLDER_THAN}"
    if [[ ${REMOVE_INCREMENTALS_OLDER_THAN} =~ ^[0-9]+$ && ${REMOVE_INCREMENTALS_OLDER_THAN} -gt 0 ]]; then
      _duplicity_cmd "remove-all-inc-of-but-n-full" "${REMOVE_INCREMENTALS_OLDER_THAN}"  --force
    else
      echo "WARN: REMOVE_INCREMENTALS_OLDER_THAN must be a number above 0"
    fi
    echo
  else
    echo "[skipped]: REMOVE_INCREMENTALS_OLDER_THAN not set"
  fi
}

duplicity_backup()
{
  local command=$1
  case "${command}" in
    "full"|"incremental"|"incr"|"verify"|"restore")
      ;;
    *)
      echo "ERROR: invalid option: $1" >&2
      exit 1
      ;;
  esac

  _duplicity_cmd "${command}" "${VERBOSITY}" \
                 "${EXCLUDE}" \
                 "${INCLUDE}" \
                 "${EXCLUDEROOT}" \
                 "${ROOT}"
}

setup_passphrase()
{
  if [ -n "${GPG_ENC_KEY}" ] && [ -n "${GPG_SIGN_KEY}" ] && [ "${GPG_ENC_KEY}" != "${GPG_SIGN_KEY}" ]; then
    echo -n "Please provide the passphrase for decryption (GPG key 0x${GPG_ENC_KEY}): " >&3
    builtin read -s -r ENCPASSPHRASE
    echo -ne "\n" >&3
    PASSPHRASE=${ENCPASSPHRASE}
    export PASSPHRASE
  fi
}

get_file_sizes()
{
  get_remote_file_size
}

backup_this_script()
{
  local script_file script_path tmpdir tmp_filename readme
  if [[ "${0:0:1}" == "." ]]; then
    script_file="${0:2}"
    script_path="$(pwd)/${script_file}"
  else
    script_path=$(command -v "${0}")
  fi

  tmpdir="duplicity-backup-$(date +'%Y-%m-%d')"
  tmp_filename="${tmpdir}.tar.gpg"
  readme="${tmpdir}/README"

  echo "You are backing up: " >&3
  echo "      1. ${script_path}" >&3

  if [[ -n "${GPG_ENC_KEY}" && -n "${GPG_SIGN_KEY}" ]]; then
    if [[ "${GPG_ENC_KEY}" == "${GPG_SIGN_KEY}" ]]; then
      echo "      2. GPG Secret encryption and sign key: ${GPG_ENC_KEY}" >&3
    else
      echo "      2. GPG Secret encryption key: ${GPG_ENC_KEY} and GPG secret sign key: ${GPG_SIGN_KEY}" >&3
    fi
  else
    echo "      2. GPG Secret encryption and sign key: none (symmetric encryption)" >&3
  fi

  if [[ -n "${CONFIG}" && -f "${CONFIG}" ]]; then
    echo "      3. Config file: ${CONFIG}" >&3
  fi

  if [[ -n "${INCEXCFILE}" &&  -f "${INCEXCFILE}" ]]; then
    echo "      4. Include/Exclude globbing file: ${INCEXCFILE}" >&3
  fi

  echo "Backup tarball will be encrypted and saved to: $(pwd)/${tmp_filename}" >&3
  echo >&3
  echo ">> Are you sure you want to do that ('yes' to continue)?" >&3
  read -r ANSWER
  if [[ "${ANSWER}" != "yes" ]]; then
    echo "You said << ${ANSWER} >> so I am exiting now." >&3
    echo -e "---------------------    END    ---------------------\n" >&5
    exit 1
  fi

  mkdir "${tmpdir}" || return 1

  cp "${script_path}" "${tmpdir}"
  [[ -n "${CONFIG}" && -f "${CONFIG}" ]] && cp "${CONFIG}" "${tmpdir}"
  [[ -n "${INCEXCFILE}" && -f "${INCEXCFILE}" ]] && cp "${INCEXCFILE}" "${tmpdir}"

  # must be set even if no encryption into configuration: used for archive's symmetric encryption
  GPG_TTY=$(tty)
  export GPG_TTY

  if [[ -n "${GPG_ENC_KEY}" && -n "${GPG_SIGN_KEY}" ]]; then
    if [[ "${GPG_ENC_KEY}" == "${GPG_SIGN_KEY}" ]]; then
      gpg -a --export-secret-keys "${KEYRING}" "${GPG_ENC_KEY}" > "${tmpdir}/duplicity-backup-encryption-and-sign-secret.key.txt"
    else
      gpg -a --export-secret-keys "${KEYRING}" "${GPG_ENC_KEY}" > "${tmpdir}/duplicity-backup-encryption-secret.key.txt"
      gpg -a --export-secret-keys "${KEYRING}" "${GPG_SIGN_KEY}" > "${tmpdir}/duplicity-backup-sign-secret.key.txt"
    fi
  fi

  cat > "${readme}" <<EOF

In case you've long forgotten, this is a backup script that you used to backup some files
(most likely remotely at Amazon S3). In order to restore these files,
you first need to import your GPG private(s) key(s) (if you haven't already).
The key(s) is/are in this directory and the following command(s) should do the trick:

If you were using the same key for encryption and signature:
  gpg --allow-secret-key-import --import duplicity-backup-encryption-and-sign-secret.key.txt
Or if you were using two separate keys for encryption and signature:
  gpg --allow-secret-key-import --import duplicity-backup-encryption-secret.key.txt
  gpg --allow-secret-key-import --import duplicity-backup-sign-secret.key.txt

After your key(s) has/have been successfully imported, you should be able to restore your files.

Good luck!
EOF

  local ret_code
  echo "Encrypting tarball, choose a password you'll remember..." >&3
  tar -cf - "${tmpdir}" | gpg -aco "${tmp_filename}"
  # ensure the previous commands succeeds
  if [[ $((PIPESTATUS[0] + PIPESTATUS[1])) -eq 0 ]]; then
    echo -e "\nIMPORTANT!!" >&3
    echo ">> To restore these files, run the following (remember your password):" >&3
    echo "gpg -d ${tmp_filename} | tar -xf -" >&3
    echo -e "\nYou may want to write the above down and save it with the file." >&3
    ret_code=0
  else
    ret_code=1
  fi
  rm -Rfv "${tmpdir:?}"
  return ${ret_code}
}

# usage: check_required_binaries <binary1> <binary2> ...
check_required_binaries()
{
  local req_bin missing_bin=()
  # check required bins
  for req_bin in "$@"
  do
    type -p "${req_bin}" >/dev/null || missing_bin+=("${req_bin}")
  done

  if [[ ${#missing_bin[@]} -gt 0 ]]; then
    echo "missing binaries: ${missing_bin[*]}"
    return 1
  fi
}

# ##################################################
# ####        end of functions definition       ####
# ##################################################

check_required_binaries tar pinentry || exit 1

check_variables


echo -e "--------    START DUPLICITY-BACKUP SCRIPT for ${HOSTNAME}   --------\n" >&5

echo -e "-------[ Program versions ]-------"
echo -e "duplicity-backup.sh ${DBSH_VERSION}"
echo -e "duplicity ${DUPLICITY_VERSION}"
echo -e "----------------------------------\n"

get_lock

INCLUDE=
EXCLUDE=
EXCLUDEROOT=

case "${COMMAND}" in
  "backup-script")
    if ! backup_this_script; then
      echo -e "\\nconfig+secrets backup has failed" >&2
      exit 1
    fi
    exit 0
  ;;

  "full")
    include_exclude
    duplicity_backup "full"
    duplicity_cleanup
    get_file_sizes
  ;;

  "verify")
    OLDROOT=${ROOT}
    ROOT=${DEST}
    DEST=${OLDROOT}

    echo -e "-------[ Verifying Source & Destination ]-------\n"
    include_exclude
    setup_passphrase
    echo -e "Attempting to verify now ...\n" >&3
    duplicity_backup "verify"
    echo

    OLDROOT=${ROOT}
    ROOT=${DEST}
    DEST=${OLDROOT}

    get_file_sizes

    echo -e "Verify complete.\n" >&3
  ;;

  "cleanup")
    if [ -z "${DRY_RUN}" ]; then
      STATIC_OPTIONS="${STATIC_OPTIONS} --force"
    fi

    echo -e "-------[ Cleaning up Destination ]-------\n"
    setup_passphrase
    _duplicity_cmd "cleanup" "${VERBOSITY}"
    echo -e "Cleanup complete."
  ;;

  "restore")
    ROOT=${DEST}
    if [ -n "${TIME}" ]; then
      STATIC_OPTIONS="${STATIC_OPTIONS} --time ${TIME}"
    fi

    if [[ ! "${RESTORE_DEST}" ]]; then
      echo "Please provide a destination path (eg, /home/user/dir):" >&3
      read -r -e NEWDESTINATION
      DEST=${NEWDESTINATION}
      echo ">> You will restore from ${ROOT} to ${DEST}" >&3
      echo "Are you sure you want to do that ('yes' to continue)?" >&3
      read -r ANSWER
      if [[ "${ANSWER}" != "yes" ]]; then
        echo "You said << ${ANSWER} >> so I am exiting now." >&3
        echo -e "User aborted restore process ...\n" >&2
        echo -e "---------------------    END    ---------------------\n" >&5
        exit 1
      fi
    else
      DEST=${RESTORE_DEST}
    fi

    setup_passphrase
    echo "Attempting to restore now ..." >&3
    duplicity_backup "restore"
  ;;

  "restore-file"|"restore-dir")
    ROOT=${DEST}

    if [ -n "${TIME}" ]; then
      STATIC_OPTIONS="${STATIC_OPTIONS} --time ${TIME}"
    fi

    if [[ ! "${FILE_TO_RESTORE}" ]]; then
      echo "Which file or directory do you want to restore?" >&3
      echo "(give the path relative to the root of the backup eg, mail/letter.txt):" >&3
      read -r -e FILE_TO_RESTORE
      echo
    fi

    if [[ "${RESTORE_DEST}" ]]; then
      DEST=${RESTORE_DEST}
    else
      DEST=$(basename "${FILE_TO_RESTORE}")
    fi

    echo -e "YOU ARE ABOUT TO..." >&3
    echo -e ">> RESTORE: ${FILE_TO_RESTORE}" >&3
    echo -e ">> TO: ${DEST}" >&3
    echo -e "\nAre you sure you want to do that ('yes' to continue)?" >&3
    read -r ANSWER
    if [ "${ANSWER}" != "yes" ]; then
      echo "You said << ${ANSWER} >> so I am exiting now." >&3
      echo -e "User aborted restore process ...\n" >&2
      echo -e "---------------------    END    ---------------------\n" >&5
      exit 1
    fi

    FILE_TO_RESTORE="'${FILE_TO_RESTORE}'"
    DEST="'${DEST}'"

    setup_passphrase
    echo "Restoring now ..." >&3
    #use INCLUDE variable without creating another one
    INCLUDE="--file-to-restore ${FILE_TO_RESTORE}"
    duplicity_backup "restore"
  ;;

  "list-current-files")
    if [ -n "${TIME}" ]; then
      STATIC_OPTIONS="${STATIC_OPTIONS} --time ${TIME}"
    fi
    _duplicity_cmd "list-current-files" "${VERBOSITY}"
  ;;

  "collection-status")
    _duplicity_cmd "collection-status" "${VERBOSITY}"
  ;;

  "backup")
    include_exclude
    duplicity_backup "incremental"
    duplicity_cleanup
    get_file_sizes
  ;;

  *)
    echo -e "[Only show $(basename "$0") usage options]\n"
    usage
  ;;
esac

echo -e "---------    END DUPLICITY-BACKUP SCRIPT    ---------\n" >&5

if [ "${USAGE}" ]; then
  exit 0
fi

if [[ ${DUPLICITY_ERRCODE} -eq 1 ]]; then
  BACKUP_STATUS="ERROR"
  # send email or notification on error
  [[ "${EMAIL_FAILURE_ONLY}" == "yes" ]] && email_logfile
  [[ "${NOTIFICATION_FAILURE_ONLY}" == "yes" ]] && send_notification
else
  BACKUP_STATUS="OK"
fi

echo -e "\\nReport:"
echo "STATUS: ${BACKUP_STATUS} (DUPLICITY_ERRCODE: ${DUPLICITY_ERRCODE})"

# remove old logfiles
# stops them from piling up infinitely
[[ -n "${REMOVE_LOGS_OLDER_THAN}" ]] && find "${LOGDIR}" -type f -mtime +"${REMOVE_LOGS_OLDER_THAN}" -delete

unset AWS_ACCESS_KEY_ID
unset AWS_SECRET_ACCESS_KEY
unset GS_ACCESS_KEY_ID
unset GS_SECRET_ACCESS_KEY
unset SWIFT_USERNAME
unset SWIFT_PASSWORD
unset SWIFT_AUTHURL
unset SWIFT_AUTHVERSION
unset DPBX_ACCESS_TOKEN
unset PASSPHRASE
unset SIGN_PASSPHRASE
unset FTP_PASSWORD

# restore stdout and stderr to their original values
# and close the other fd
exec 1>&6 2>&7 3>&- 4>&- 5>&- 6>&- 7>&-

# set Duplicity error code as script's error code
exit "${DUPLICITY_ERRCODE}"

# vim: set tabstop=2 shiftwidth=2 sts=2 autoindent smartindent:
