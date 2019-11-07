#!/usr/bin/env bash
# export helper functions for aquiva buildpack

header() {
  echo "" || true
  echo -e "-----> \e[34m$*\033[0m" || true
  echo "" || true
}

log() {
  echo -e "       $*"
}
