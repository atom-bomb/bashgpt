#!/bin/bash
#
# bashgpt.sh
#
# here is a simple markov chain chat engine in bash
# incoming text is built into a directed graph of words with weights
# applied to probable next words.
#

SCRIPTNAME=$0

TOOLS="grep tr sed cat" 
MISSING_TOOLS=""

ucase() {
  if [ "`which tr`" != "" ]; then
    echo ${1} | tr '[a-z]' '[A-Z]'
  else
    echo ${1^^}
  fi
}

for TOOL in ${TOOLS}; do
  WHICH_TOOL=$(which ${TOOL})
  eval $(ucase ${TOOL})=${WHICH_TOOL}
  if [ "${WHICH_TOOL}" = "" ]; then
    MISSING_TOOLS="${MISSING_TOOLS} ${TOOL}"
  fi
done

if [ "${MISSING_TOOLS}" != "" ]; then
  echo "${SCRIPTNAME} Missing the following tools" >&2
  echo ${MISSING_TOOLS} >&2
  exit 1
fi

data_filename=bashgpt.dat
read_filename=

bidirectional=1

var_prefix=BG

begin_tag=__BEGIN__
end_tag=__END__

comma_tag=__COMMA__
period_tag=__PERIOD__
question_tag=__QM__
bang_tag=__BANG__
number_tag=__NUM__

QUIET=0

debug() {
  if [ "${VERBOSE}" = "1" ]; then
    echo $@ >&2
  fi
}

info() {
  if [ "${QUIET}" != "1" ]; then
    echo $@ >&2
  fi
}

warning() {
  echo $@ >&2
}

error_exit() {
  echo $@ >&2
  exit 1
}

help_exit() {
  echo "${SCRIPTNAME} usage:" >&2
  echo "-h             : print this help and exit" >&2
  echo "-v             : verbose output" >&2
  echo "-d <filename>  : restore and save graph from given filename" >&2
  echo "-r <filename>  : read text from filename" >&2
  exit 1
}

# add a next word for a given word
function add_next_word() {
  local this_word=$1
  local next_word=$2
  local prev_word=$3

  local this_prev_nexts=${var_prefix}_${prev_word}_${this_word}_nexts
  local this_prev_counts=${var_prefix}_${prev_word}_${this_word}_counts
  local this_prev_total=${var_prefix}_${prev_word}_${this_word}_total

  local prev_next_words
  eval prev_next_words=\$\{$this_prev_nexts\[\@\]\}

  local old_prev_total
  eval old_prev_total=\$${this_prev_total}
  eval ${this_prev_total}=$(( ${old_prev_total} + 1 ))

  if [[ " ${prev_next_words} " = *" $next_word "* ]]; then
    # old next word, increment the count
    local num_prev_next_words
    eval num_prev_next_words=\$\{\#$this_prev_nexts\[\@\]\}
    local i=0
 
    while [ $i -lt ${num_prev_next_words} ]; do
      local a_word
      local a_count
      eval a_word=\$\{$this_prev_nexts\[$i\]\}
      if [ "${a_word}" = "${next_word}" ]; then
        eval a_count=\$\{$this_prev_counts\[$i\]\}
        eval $this_prev_counts\[$i\]=$(( ${a_count} + 1 ))
        break
      fi
      (( i++ ))
    done
  else
    # new next word
    eval ${this_prev_nexts}+=\(${next_word}\)
    eval ${this_prev_counts}+=\(1\)
  fi

  local this_nexts=${var_prefix}_${this_word}_nexts
  local this_counts=${var_prefix}_${this_word}_counts
  local this_total=${var_prefix}_${this_word}_total

  local next_words
  eval next_words=\$\{$this_nexts\[\@\]\}

  local old_total
  eval old_total=\$${this_total}
  eval ${this_total}=$(( ${old_total} + 1 ))

  if [[ " ${next_words} " = *" $next_word "* ]]; then
    # old next word, increment the count
    local num_next_words
    eval num_next_words=\$\{\#$this_nexts\[\@\]\}
    local i=0
 
    while [ $i -lt ${num_next_words} ]; do
      local a_word
      local a_count
      eval a_word=\$\{$this_nexts\[$i\]\}
      if [ "${a_word}" = "${next_word}" ]; then
        eval a_count=\$\{$this_counts\[$i\]\}
        eval $this_counts\[$i\]=$(( ${a_count} + 1 ))
        break
      fi
      (( i++ ))
    done
  else
    # new next word
    eval ${this_nexts}+=\(${next_word}\)
    eval ${this_counts}+=\(1\)
  fi

  if [ "${bidirectional}" != "1" ]; then
    return
  fi

  # bidirectional case
  local next_prevs=${var_prefix}_${next_word}_prevs
  local next_counts=${var_prefix}_${next_word}_prev_counts
  local next_total=${var_prefix}_${next_word}_prev_total
  local prev_words
  eval prev_words=\$\{$next_prevs\[\@\]\}

  local old_total
  eval old_total=\$${next_total}
  eval ${next_total}=$(( ${old_total} + 1 ))

  if [[ " ${prev_words} " = *" $this_word "* ]]; then
    # old prev word, increment the count
    local num_prev_words
    eval num_prev_words=\$\{\#$next_prevs\[\@\]\}
    local i=0
 
    while [ $i -lt ${num_prev_words} ]; do
      local a_word
      local a_count
      eval a_word=\$\{$next_prevs\[$i\]\}
      if [ "${a_word}" = "${this_word}" ]; then
        eval a_count=\$\{$next_counts\[$i\]\}
        eval $next_counts\[$i\]=$(( ${a_count} + 1 ))
        break
      fi
      (( i++ ))
    done
  else
    # new next word
    eval ${next_prevs}+=\(${prev_word}\)
    eval ${next_counts}+=\(1\)
  fi
}

ingest_prev_word=${begin_tag}
ingest_this_word=${begin_tag}
ingest_next_word=${begin_tag}

# pick words off of a given line and add them to the graph
function ingest_line() {
  local this_line=$1
  local skip_trash
  local skip
  local end

  this_line="${1//)/}"

  if [ "${this_line}" != "${1}" ]; then
    warning "Hack around parens ${1} -> ${this_line}"
  fi

  while [ "${this_line}" != "" ]; do
    ingest_prev_word="${ingest_this_word}"
    ingest_this_word="${ingest_next_word}"
    ingest_next_word="$(expr "${this_line}" : "[ -/\:-@\[-\`{-\~]*\([A-Za-z0-9\']*\)")"
    skip_trash="$(expr "${this_line}" : "\([ -/\:-@\[-\`{-\~]*\)[A-Za-z0-9\']*")"

    debug "Prev ${ingest_prev_word}"
    debug "This ${ingest_this_word}"
    debug "Next ${ingest_next_word}"
    debug "Trash ${skip_trash}"
    debug "Line ${this_line}"

    case "${skip_trash}" in
       .*)
        ingest_next_word=${period_tag}
        skip=${#skip_trash}
        end=1
        ;;
      \?*)
        ingest_next_word=${question_tag}
        skip=${#skip_trash}
        end=1
        ;;
      \!*)
        ingest_next_word=${bang_tag}
        skip=${#skip_trash}
        end=1
        ;;
      \,*)
        ingest_next_word=${comma_tag}
        skip=${#skip_trash}
        end=0
        ;;
      *)
        ingest_next_word="${ingest_next_word//\'/_}"
        skip=$(( ${#skip_trash} + ${#ingest_next_word} ))
        end=0
        ;;
    esac

    this_line="${this_line:${skip}}"

    case "${ingest_next_word}" in
      [0-9]*)
        ingest_next_word=${number_tag}${ingest_next_word}
        ;;

      *)
        ;;
    esac

    if [ "${ingest_next_word}" != "" ]; then
      add_next_word "${ingest_this_word}" "${ingest_next_word}" "${ingest_prev_word}"

      # seems to be the end of an incoming sentence
      if [ ${end} -eq 1 ]; then
        add_next_word "${ingest_next_word}" "${end_tag}" "${ingest_this_word}"
        ingest_this_word="${begin_tag}"
        ingest_next_word="${begin_tag}"
      fi
    fi

    if [ ${skip} -eq 0 ]; then
      warning "Parse error at ${this_line}"
      break
    fi
  done
}

# keep reading stdin and adding words to the graph
function ingest_lines_from_stdin() {
  local line

  while read line; do
    debug "${line}"
    ingest_line "${line}"
  done

  # save off the graph
  info "Saving ${data_filename}"
  set | ${GREP} -E "^${var_prefix}_" > ${data_filename}
}

# expand magic punctuation into printable text
function expand_tag() {
  local word="$1"

  case "${word}" in
    ${number_tag}[0-9]*)
      echo "${word/${number_tag}/} "
      ;;
    ${comma_tag})
      echo ", "
      ;;
    ${period_tag})
      echo ". "
      ;;
    ${question_tag})
      echo "? "
      ;;
    ${bang_tag})
      echo "! "
      ;;
    *)
      echo "${word//_/\'}"
      ;;
  esac
}

# get a random word that follows the given word
function get_next_word() {
  local this_word=$1
  local prev_word=$2

  local this_prev_nexts=${var_prefix}_${prev_word}_${this_word}_nexts
  local this_prev_counts=${var_prefix}_${prev_word}_${this_word}_counts
  local this_prev_total=${var_prefix}_${prev_word}_${this_word}_total

  local this_nexts=${var_prefix}_${this_word}_nexts
  local this_counts=${var_prefix}_${this_word}_counts
  local this_total=${var_prefix}_${this_word}_total

  local randy
  local i
  local num_next_words
  local total

  eval total=\$${this_prev_total}
  if [ "${total}" != "" ]; then
    randy=$(( $RANDOM % ${total} ))
    i=0

    eval num_next_words=\$\{\#$this_prev_nexts\[\@\]\}
    while [ $i -lt ${num_next_words} ]; do
      local a_word
      local a_count
      eval a_count=\$\{$this_prev_counts\[$i\]\}
      if [ ${randy} -le ${a_count} ]; then
        eval a_word=\$\{$this_prev_nexts\[$i\]\}
        echo ${a_word}
        break
      fi
      randy=$(( ${randy} - ${a_count} ))
      (( i++ ))
    done
    return
  fi

  eval total=\$${this_total}

  if [ "${total}" = "" ]; then
    echo ${end_tag}
    return
  fi

  randy=$(( $RANDOM % ${total} ))
  i=0

  eval num_next_words=\$\{\#$this_nexts\[\@\]\}
  while [ $i -lt ${num_next_words} ]; do
    local a_word
    local a_count
    eval a_count=\$\{$this_counts\[$i\]\}
    if [ ${randy} -le ${a_count} ]; then
      eval a_word=\$\{$this_nexts\[$i\]\}
      echo ${a_word}
      break
    fi
    randy=$(( ${randy} - ${a_count} ))
    (( i++ ))
  done
}

# used by get_previous_word to scrape words from the graph in memory
function get_words_from_set_spew() {
  local line

  while read line; do
    expr "$line" : "BG_\(\w*\)_nexts"
  done
}

# get a random word that precedes the given word
function get_previous_word() {
  local this_word=$1

  debug "get prev ${this_word}"

  if [ "${bidirectional}" = "1" ]; then
    local this_word=$1

    local this_prevs=${var_prefix}_${this_word}_prevs
    local this_counts=${var_prefix}_${this_word}_prev_counts
    local this_total=${var_prefix}_${this_word}_prev_total

    local total
    eval total=\$${this_total}

    if [ "${total}" = "" ]; then
      echo ${begin_tag}
      return
    fi

    local randy=$(( $RANDOM % ${total} ))
    local i=0
    local num_prev_words
    eval num_prev_words=\$\{\#$this_prevs\[\@\]\}
    while [ $i -lt ${num_prev_words} ]; do
      local a_word
      local a_count
      eval a_count=\$\{$this_counts\[$i\]\}
      if [ ${randy} -le ${a_count} ]; then
        eval a_word=\$\{$this_prevs\[$i\]\}
        echo ${a_word}
        break
      fi
      randy=$(( ${randy} - ${a_count} ))
      (( i++ ))
    done
  else
    # awkwardly search memory to backwards-walk the directed graph
    local raw_words_list
    local words_list
    local words_count=0

    raw_words_list=$(set | ${GREP} -E "^${var_prefix}_\\w+_nexts.*\=\"${this_word}\"" | get_words_from_set_spew )

    while [ 1 ]; do
      local a_word=$(expr "$raw_words_list" : "\s*\(\w*\)\s*")
      local skip=$(expr "$raw_words_list" : "\(\s*\w*\s*\)")

      if [ "${a_word}" = "" ]; then
        break
      fi

      words_list+=(${a_word})
      words_count=$(( ${words_count} + 1 ))
      raw_words_list=${raw_words_list:${#skip}}
    done

    if [ ${words_count} -gt 0 ]; then
      local word_choice=$(( $RANDOM % ${words_count} ))
      echo ${words_list[${word_choice}]} 
    else
      echo ${begin_tag}
    fi
  fi
}

# build a random sentence, starting at begin_tag
function get_sentence() {
  local prev_word=""
  local this_word=${begin_tag}
  local sentence=""

  while [ 1 ]; do
    next_word=$(get_next_word ${this_word} ${prev_word})
    if [ "${next_word}" != ${end_tag} ]; then
      if [ "" = "${sentence}" ]; then
        sentence=$(expand_tag "${next_word}")
      else
        if [[ "${this_word:0:1}" = "_" ||  "${next_word:0:1}" = "_" ]]; then
          sentence=${sentence}$(expand_tag "${next_word}")
        else
          sentence="${sentence} "$(expand_tag "${next_word}")
        fi
      fi
      last_word="${this_word}"
      this_word="${next_word}"
    else
      echo "${sentence}"
      break
    fi
  done
}

# pick a word from the given sentence that has few connections in the graph
function rarest_word_in_sentence() {
  local sentence=$1
  local rarest_word
  local rarest_word_total=0
  local next_word
  local skip_trash

  sentence="${1//)/}"

  if [ "${sentence}" != "${1}" ]; then
    warning "Hack around parens ${1} -> ${sentence}"
  fi

  while [ "${sentence}" != "" ]; do
    next_word="$(expr "${sentence}" : "[ -/\:-@\[-\`\{-\~]*\([A-Za-z0-9\']*\)")"
    skip_trash="$(expr "${sentence}" : "\([ -/\:-@\[-\`\{-\~]*\)[A-Za-z0-9\']*")"
    debug "Next ${next_word}"
    debug "Trash ${skip_trash}"
    debug "Line ${sentence}"

    local skip=$(( ${#skip_trash} + ${#next_word} ))
    sentence="${sentence:${skip}}"
    if [ "${next_word}" != "" ]; then
      local total

      case "${next_word}" in
        [0-9]*)
          next_word=${number_tag}${next_word}
          ;;

        *)
          ;;
      esac

      next_word="${next_word//\'/_}"
      eval total=\$${var_prefix}_${next_word}_total
      if [ "${total}" = "" ]; then
        total=0
      else
        if [ "${rarest_word}" = "" ]; then
          rarest_word="${next_word}"
          rarest_word_total=${total}
        elif [ ${rarest_word_total} -gt ${total} ]; then
          rarest_word="${next_word}"
          rarest_word_total=${total}
        fi
      fi
    fi
  done
  debug "RARE: ${rarest_word}"
  echo "${rarest_word}"
}

# build a sentence that uses a given word
function get_sentence_using() {
  local use_word=$1
  local last_word=${use_word}
  local sentence=""

  debug "get_sentence_using x${use_word}x"

  if [ "${use_word}" = "" ]; then
    get_sentence
    return
  fi

  while [ 1 ]; do
    next_word=$(get_previous_word ${last_word})
    if [ "${next_word}" != ${begin_tag} ]; then
      if [ "" = "${sentence}" ]; then
        sentence=$(expand_tag "${next_word}")
      else
        if [[ "${last_word:0:1}" = "_" ||  "${next_word:0:1}" = "_" ]]; then
          sentence=$(expand_tag "${next_word}")${sentence}
        else
          sentence=$(expand_tag "${next_word}")" ${sentence}"
        fi
      fi
      last_word="${next_word}"
    else
      if [ "" = "${sentence}" ]; then
        sentence="$(expand_tag ${use_word})"
      else
        if [[ "${sentence: -1}" = " " ]]; then
          sentence="${sentence}$(expand_tag ${use_word})"
        else
          sentence="${sentence} $(expand_tag ${use_word})"
        fi
      fi
      break
    fi
  done

  last_word=${use_word}
  while [ 1 ]; do
    next_word=$(get_next_word ${last_word})
    if [ "${next_word}" != ${end_tag} ]; then
      if [ "" = "${sentence}" ]; then
        sentence=$(expand_tag "${next_word}")
      else
        if [[ "${last_word:0:1}" = "_" ||  "${next_word:0:1}" = "_" ]]; then
          sentence=${sentence}$(expand_tag "${next_word}")
        else
          sentence="${sentence} "$(expand_tag "${next_word}")
        fi
      fi
      last_word="${next_word}"
    else
      echo "${sentence}"
      break
    fi
  done
}

while getopts ":vqhd:r:" opt; do
  case $opt in
    v)
      VERBOSE=1
      debug "Verbose Mode"
      ;;
    q)
      QUIET=1
      debug "Quiet Mode"
      ;;
    h)
      help_exit
      ;;
    d)
      data_filename=${OPTARG}
      ;;
    r)
      read_filename=${OPTARG}
      ;;
    \?)
      error_exit "Invalid option: -$OPTARG"
      ;;
    :)
      error_exit "Option -$OPTARG requires an argument."
  esac
done

if [ -f "${data_filename}" ]; then
  # read whatever graph is available
  info "Loading ${data_filename}"
  source "${data_filename}"
else
  # if no graph is available, populate some nonsense
  ingest_line "There once was a man from nantucket,"
  ingest_line "who got his foot caught in a sandwich?"
  ingest_line "His foot got caught in a sandwich!"
  ingest_line "I would tell you if I knew."
  ingest_line "Do you know what I mean?"
  ingest_line "If you know what I mean."
  ingest_line "I would like to eat a sandwich."
  ingest_line "Wow, you sure are patient!"
  ingest_line "I am a computer."
  ingest_line "This is a waste of my time and yours."
  ingest_line "Time and tide waits for no man."
  ingest_line "Man, I could sure use a drink."
fi

if [ "${read_filename}" != "" ]; then
  # ingest text from read_filename
  info "Building graph from ${read_filename}"
  if [ -f "${read_filename}" ]; then
    ${CAT} "${read_filename}" | \
      ${TR} -cd '\12\15\40-\176' | ${TR} '\r' ' ' | ${TR} '\n' ' ' | \
      ${SED} -e 's/\. /.\n/g' -e 's/\? /\?\n/g' -e 's/\! /\!\n/g' | \
      ingest_lines_from_stdin
    exit 0
  else
    error_exit "cannot open ${read_filename}"
  fi
else
  # interactive mode
  while [ 1 ]; do
    read -e -r -p "> " input
    if [ $? != 0 ]; then
      break
    fi

    ingest_line "${input}"
    get_sentence_using $(rarest_word_in_sentence "${input}")
  done
fi

# save off the graph
info "Saving ${data_filename}"
set | ${GREP} -E "^${var_prefix}_" > ${data_filename}
