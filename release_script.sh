git fetch --prune --prune-tags origin

current_date=$(date '+%Y-%m-%d')
echo "Current date: ${current_date}"
tag_date=${current_date//-/.}
tag_date=v${tag_date:2}
echo "Current tag generated out of date: ${tag_date}"

latest_tag=$(git describe --tags --match="v[0-9].[0-9].[0-9]*" $(git rev-list --tags --max-count=10) | head -n 1)
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

eecho "Generating Release Notes..."
if [ -z "$latest_tag" ]; then
    release_notes="- Initial Release"
else
    # Get commit messages between the last tag and now
    # We use 'git log' to get the subject lines
    raw_notes=$(git log "${latest_tag}..HEAD" --pretty=format:"- %s")
    
    # If raw_notes is empty (no commits since last tag), use a fallback message
    if [ -z "$raw_notes" ]; then
        release_notes="- No new commits (Maintenance release or testing)"
    else
        release_notes="$raw_notes"
    fi
fi

# Escape backslashes and double quotes for JSON compliance
release_notes="${release_notes//\\/\\\\}"
release_notes="${release_notes//\"/\\\"}"
# Escape newlines (replace literal newline with \n)
release_notes="${release_notes//$'\n'/\\n}"

echo "Contacting GitHub API..."

# Create the JSON payload
api_json=$(cat <<EOF
{
  "tag_name": "$tag_date",
  "target_commitish": "main",
  "name": "Release $tag_date",
  "body": "Automated Release.\\n\\nChanges:\\n$release_notes",
  "draft": false,
  "prerelease": false
}
EOF
)

# Send the Request
curl -s -X POST \
     -H "Authorization: Bearer $GITHUB_TOKEN" \
     -H "Accept: application/vnd.github.v3+json" \
     -d "$api_json" \
     "https://api.github.com/repos/akarrar16/release-automation-test/releases"

echo "Release creation request sent."

echo "Checking if creation was successful ..."