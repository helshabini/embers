#!/bin/zsh
# Raises the build number by one, and the version too when one is given, in all eight build
# configurations at once.
#
#   scripts/bump-version.sh          # another build of the same version: 1.1 (3) → 1.1 (4)
#   scripts/bump-version.sh 1.2      # a new version:                     1.1 (4) → 1.2 (5)
#
# The build number only ever goes up, even for a new version. The Mac store refuses any build
# lower than one already uploaded, across every version: 1.1 went up as build 1 after 1.0's
# build 2 and was turned away. iOS only compares within a version, but both apps share the number.
set -euo pipefail
cd "${0:A:h}/.."

project=Embers.xcodeproj/project.pbxproj
configurations=8

# value <setting>: the one value every configuration holds, or a refusal if they disagree.
value() {
  local values=("${(@f)$(grep -o "$1 = [^;]*;" $project | sed "s/$1 = //; s/;//" | sort -u)}")
  local count=$(grep -c "$1 = " $project)
  if (( ${#values} != 1 || count != configurations )); then
    print -u2 "$1 should be set once in each of $configurations configurations; found $count, values: ${values[*]}"
    exit 1
  fi
  print -r -- $values[1]
}

old_version=$(value MARKETING_VERSION)
old_build=$(value CURRENT_PROJECT_VERSION)
new_version=${1:-$old_version}
new_build=$(( old_build + 1 ))

if [[ ! $new_version =~ '^[0-9]+(\.[0-9]+){1,2}$' ]]; then
  print -u2 "A version is two or three numbers, like 1.2 or 1.2.1; got \"$new_version\""
  exit 1
fi
# Comparing as versions, not as text, so 1.10 is after 1.9.
if [[ $new_version != $old_version && $(printf '%s\n%s\n' $old_version $new_version | sort -V | tail -1) == $old_version ]]; then
  print -u2 "$new_version is not after $old_version"
  exit 1
fi

sed -i '' \
  -e "s/MARKETING_VERSION = $old_version;/MARKETING_VERSION = $new_version;/" \
  -e "s/CURRENT_PROJECT_VERSION = $old_build;/CURRENT_PROJECT_VERSION = $new_build;/" \
  $project

[[ $(value MARKETING_VERSION) == $new_version && $(value CURRENT_PROJECT_VERSION) == $new_build ]] || {
  print -u2 "The project did not end up at $new_version ($new_build); check $project"
  exit 1
}

print "$old_version ($old_build) → $new_version ($new_build)"
print "Commit it with: git commit -m \"Version $new_version, build $new_build\" $project"
