#!/usr/bin/env bash
# scrub.sh — fails if a private name, id, host or token is in the repo. Run it before every push; CI runs it too.
#
#   scripts/scrub.sh [path ...]     (default: the whole repo)
#
# Scans every tracked or untracked text file but .git, node_modules, lockfiles, e2e run output (.e2e) and this
# script. Two values are allowed where they appear: the public URLs of the shared relay and the hosted Worker. PRHub's
# bundle ID, team ID and App Store Connect app ID are public and are not on the list.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
[ $# -gt 0 ] || set -- .

# Each line: a Perl regex. A match anywhere in a file fails the scrub.
patterns=$(cat <<'EOF'
(?i)EWA-Services|ewa-services\.com|finn-app\.com|EWA-Actions
(?i)\bfinn\b|\bfinn[-_]|[-_]finn\b
\bEWA\b|\bewa-|-ewa\b
(?i)easyhoteluk
finn-atlas|jai-f89
com\.jaigovindani\.agentpager
f8966459|31d7953b
~/\.credentials|HOME/\.credentials|\.credentials/
(?i)borg[- ]cube|jais?-mac-mini|mac-mini-users
\bagent_01|\benv_01|\bvlt_0|\bvcrd_
op://
\bsk-ant-|\bghp_[A-Za-z0-9]|\bgho_[A-Za-z0-9]|\bghs_[A-Za-z0-9]|\bgithub_pat_|\bops_[A-Za-z0-9]{20}|\brks_[A-Za-z0-9]{16}
PRIVATE KEY-----(\\n|\s*$)MI|PRIVATE KEY-----\s*MI[A-Za-z0-9+/]
\b(?=[a-z]*[0-9])(?=[0-9]*[a-z])[a-z0-9]{26}\b
H8839T272X|B765L3Q2GZ|bbbcdf62-cba8-48ed-a884-49e673b9916c
(?i)maksimb
jai\.g@
EOF
)

# Allowed values: removed from a line before the patterns are tried. The hosted Worker's bare host is the app's build
# setting (app/Config/PRHub.xcconfig).
allowed='https://(agent-pager-relay|prhub)\.jai-f89\.workers\.dev|\bprhub\.jai-f89\.workers\.dev'

files=$(find "$@" \( -name .git -o -name node_modules -o -name .build -o -name DerivedData -o -name build -o -name tmp -o -name .e2e \) -prune -o \
  -type f ! -name package-lock.json ! -name Package.resolved ! -path ./scripts/scrub.sh ! -path scripts/scrub.sh -print)

# shellcheck disable=SC2086
PATTERNS="$patterns" ALLOWED="$allowed" perl -e '
  my @patterns = grep { length } split /\n/, $ENV{PATTERNS};
  my $allowed = qr/$ENV{ALLOWED}/;
  my $fail = 0;
  for my $file (@ARGV) {
    next if -B $file;
    open my $fh, "<", $file or next;
    while (my $line = <$fh>) {
      (my $rest = $line) =~ s/$allowed//g;
      for my $pattern (@patterns) {
        if ($rest =~ /$pattern/) {
          chomp $line;
          $line = substr($line, 0, 200);
          print STDERR "scrub: $file:$.: matches /$pattern/: $line\n";
          $fail = 1;
          last;
        }
      }
    }
  }
  exit $fail;
' $files && echo "scrub: clean"
