#!perl
use strict;
use warnings;

use Cwd;
use English qw( -no_match_vars );
use Test::More;

use lib 'lib';

eval 'use Mail::Ezmlm';
if ($EVAL_ERROR) {
    plan skip_all => "Mail::Ezmlm is required for ezmlm.cgi testing",
}

use_ok 'Mail::Toaster::Ezmlm';

# basic OO mechanism
my $ezmlm = Mail::Toaster::Ezmlm->new;
isa_ok( $ezmlm, 'Mail::Toaster::Ezmlm', 'object class' );

my $conf = $ezmlm->conf;
ok( $conf, 'toaster-watcher.conf loaded');

# process_shell
    if ( $conf->{'install_ezmlm_cgi'} ) {
        ok( $ezmlm->process_shell( test_ok => 1 ), 'process_shell');
    }

# authenticate
    if ( eval "require vpopmail" ) {
        ok( ! $ezmlm->authenticate(
            domain   => 'example.com',
            password => 'exampass',
        ), 'authenticate');
    };

ok( ! $ezmlm->subs_list(
    list     => {'list_object'=>1},
    list_dir => 'path/to/list',
    verbose  => 0, ), 'subs_list');

ok( ! $ezmlm->subs_add (
        list=>'list_object',
        list_dir=>'path/to/list',
        verbose=>0,
        requested=>['user@example.com'],
        br=>'\n',
    ), 'subs_add');

#ok( ! $ezmlm->lists_get(domain=>'example.com',verbose=>0), 'subs_list');

ok( $ezmlm->logo( test_ok => 1), 'logo');

ok( $ezmlm->dir_check(dir=>"/tmp",verbose=>0) , 'dir_check');

done_testing();
exit;
