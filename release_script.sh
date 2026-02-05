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

echo "Generating Release Notes..."
# --- START: HEURISTIC RELEASE NOTES GENERATOR ---
echo "Generating structured release notes (Rule-Based)..."

# Initialize categories
feats=""
fixes=""
maint=""
docs=""
others=""

# Get raw commits (Subject only) from the range
# We use a loop to process line by line
git log "${latest_tag}..HEAD" --pretty=format:"%s" | while read -r line; do
    
    # 1. CLEANING
    # Skip "Merge pull request" lines (too noisy)
    if [[ "$line" == *"Merge pull request"* ]] || [[ "$line" == *"Merge branch"* ]]; then
        continue
    fi
    
    # Remove Jira/Ticket IDs (e.g., [ABC-123] or ABC-123) for cleaner reading
    clean_line=$(echo "$line" | sed -E 's/\[?[A-Z]+-[0-9]+\]?[-: ]*//g')
    
    # 2. CATEGORIZATION (Case Insensitive)
    # We check for keywords to decide where to put the line
    
    if echo "$clean_line" | grep -iqE "^(feat|add|new|implement|feature)"; then
        # It's a Feature
        echo "- $clean_line" >> temp_feats.txt
        
    elif echo "$clean_line" | grep -iqE "^(fix|bug|resolve|patch|hotfix)"; then
        # It's a Fix
        echo "- $clean_line" >> temp_fixes.txt
        
    elif echo "$clean_line" | grep -iqE "^(doc|readme|comment)"; then
        # It's Documentation
        echo "- $clean_line" >> temp_docs.txt
        
    elif echo "$clean_line" | grep -iqE "^(chore|ci|test|refactor|perf|maint|clean)"; then
        # It's Maintenance
        echo "- $clean_line" >> temp_maint.txt
        
    else
        # Everything else
        echo "- $clean_line" >> temp_others.txt
    fi
done

# 3. ASSEMBLE THE MARKDOWN
# We build the final string variable.
release_notes="# Release Notes for $tag_date\n\n"

if [ -f temp_feats.txt ]; then
    release_notes="${release_notes}## 🚀 New Features\n$(cat temp_feats.txt)\n\n"
    rm temp_feats.txt
fi

if [ -f temp_fixes.txt ]; then
    release_notes="${release_notes}## 🐛 Bug Fixes\n$(cat temp_fixes.txt)\n\n"
    rm temp_fixes.txt
fi

if [ -f temp_maint.txt ]; then
    release_notes="${release_notes}## 🔧 Maintenance & Performance\n$(cat temp_maint.txt)\n\n"
    rm temp_maint.txt
fi

if [ -f temp_docs.txt ]; then
    release_notes="${release_notes}## 📚 Documentation\n$(cat temp_docs.txt)\n\n"
    rm temp_docs.txt
fi

if [ -f temp_others.txt ]; then
    release_notes="${release_notes}## 📦 Other Changes\n$(cat temp_others.txt)\n\n"
    rm temp_others.txt
fi

echo "--- Generated Notes Preview ---"
echo -e "$release_notes"
echo "-----------------------------"

# --- END: HEURISTIC GENERATOR ---

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
