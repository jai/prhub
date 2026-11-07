#!/usr/bin/env bash
# design-lint.sh — fails if view code types a font size, colour, padding, gap, corner or animation that DESIGN.md's
# tokens own. Run it before every push; CI runs it too.
#
#   scripts/design-lint.sh [path ...]     (default: PRKit/Sources/PRKit and app/PRHub)
#
# PRKit/Sources/PRKitDesign is where the values live, so it is never scanned. A line may keep a literal with a reason
# on it or on the line above: `// design-lint: allow <why>`. A whole file may wait on the list in
# scripts/design-lint-allow.txt, one path and its reason per line. What to use instead is DESIGN.md's "Making a change".
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
[ $# -gt 0 ] || set -- PRKit/Sources/PRKit app/PRHub

allow_file=scripts/design-lint-allow.txt
files=$(find "$@" -name '*.swift' -not -path '*/PRKitDesign/*' | sort)

exec perl -e '
use strict;
use warnings;

my ($allow_file, @files) = @ARGV;
my %allowed;
if (open my $fh, "<", $allow_file) {
    while (<$fh>) {
        next if /^\s*(#|$)/;
        my ($path) = split /\s+/;
        $allowed{$path} = 1;
    }
}

my $colours = qr/(?:red|green|blue|orange|yellow|purple|pink|gray|grey|black|white|teal|indigo|mint|cyan|brown)/;
my $curves = qr/(?:easeInOut|easeIn|easeOut|linear|spring|snappy|smooth|bouncy|interpolatingSpring|default)/;
my $number = qr/-?(?:\d*\.)?\d*[1-9]\d*(?:\.\d+)?/;
my @rules = (
    [qr/\.system\(\s*size:|\.custom\(|(?:UI|NS)Font\.(?:systemFont|monospacedSystemFont)\(ofSize:\s*\d/,
        "a font size: use an AppFont style (.appFootnote, .app(.caption, design: .monospaced))"],
    [qr/\.font\(\s*\.(?:largeTitle|title|title2|title3|headline|subheadline|body|callout|footnote|caption|caption2)\b/,
        "a system text style: use its AppFont style (.appFootnote)"],
    [qr/(?:Color|UIColor|NSColor)\(\s*(?:red|white|hue|srgbRed|displayP3Red):|#colorLiteral|Color\(\s*"/,
        "a colour: use its role (Color.toneGood, .inkQuiet, .groundCard) from AppColor.swift"],
    [qr/(?:\bColor|(?:UI|NS)Color)\.$colours\b|(?:\bColor\.)?\bsystem(?:Red|Green|Blue|Orange|Yellow|Purple|Pink|Gray|Teal|Indigo|Mint|Cyan|Brown)\b|(?:foregroundStyle|foregroundColor|tint|fill|stroke|strokeBorder|background)\(\s*\.$colours\b|tint:\s*\.$colours\b/,
        "a system colour: use its role (Color.toneBad, .onAccent) from AppColor.swift"],
    [qr/\.padding\(\s*(?:(?:\.\w+|\[[^\]]*\])\s*,\s*)?$number\s*\)|\bspacing:\s*$number\b|EdgeInsets\([^)]*:\s*$number/,
        "a padding or gap: use a Space step, or the part'"'"'s measure in PRKitDesign/Metrics.swift"],
    [qr/cornerRadius:\s*$number\b|\.cornerRadius\(\s*$number/,
        "a corner: use Radius or the part'"'"'s measure in PRKitDesign/Metrics.swift"],
    [qr/(?:withAnimation|\.animation|Transaction\(animation:)\s*\(?\s*(?:Animation)?\.$curves\b|\bAnimation\.$curves\b|withAnimation\s*\{/,
        "an animation: use AppMotion (.fold, .swap, .press, .screen)"],
);

my $failures = 0;
for my $file (@files) {
    next if $allowed{$file};
    open my $fh, "<", $file or die "$file: $!";
    my $previous = "";
    while (my $line = <$fh>) {
        my $allowed_here = $line =~ m{//\s*design-lint:\s*allow\s+\S} || $previous =~ m{^\s*//\s*design-lint:\s*allow\s+\S};
        $previous = $line;
        next if $allowed_here;
        (my $code = $line) =~ s{//.*$}{};
        for my $rule (@rules) {
            my ($pattern, $use) = @$rule;
            if ($code =~ $pattern) {
                chomp $line;
                $line =~ s/^\s+//;
                print "$file:$.: $use\n    $line\n";
                $failures++;
                last;
            }
        }
    }
}
if ($failures) {
    print "\n$failures literal(s) in view code. DESIGN.md says which token or part to use; a real exception gets ",
        "\"// design-lint: allow <why>\".\n";
    exit 1;
}
print "design-lint: no literals outside PRKitDesign\n";
' "$allow_file" $files
