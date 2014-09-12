#!/usr/bin/perl
use strict;
use warnings;

my $ver = get_qp_version();
   $ver =~ m/^([\d]+)\.(\d+)$/;
my $new_ver = $1 . '.' . ($2 + 1);

`find lib -name '*.pm' -exec sed -i .bak -e 's/$ver/$new_ver/' {} \;`;
`find lib -name '*.pm.bak' -delete`;

sub get_qp_version {
    my $rvfile = get_file_contents('lib/Mail/Toaster.pm')
        or return;
    my ($ver_line) = grep { $_ =~ /^(?:my|our) \$VERSION/ } @$rvfile;
    my ($ver) = $ver_line =~ /(?:"|')([0-9\.]+)(?:"|')/;
    return $ver;
};

sub get_file_contents {
    my $file = shift;
    open my $fh, '<', $file or do {
        warn "failed to open $file";
        return;
    };
    chomp (my @r = <$fh>);
    return \@r;
};
