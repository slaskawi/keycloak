#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${ROOT_DIR}/sources.tsv"

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required to download the reference PDFs" >&2
  exit 1
fi

extract_text=false
if command -v pdftotext >/dev/null 2>&1; then
  extract_text=true
else
  echo "pdftotext not found; PDFs will be downloaded without text extraction" >&2
fi

tail -n +2 "${MANIFEST}" | while IFS=$'\t' read -r group pdf_path txt_path source_url title; do
  [ -n "${group}" ] || continue

  pdf_file="${ROOT_DIR}/${pdf_path}"
  txt_file="${ROOT_DIR}/${txt_path}"
  mkdir -p "$(dirname "${pdf_file}")"

  if [ ! -s "${pdf_file}" ]; then
    echo "Downloading ${title}"
    curl -L -f --retry 3 --retry-delay 2 --output "${pdf_file}" "${source_url}"
  else
    echo "Keeping existing ${pdf_path}"
  fi

  if [ "${extract_text}" = true ]; then
    if [ ! -s "${txt_file}" ] || [ "${pdf_file}" -nt "${txt_file}" ]; then
      echo "Extracting text ${txt_path}"
      pdftotext -layout "${pdf_file}" "${txt_file}"
    fi
  fi
done

echo "Reference download complete."
