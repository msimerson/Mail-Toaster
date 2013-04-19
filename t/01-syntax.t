
use Config qw/ myconfig /;
use Data::Dumper;
use English qw/ -no_match_vars /;
use Test::More tests => 23;

use lib 'lib';

ok( -d 'bin', 'bin directory' ) or die 'could not find bin directory';

my $this_perl = $Config{'perlpath'} || $EXECUTABLE_NAME;

ok( $this_perl, "this_perl: $this_perl" );

if ($OSNAME ne 'VMS' && $Config{_exe} ) {
    $this_perl .= $Config{_exe}
        unless $this_perl =~ m/$Config{_exe}$/i;
}

foreach ( <bin/*> ) {
    my $cmd = "$this_perl -c $_";
    my $r = system "$cmd 2>/dev/null >/dev/null";
    ok( $r == 0, "syntax $_");
};

foreach ( `find lib -name '*.pm'` ) {
    chomp;
    my $cmd = "$this_perl -c $_";
    my $r = `$cmd 2>&1`;
    my $exit_code = sprintf ("%d", $CHILD_ERROR >> 8);
    my $pretty_name = substr($_, 4);
    ok( $exit_code == 0, "syntax $pretty_name");
};

my $r = `$this_perl -c cgi_files/ezmlm.cgi 2>&1`;
my $exit_code = sprintf ("%d", $CHILD_ERROR >> 8);
ok( $exit_code == 0, "syntax ezmlm.cgi");
