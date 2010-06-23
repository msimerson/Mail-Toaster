#!perl
use strict;
use warnings;

use Cwd;
use English qw( -no_match_vars );
use Test::More;

use lib "lib";

eval "use Mail::Ezmlm";
if ($EVAL_ERROR) {
    plan skip_all => "Mail::Ezmlm is required for ezmlm.cgi testing",
}
else {
    plan 'no_plan';
};

require_ok( 'Mail::Toaster' );
require_ok( 'Mail::Toaster::Ezmlm' );

# basic OO mechanism
my $ezmlm = Mail::Toaster::Ezmlm->new;                       # create an object
ok ( defined $ezmlm, 'get Mail::Toaster::Ezmlm object' );    # check it
ok ( $ezmlm->isa('Mail::Toaster::Ezmlm'), 'check object class' );


my $toaster = Mail::Toaster->new();
my $conf = $toaster->{conf};
my $util = $toaster->{util};

ok( $conf, 'toaster-watcher.conf loaded');

# process_shell
    if ( $conf->{'install_ezmlm_cgi'} ) {
        ok( $ezmlm->process_shell(), 'process_shell');
    }

# authenticate
    if ( eval "require vpopmail" ) {
        ok( ! $ezmlm->authenticate(
            domain=>'example.com', 
            password=>'exampass',
        ), 'authenticate');
    };

ok( ! $ezmlm->subs_list(
    list     => {'list_object'=>1},
    list_dir => 'path/to/list',
    debug    => 0, ), 'subs_list');

ok( ! $ezmlm->subs_add (
        list=>'list_object',
        list_dir=>'path/to/list',
        debug=>0,
        requested=>['user@example.com'],
        br=>'\n',
    ), 'subs_add');

#ok( ! $ezmlm->lists_get(domain=>'example.com',debug=>0), 'subs_list');

ok( $ezmlm->logo(), 'logo');

ok( $ezmlm->dir_check(dir=>"/tmp",debug=>0) , 'dir_check');


