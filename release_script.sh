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

# Ensure temp files are clean
rm -f temp_feats.txt temp_fixes.txt temp_maint.txt temp_docs.txt temp_others.txt

# Get raw commits (Subject only) from the range
git log "${latest_tag}..HEAD" --pretty=format:"%s" | while read -r line; do
    
    # 1. CLEANING
    if [[ "$line" == *"Merge pull request"* ]] || [[ "$line" == *"Merge branch"* ]]; then
        continue
    fi
    
    # Remove Jira/Ticket IDs
    clean_line=$(echo "$line" | sed -E 's/\[?[A-Z]+-[0-9]+\]?[-: ]*//g')
    
    # 2. CATEGORIZATION (Case Insensitive)
    if echo "$clean_line" | grep -iqE "^(feat|add|new|implement|feature)"; then
        echo "- $clean_line" >> temp_feats.txt
    elif echo "$clean_line" | grep -iqE "^(fix|bug|resolve|patch|hotfix)"; then
        echo "- $clean_line" >> temp_fixes.txt
    elif echo "$clean_line" | grep -iqE "^(doc|readme|comment)"; then
        echo "- $clean_line" >> temp_docs.txt
    elif echo "$clean_line" | grep -iqE "^(chore|ci|test|refactor|perf|maint|clean)"; then
        echo "- $clean_line" >> temp_maint.txt
    else
        echo "- $clean_line" >> temp_others.txt
    fi
done

# 3. ASSEMBLE THE MARKDOWN
# We write to a temporary file first to handle newlines correctly
notes_file="final_notes.md"
echo "# Release Notes for $tag_date" > "$notes_file"
echo "" >> "$notes_file"

if [ -f temp_feats.txt ]; then
    echo "## 🚀 New Features" >> "$notes_file"
    cat temp_feats.txt >> "$notes_file"
    echo "" >> "$notes_file"
    rm temp_feats.txt
fi

if [ -f temp_fixes.txt ]; then
    echo "## 🐛 Bug Fixes" >> "$notes_file"
    cat temp_fixes.txt >> "$notes_file"
    echo "" >> "$notes_file"
    rm temp_fixes.txt
fi

if [ -f temp_maint.txt ]; then
    echo "## 🔧 Maintenance & Performance" >> "$notes_file"
    cat temp_maint.txt >> "$notes_file"
    echo "" >> "$notes_file"
    rm temp_maint.txt
fi

if [ -f temp_docs.txt ]; then
    echo "## 📚 Documentation" >> "$notes_file"
    cat temp_docs.txt >> "$notes_file"
    echo "" >> "$notes_file"
    rm temp_docs.txt
fi

if [ -f temp_others.txt ]; then
    echo "## 📦 Other Changes" >> "$notes_file"
    cat temp_others.txt >> "$notes_file"
    echo "" >> "$notes_file"
    rm temp_others.txt
fi

echo "--- Generated Notes Preview ---"
cat "$notes_file"
echo "-----------------------------"

# --- END: HEURISTIC GENERATOR ---

echo "Contacting GitHub API..."

# --- FIXED JSON CONSTRUCTION ---
# We use Python to read the file content and dump it as a properly escaped JSON string.
# This handles all newlines, quotes, and special characters automatically.

api_json=$(python3 -c "import json, sys; 
content = open('$notes_file', 'r').read(); 
print(json.dumps({
  'tag_name': '$tag_date', 
  'target_commitish': 'main', 
  'name': 'Release $tag_date', 
  'body': content, 
  'draft': False, 
  'prerelease': False
}))")

# Clean up the notes file
rm "$notes_file"

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
