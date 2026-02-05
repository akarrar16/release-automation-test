#!/bin/bash
set -e

git fetch --prune --prune-tags origin

response_body_file="response.json"

current_date=$(date '+%Y-%m-%d')
echo "Current date: ${current_date}"
tag_date=${current_date//-/.}
tag_date=v${tag_date:2}
echo "Current tag generated out of date: ${tag_date}"

# latest_tag=$(git describe --tags --match="v[0-9].[0-9].[0-9]*" $(git rev-list --tags --max-count=10) | head -n 1)
latest_tag=$(git describe --tags --match="v[0-9]*.[0-9]*.*" $(git rev-list --tags --max-count=10) 2>/dev/null | head -n 1)
echo "Found latest tag: ${latest_tag}"
latest_tag_commit_hash=$(git rev-list -n 1 ${latest_tag})
echo "latest_tag_commit_hash: $latest_tag_commit_hash"
head_commit_hash=$(git rev-parse HEAD)
echo "head_commit_hash: $head_commit_hash"
if [ "$latest_tag_commit_hash" = "$head_commit_hash" ]; then
echo "INFO: Tag $latest_tag is current head, no new tag will be created"
exit 0
fi
if [ $(git tag -l "$tag_date") ]; then
echo "ERROR: Tag $tag_date already exist!"
# exit 1
fi

if [ $(git tag -l "$tag_date") ]; then
    echo "Tag $tag_date already exists. calculating increment..."
    counter=1
    while true; do
        candidate_tag="${tag_date}.${counter}"
        if [ ! $(git tag -l "$candidate_tag") ]; then
            tag_date="$candidate_tag"
            break
        fi
        ((counter++))
    done
fi

echo "New tag will be: ${tag_date}"

echo "Creating new tag: ${tag_date}"
git tag ${tag_date}
echo "Pushing tag"
git push origin refs/tags/${tag_date}

# --- CHANGED SECTION START: GITHUB NATIVE GENERATION ---
echo "Generating Release Notes via GitHub API..."

# Define the Repo URL base (Extracted from your bottom curl command)
REPO_API_URL="https://api.github.com/repos/akarrar16/release-automation-test/releases"

# Prepare JSON payload for generation
# We check if a previous tag exists to define the range
if [ -z "$latest_tag" ]; then
    gen_payload="{\"tag_name\": \"$tag_date\"}"
else
    gen_payload="{\"tag_name\": \"$tag_date\", \"previous_tag_name\": \"$latest_tag\"}"
fi

# Call GitHub generate-notes endpoint
# We use a temporary file to store the response
gen_notes_response=$(mktemp)

http_code_gen=$(curl -s -X POST \
     -H "Authorization: Bearer $GITHUB_TOKEN" \
     -H "Accept: application/json" \
     -d "$gen_payload" \
     -w "%{http_code}" \
     -o "$gen_notes_response" \
     "${REPO_API_URL}/generate-notes")

if [ "$http_code_gen" -eq 200 ]; then
    echo "GitHub successfully generated notes."
    # Extract the 'body' field using Python (safest way to handle JSON in bash)
    release_notes=$(cat "$gen_notes_response" | python3 -c "import sys, json; print(json.load(sys.stdin).get('body', ''))")
else
    echo "WARNING: Failed to generate notes via GitHub API (HTTP $http_code_gen). Defaulting to simple message."
    release_notes="Automated release for $tag_date"
fi

rm "$gen_notes_response"
# --- CHANGED SECTION END ---

# Escape backslashes and double quotes for JSON compliance
release_notes="${release_notes//\\/\\\\}"
release_notes="${release_notes//\"/\\\"}"
# Escape newlines (replace literal newline with \n)
release_notes="${release_notes//$'\n'/\\n}"

echo "Contacting GitHub API..."

# Create the JSON payload
# Note: I removed "Automated Release\n\nChanges:\n" prefix because GitHub notes usually include a title.
api_json=$(cat <<EOF
{
  "tag_name": "$tag_date",
  "target_commitish": "main",
  "name": "Release $tag_date",
  "body": "$release_notes",
  "draft": false,
  "prerelease": false
}
EOF
)

# Send the Request
http_code=$(curl -s -X POST \
     -H "Authorization: Bearer $GITHUB_TOKEN" \
     -H "Accept: application/json" \
     -d "$api_json" \
     -w "%{http_code}" \
     -o "$response_body_file" \
     "https://api.github.com/repos/akarrar16/release-automation-test/releases")

echo "Release creation request sent."
echo "Checking if creation was successful ..."

# Check the response
if [ "$http_code" -eq 201 ]; then
    echo "SUCCESS: Release $tag_date created successfully!"
    echo "Release URL: $(grep -o '"html_url": "[^"]*' "$response_body_file" | cut -d'"' -f4)"
else
    echo "ERROR: Failed to create release. HTTP Status: $http_code"
    echo "Server Response:"
    cat "$response_body_file" || echo "No response body."
    # Clean up and exit with error
    rm "$response_body_file"
    exit 1
fi

# Cleanup
rm "$response_body_file"

echo ""
echo "Done."