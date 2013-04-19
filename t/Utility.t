
use strict;
#use warnings;

use lib "lib";

use Cwd;
use English qw( -no_match_vars );
use Test::More 'no_plan';

my $deprecated = 0;    # run the deprecated tests.
my $network    = 0;    # run tests that require network
$network = 1 if $OSNAME =~ /freebsd|darwin/;
my $r;

BEGIN {
    use_ok('Mail::Toaster');
    use_ok('Mail::Toaster::Utility');
}
require_ok('Mail::Toaster');
require_ok('Mail::Toaster::Utility');

# let the testing begin
my $toaster = Mail::Toaster->new();
my $log = my $util = $toaster->get_util();
ok( defined $util, 'get Mail::Toaster::Utility object' );
isa_ok( $util, 'Mail::Toaster::Utility' );

# for internal use
if ( -e "Utility.t" ) { chdir "../"; }

# we need this stuff during subsequent tests
my $debug = 0;
my ($cwd) = cwd =~ /^([\/\w\-\s\.]+)$/;       # get our current directory

print "\t\twd: $cwd\n" if $debug;

my $tmp = "$cwd/t/trash";
mkdir $tmp, 0755;
if ( ! -d $tmp ) {
    $util->mkdir_system( dir => $tmp, fatal => 0 );
};
skip "$tmp dir creation failed!\n", 2 if ( ! -d $tmp );
ok( -d $tmp, "temp dir: $tmp" );
ok( $util->syscmd( "cp TODO $tmp/", fatal => 0 ), 'cp TODO' );


# ask - asks a question and retrieves the answer
SKIP: {
    skip "annoying", 4 if 1 == 1;
    skip "ask is an interactive only feature", 4 unless $util->is_interactive;
    ok( $r = $util->ask( 'test yes ask',
            default  => 'yes',
            timeout  => 5
        ),
        'ask, proper args'
    );
    is( lc($r), "yes", 'ask' );
    ok( $r = $util->ask( 'any (non empty) answer' ), 'ask, tricky' );

    # multiline prompt
    ok( $r = $util->ask( 'test any (non empty) answer',
            default  => 'just hit enter',
        ),
        'ask, multiline'
    );

    # default password prompt
    ok( $r = $util->ask( 'type a secret word',
            password => 1,
            default  => 'secret',
        ),
        'ask, password'
    );
}

# extract_archive
my $gzip = $util->find_bin( "gzip", fatal => 0 );
my $tar  = $util->find_bin( "tar",  fatal => 0 );
my $star  = $util->find_bin( "star",  fatal => 0 );

SKIP: {
    skip "gzip or tar is missing!\n", 6 unless ( -x $gzip and -x $tar and -d $tmp );
    ok( $util->syscmd( "$tar -cf $tmp/test.tar TODO", fatal => 0),
        "tar -cf test.tar"
    );
    ok( $util->syscmd( "$gzip -f $tmp/test.tar", fatal => 0), 'gzip test.tar'
    );

    my $archive = "$tmp/test.tar.gz";
    ok( -e $archive, 'temp archive exists' );

    ok( $util->extract_archive( $archive, fatal => 0 ), 'extract_archive +');
    ok( !$util->extract_archive( "$archive.fizzlefuzz", fatal => 0 ), 'extract_archive -');

    # clean up behind the tests
    ok( $util->file_delete( $archive, fatal => 0 ), 'file_delete' );
}

$log->dump_audit(quiet=>1);
$log->{last_error} = scalar @{$log->{errors}};

#	TODO: { my $why = "extract_archive, requires a valid archive to expand";
#			this is how to run them but not count them as failures
#			local $TODO = $why if (! -e $archive);
#			this way to skip them entirely and mark as TODO
#			todo_skip $why, 3 if (! -e $archive); #}

# cwd_source_dir
# dir already exists
ok( $util->cwd_source_dir( $tmp ), 'cwd_source_dir' );

# clean up after previous runs
if ( -f "$tmp/foo" ) {
    ok( $util->file_delete( "$tmp/foo", fatal => 0 ), 'file_delete' );
}

# a dir to create
ok( $util->cwd_source_dir( "$tmp/foo" ), 'cwd_source_dir' );
print "\t\t wd: " . cwd . "\n" if $debug;

# go back to our previous working directory
chdir($cwd) or die;
print "\t\t wd: " . cwd . "\n" if $debug;

# chown_system
my $sudo_bin = $util->find_bin( 'sudo', fatal => 0 );
if ( $UID == 0 && $sudo_bin && -x $sudo_bin ) {

    # avoid the possiblity of a sudo call in testing
    ok( $util->chown_system( $tmp, user => $<, fatal => 0), 'chown_system');
}

# clean_tmp_dir
TODO: {
    my $why = " - no test written yet";
}
ok( $util->clean_tmp_dir( $tmp ), 'clean_tmp_dir' );

print "\t\t wd: " . cwd . "\n" if $debug;

# get_mounted_drives
ok( my $drives = $util->get_mounted_drives(), 'get_mounted_drives' );
isa_ok( $drives, 'HASH' );

# example code working with the mounts
#foreach my $drive (keys %$drives) {
#	print "drive: $drive $drives->{$drive}\n";
#}

# file_* tests

TODO: {
    my $why = " - user may not want to run extended tests";

    # this way to run them but not count them as failures
    local $TODO = $why if ( -e '/dev/null' );

#$extra = $util->yes_or_no( question=>"can I run extended tests?", timeout=>5 );
#ok ( $extra, 'yes_or_no' );
}

# file_read
my $rwtest = "$tmp/rw-test";
ok( $util->file_write( $rwtest, lines => ["erase me please"] ), 'file_write');
my @lines = $util->file_read( $rwtest );
ok( @lines == 1, 'file_read' );

# file_append
# a typical invocation
ok( $util->file_write( $rwtest, lines  => ["more junk"], append => 1 ), 'file_append');

# archive_file
# a typical invocation
my $backup = $util->archive_file( $rwtest, fatal => 0 );
ok( -e $backup, 'archive_file' );
ok( $util->file_delete( $backup, fatal => 0 ), 'file_delete' );

ok( !$util->archive_file( $backup, fatal => 0 ), 'archive_file' );

#    eval {
#        # invalid param, will raise an exception
#	    $util->archive_file( $backup, fatal=>0 );
#    };
#	ok( $EVAL_ERROR , "archive_file");

# file_check_[readable|writable]
# typical invocation
ok( $util->is_readable( $rwtest, fatal => 0 ), 'is_readable' );

# a non-existing file (we already deleted it)
ok( !$util->is_readable( $backup, fatal => 0,debug=>0 ), 'is_readable - negated' );

ok( $util->is_writable( $rwtest, fatal => 0 ), 'is_writable' );

# get_url
SKIP: {
    skip "avoiding network tests", 3 if ( !$network );

    ok( $util->cwd_source_dir( $tmp ), 'cwd_source_dir' );

    my $url = "http://www.mail-toaster.org/etc/maildrop-qmail-domain";
    ok( $util->get_url( $url ), 'get_url' );
    ok( $util->get_url( $url, dir => $tmp ), 'get_url');
}

chdir($cwd);
print "\t\t  wd: " . Cwd::cwd . "\n" if $debug;

# chown
my $uid = getpwuid($UID);
my $gid = getgrgid($GID);
my $root = 'root';
my $grep = $util->find_bin( 'grep' );
my $wheel = `$grep wheel /etc/group` ? 'wheel' : 'root';

SKIP: {
    skip "the temp file for file_ch* is missing!", 4 if ( !-f $rwtest );

    # this one should work
    ok( $util->chown( $rwtest,
            uid   => $uid,
            gid   => $gid,
            sudo  => 0,
            fatal => 0
        ),
        'chown uid'
    );

    if ( $UID == 0 ) {
        ok( $util->chown( $rwtest,
                uid   => $root,
                gid   => $wheel,
                sudo  => 0,
                fatal => 0,
            ),
            'chown user'
        );
    }

    # try a user/group that does not exist
    ok( !$util->chown( $rwtest,
            uid   => 'frobnob6i',
            gid   => 'frobnob6i',
            sudo  => 0,
            fatal => 0
        ),
        'chown nonexisting uid'
    );

    # try a user/group that I may not have permission to
    if ( $UID != 0 && lc($OSNAME) ne 'irix') {
        ok( !$util->chown( $rwtest,
                uid   => $root,
                gid   => $wheel,
                sudo  => 0,
                fatal => 0
            ),
            'chown no perms'
        );
    }
}

# tests system_chown because sudo is set, might cause testers to freak out
#	ok ($util->chown( $rwtest, uid=>$uid, gid=>$gid, sudo=>1, fatal=>0 ), 'chown');
#	ok ( ! $util->chown( $rwtest, uid=>'frobnob6i', gid=>'frobnob6i', sudo=>1, fatal=>0 ), 'chown');
#	ok ( ! $util->chown( $rwtest, uid=>$root, gid=>$wheel, sudo=>1,fatal=>0), 'chown');

# chmod
# get the permissions of the file in octal file mode
use File::stat;
my $st = stat($rwtest) or warn "No $tmp: $!\n";
my $before = sprintf "%lo", $st->mode & 07777;

#$util->syscmd( "ls -al $rwtest" );   # use ls -al to view perms

# change the permissions to something slightly unique
if ( lc($OSNAME) ne 'irix' ) {
# not sure why this doesn't work on IRIX, and since IRIX is EOL and nearly 
# extinct, I'm not too motivated to find out why.
    ok( $util->chmod(
            file_or_dir => $rwtest,   mode        => '0700',
            fatal       => 0,
        ),
        'chmod'
    );

# file_mode
    my $result_mode = $util->file_mode( file => $rwtest );
    cmp_ok( $result_mode, '==', 700, 'file_mode' );

#$util->syscmd( "ls -al $rwtest" );

# and then set them back
    ok( $util->chmod(
            file_or_dir => $rwtest,
            mode        => $before,
            fatal => 0,
        ),
        'chmod'
    );
};

#$util->syscmd( "ls -al $rwtest" );

# file_write
ok( $util->file_write( $rwtest, lines => ["17"], fatal => 0 ), 'file_write');

#$ENV{PATH} = ""; print `/bin/cat $rwtest`;
#print `/bin/cat $rwtest` . "\n";

# files_diff
# we need two files to work with
$backup = $util->archive_file( $rwtest );

# these two files are identical, so we should get 0 back from files_diff
ok( !$util->files_diff( f1 => $rwtest, f2 => $backup ), 'files_diff' );

# now we change one of the files, and this time they should be different
ok( $util->file_write( $rwtest,
        lines  => ["more junk"],
        append => 1
    ),
    'file_write'
);
ok( $util->files_diff( f1 => $rwtest, f2 => $backup ), 'files_diff' );

# make it use md5 checksums to compare
$backup = $util->archive_file( $rwtest );
ok( !$util->files_diff(
        f1    => $rwtest,
        f2    => $backup,
        type  => 'binary'
    ),
    'files_diff'
);

# now we change one of the files, and this time they should be different
sleep 1;
ok( $util->file_write( $rwtest,
        lines  => ["extra junk"],
        append => 1
    ),
    'file_write'
);
ok( $util->files_diff(
        f1    => $rwtest,
        f2    => $backup,
        type  => 'binary'
    ),
    'files_diff'
);

# file_is_newer
#

# find_bin
# a typical invocation
my $rm = $util->find_bin( "rm", fatal => 0 );
ok( $rm && -x $rm, 'find_bin' );

# a test that should fail
ok( !$util->find_bin( "globRe", fatal => 0 ), 'find_bin' );

# a shortcut that should work
$rm = $util->find_bin( 'rm' );
ok( -x $rm, 'find_bin' );



# find_config
ok( $util->find_config( 'services', fatal => 0 ), 'find_config valid' );

# same as above but with etcdir defined
ok( $util->find_config( 'services', etcdir => '/etc', fatal  => 0,), 'find_config valid');

# this one fails because the file does not exist
ok( !$util->find_config( 'country-bumpkins.conf', fatal => 0),
    'find_config non-existent file'
);

# fstab_list
my $fs = $util->fstab_list();
if ($fs) {
    ok( $fs, 'fstab_list' );

    #foreach (@$fs) { print "\t$_\n"; };
}

# get_dir_files
my (@list) = $util->get_dir_files( "/etc" );
ok( -e $list[0], 'get_dir_files' );

# get_my_ips
SKIP: {
    skip "avoiding network tests", 1 if ( !$network );

    # need to update this so it works on netbsd & solaris
    ok( $util->get_my_ips( exclude_internals => 0 ), 'get_my_ips' );
}

# get_the_date
my $mod = "Date::Format";
if ( eval "require $mod" ) {

    ok( @list = $util->get_the_date(), 'get_the_date' );

    my $date = $util->find_bin( "date" );
    cmp_ok( $list[0], '==', `$date '+%d'`, 'get_the_date day' );
    cmp_ok( $list[1], '==', `$date '+%m'`, 'get_the_date month' );
    cmp_ok( $list[2], '==', `$date '+%Y'`, 'get_the_date year' );
    cmp_ok( $list[4], '==', `$date '+%H'`, 'get_the_date hour' );
    cmp_ok( $list[5], '==', `$date '+%M'`, 'get_the_date minutes' );

    # this will occasionally fail tests
    #cmp_ok( $list[6], '==', `$date '+%S'`, 'get_the_date seconds');

    @list = $util->get_the_date( bump => 1 );
    cmp_ok( $list[0], '!=', `$date '+%d'`, 'get_the_date day' );
# if today is the first day of the month
    if ( `$date '+%d'` == 1 ) {
# then yesterdays month will not the same as this month
        cmp_ok( $list[1], '!=', `$date '+%m'`, 'get_the_date month' );
    }
    else {
        cmp_ok( $list[1], '==', `$date '+%m'`, 'get_the_date month' );
    }
    cmp_ok( $list[2], '==', `$date '+%Y'`, 'get_the_date year' );
    cmp_ok( $list[4], '==', `$date '+%H'`, 'get_the_date hour' );
    cmp_ok( $list[5], '==', `$date '+%M'`, 'get_the_date minutes' );
}
else {
    ok( 1, 'get_the_date - skipped (Date::Format not installed)' );
}

# graceful_exit

# install_if_changed
$backup = $util->archive_file( $rwtest, fatal => 0 );

# call it the new way
ok( $util->install_if_changed(
        newfile  => $backup,
        existing => $rwtest,
        mode     => '0644',
        notify   => 0,
        clean    => 0,
    ),
    'install_if_changed'
);

# install_from_sources_php
# sub is incomplete, so are the tests.

# install_from_source
ok( $util->install_from_source(
        package => "ripmime-1.4.0.6",
        site    => 'http://www.pldaniels.com',
        url     => '/ripmime',
        targets        => [ 'make', 'make install' ],
        bintest        => 'ripmime',
        source_sub_dir => 'mail',
        test_ok        => 1,
    ),
    'install_from_source'
);

ok( !$util->install_from_source(
        package => "mt",
        site    => "mt",
        url     => "dl",
        fatal   => 0,
        test_ok => 0
    ),
    'install_from_source'
);

# is_process_running
my $process_that_exists 
    = lc($OSNAME) eq 'darwin' ? 'launchd' 
    : lc($OSNAME) eq 'freebsd' ? 'cron'  
    : 'init';      # init does not run in a freebsd jail

ok( $util->is_process_running($process_that_exists), "is_process_running, $process_that_exists" )
   ; # or diag system "/bin/ps -ef && /bin/ps ax";
ok( !$util->is_process_running("nonexistent"), "is_process_running, nonexistent" );

# is_tainted

# logfile_append

$mod = "Date::Format";
if ( eval "require $mod" ) {
    ok( $util->logfile_append(
            file  => $rwtest,
            prog  => $0,
            lines => ['running tests'],
        ),
        'logfile_append'
    );

    #print `/bin/cat $rwtest` . "\n";

    ok( $util->logfile_append(
            file  => $rwtest,
            prog  => $0,
            lines => [ 'test1', 'test2' ],
        ),
        'logfile_append'
    );

    #print `/bin/cat $rwtest` . "\n";

    ok( $util->logfile_append(
            file  => $rwtest,
            prog  => $0,
            lines => [ 'test1', 'test2' ],
        ),
        'logfile_append'
    );
}

# mailtoaster
#

# mkdir_system
my $mkdir = "$tmp/bar";
ok( $util->mkdir_system( dir => $mkdir ), 'mkdir_system' );
ok( $util->chmod( file_or_dir => $mkdir, mode => '0744', fatal => 0 ),
    'chmod' );
ok( rmdir($mkdir), 'mkdir_system' );

# path_parse
my $pr = "/usr/bin";
my $bi = "awk";
ok( my ( $up1dir, $userdir ) = $util->path_parse("$pr/$bi"), 'path_parse' );
ok( $pr eq $up1dir,  'path_parse' );
ok( $bi eq $userdir, 'path_parse' );

$log->dump_audit(quiet=>1);
$log->{last_error} = scalar @{$log->{errors}};

# check_pidfile
# will fail because the file is too new
ok( !$util->check_pidfile( $rwtest, fatal => 0,debug=>0 ), 'check_pidfile' )
    or $log->dump_audit();

# will fail because the file is a directory
ok( !$util->check_pidfile( $tmp, fatal => 0,debug=>0 ), 'check_pidfile' )
    or $log->dump_audit();

# proper invocation
ok( $util->check_pidfile( "${rwtest}.pid", fatal => 0 ), 'check_pidfile')
    or $log->error();

# verify the contents of the file contains our PID
my ($pid) = $util->file_read( "${rwtest}.pid", fatal => 0 );
ok( $PROCESS_ID == $pid, 'check_pidfile' );

# regext_test
ok( $util->regexp_test(
        exp    => 'toast',
        string => 'mailtoaster rocks',
        debug  => 0,
    ),
    'regexp_test'
);



# parse_line 
my ( $foo, $bar ) = $util->parse_line( ' localhost1 = localhost, disk, da0, disk_da0 ' );
ok( $foo eq "localhost1", 'parse_line lead & trailing whitespace' );
ok( $bar eq "localhost, disk, da0, disk_da0", 'parse_line lead & trailing whitespace' );

( $foo, $bar ) = $util->parse_line( 'localhost1=localhost, disk, da0, disk_da0' );
ok( $foo eq "localhost1", 'parse_line no whitespace' );
ok( $bar eq "localhost, disk, da0, disk_da0", 'parse_line no whitespace' );

( $foo, $bar ) = $util->parse_line( ' htmldir = /usr/local/www/toaster ' );
ok( $foo && $bar, 'parse_line' );

( $foo, $bar )
    = $util->parse_line( ' hosts   = localhost lab.simerson.net seattle.simerson.net ' );
    ok( $foo eq "hosts", 'parse_line' );
    ok( $bar eq "localhost lab.simerson.net seattle.simerson.net", 'parse_line' );


# parse_config
# this fails because the filename is wrong
    ok( !$util->parse_config( 'toaster-wacher.conf',
                debug => 0,
                fatal => 0
                ),
            'parse_config invalid filename'
      );

# this works because find_config will check for -dist in the local dir
    my $conf;
    ok( $conf = $util->parse_config( 'toaster-watcher.conf',
                debug => 0,
                fatal => 0
                ),
            'parse_config correct'
      );


# sources_get
# do I really want a test script downloading stuff? probably not.

# source_warning
ok( $util->source_warning( package => 'foo' ), 'source_warning' );

# sudo
if ( !$< == 0 && $sudo_bin && -x $sudo_bin ) {
    ok( $util->sudo(), 'sudo' );
}
else {
    ok( !$util->sudo( fatal => 0 ), 'sudo' );
}

$log->dump_audit( quiet => 1 );
$log->{last_error} = scalar @{$log->{errors}};

# syscmd
my $tmpfile = '/tmp/provision-unix-test';
ok( $util->syscmd( "touch $tmpfile", fatal => 0 ), 'syscmd +');
ok( ! $util->syscmd( "rm $tmpfile.nonexist", fatal => 0,debug=>0 ), 'syscmd -');
ok( ! $util->syscmd( "rm $tmpfile.nonexist", fatal => 0,,debug=>0, timeout=>1), 'syscmd - (w/timeout)');
ok( $util->syscmd( "rm $tmpfile", fatal => 0, ), 'syscmd +');
    ok( $util->syscmd( "$rm $tmp/maildrop-qmail-domain", fatal => 0, ),
        'syscmd +'
) if ( $network && -f "$tmp/maildrop-qmail-domain" );

# file_delete
ok( $util->file_delete( $backup ), 'file_delete' );
ok( !$util->file_delete( $backup, fatal => 0 ), 'file_delete' );

ok( $util->file_delete( $rwtest       ), 'file_delete' );
ok( $util->file_delete( "$rwtest.md5" ), 'file_delete' );

ok( $util->clean_tmp_dir( $tmp ), 'clean_tmp_dir' );


# yes_or_no
ok( $util->yes_or_no( "test", timeout => 5 ), 'yes_or_no' );



