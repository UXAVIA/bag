# Source this to point tools/store/asc_publish.py at the team API key:
#   source tools/store/asc_env.sh
# Reads ~/.secrets/aerocommute/key_issuer_id.txt (KeyID line + issuer UUID) and the matching AuthKey_<id>.p8.
_f=~/.secrets/aerocommute/key_issuer_id.txt
export ASC_KEY_ID=$(grep -i "^KeyID" "$_f" | awk '{print $2}' | tr -d '\r')
export ASC_ISSUER_ID=$(grep -o "[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}" "$_f" | head -1)
export ASC_KEY_PATH=~/.secrets/aerocommute/AuthKey_${ASC_KEY_ID}.p8
export ASC_PY=/mnt/fedora-home/hannibalp/LocalRepos/pdf_blank_remove/tools/calibrate/.venv/bin/python
unset _f
