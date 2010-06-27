package Mail::Toaster::Setup;

use strict;
use warnings;

our $VERSION = '5.26';

use vars qw/ $conf $log $freebsd $darwin $err $qmail $toaster $util /;

use Carp;
use Config;
use Cwd;
use Data::Dumper;
use File::Copy;
use File::Path;
use English qw( -no_match_vars );
use Params::Validate qw( :all );
use Sys::Hostname;

use lib 'lib';
use Mail::Toaster       5.25; 

my @std_opts = qw/ test_ok debug fatal /;
my %std_opts = (
    test_ok => { type => BOOLEAN, optional => 1 },
    debug   => { type => BOOLEAN, optional => 1, default => 1 },
    fatal   => { type => BOOLEAN, optional => 1, default => 1 },
);


sub new {
    my $class = shift;
    my %p = validate(@_,
        {   toaster => { type => HASHREF, optional => 1 },
            conf    => { type => HASHREF, optional => 1 },
        } 
    );

    $toaster = $log = $p{toaster} || Mail::Toaster->new(debug=>0);
    $conf    = $p{conf} || $toaster->get_config;
    $util    = $toaster->{util};

    if ( $OSNAME eq "freebsd" ) {
        require Mail::Toaster::FreeBSD;
        $freebsd = Mail::Toaster::FreeBSD->new( toaster => $toaster );
    }
    elsif ( $OSNAME eq "darwin" ) {
        require Mail::Toaster::Darwin;
        $darwin = Mail::Toaster::Darwin->new( toaster => $toaster );
    }

    my $self = { 
        conf  => $conf,
        debug => $conf->{toaster_debug},
        fatal => 1,
    };
    bless( $self, $class );

    if ( $self->{debug} ) {
        $toaster->{debug} = 1;
        print "toaster_debug is set, prepare for lots of verbosity!\n";
    };

    return $self;
}

sub apache {
    my $self  = shift;
    my %p = validate( @_, {
            ver   => { type => SCALAR, optional => 1, },
            %std_opts,
        },
    );

    my $debug = $self->set_debug( $p{debug} );
    my $fatal = $self->set_fatal( $p{fatal} );

    return $p{test_ok} if defined $p{test_ok};

    my $ver   = $p{'ver'} || $conf->{install_apache} or do {
        $log->audit( "apache: installing, skipping (disabled)" );
        return;
    };

    require Mail::Toaster::Apache;
    my $apache = Mail::Toaster::Apache->new();

    require Cwd;
    my $old_directory = Cwd::cwd();

    if ( lc($ver) eq "apache" or lc($ver) eq "apache1" or $ver == 1 ) {
        my $src = $conf->{'toaster_src_dir'} || "/usr/local/src";
        $apache->install_apache1( $src, $conf );
    }
    elsif ( lc($ver) eq "ssl" ) {
        $apache->install_ssl_certs( conf=>$conf, type=>"rsa", debug=>$debug );
    }
    else {
        $apache->install_2( conf=>$conf, debug=>$debug );
    }

    chdir $old_directory if $old_directory;
    $apache->startup( conf=>$conf, debug=>$debug );
    return 1;
}

sub apache_conf_fixup {
# makes changes necessary for Apache to start while running in a jail

    my $self  = shift;
    my %p = validate( @_, {
            'fatal'   => { type => BOOLEAN, optional => 1 },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    return $p{test_ok} if defined $p{test_ok};

    my $fatal = $self->set_fatal( $p{fatal} );
    my $debug = $self->set_debug();

    require Mail::Toaster::Apache;
    my $apache    = Mail::Toaster::Apache->new;
    my $httpdconf = $apache->conf_get_dir( conf=> $conf );

    unless ( -e $httpdconf ) {
        print "Could not find your httpd.conf file!  FAILED!\n";
        return 0;
    }

    return if hostname !~ /^jail/;    # we're running in a jail

    my @lines = $util->file_read( $httpdconf, debug=>$debug );
    foreach my $line (@lines) {
        if ( $line =~ /^Listen 80/ ) { # this is only tested on FreeBSD
            my @ips = $util->get_my_ips(only=>"first", debug=>0);
            $line = "Listen $ips[0]:80";
        }
    }

    $util->file_write( "/var/tmp/httpd.conf", lines => \@lines, debug=>$debug );

    return unless $util->install_if_changed(
        newfile  => "/var/tmp/httpd.conf",
        existing => $httpdconf,
        clean    => 1,
        notify   => 1,
        debug    => $debug,
    );

    return 1;
}

sub autorespond {

    my $self  = shift;
    my %p = validate( @_, { %std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    my $debug = $self->set_debug( $p{debug} );
    my $fatal = $self->set_fatal( $p{fatal} );

    my $ver = $conf->{'install_autorespond'};
    if ( ! $ver ) {
        $log->audit( "autorespond install skipped (disabled)" ) if $debug;
        return;
    }

    if ( $OSNAME eq "freebsd" && $ver eq "port" ) {
        $freebsd->install_port( "autorespond" );
    }

    my $autorespond = $util->find_bin( "autorespond", fatal => 0, debug => 0 );

    # return success if it is installed.
    if ( $autorespond &&  -x $autorespond ) {
        $log->audit( "autorespond: installed ok (exists)" ) if $debug;
        return 1;
    }

    if ( $ver eq "port" ) {
        print
"autorespond: port install failed, attempting to install from source.\n";
        $ver = "2.0.5";
    }

    my @targets = ( 'make', 'make install' );

    if ( $OSNAME eq "darwin" || $OSNAME eq "freebsd" ) {
        print "autorespond: applying strcasestr patch.\n";
        my $sed = $util->find_bin( "sed", debug => 0 );
        my $prefix = $conf->{'toaster_prefix'} || "/usr/local";
        $prefix =~ s/\//\\\//g;
        @targets = (
            "$sed -i '' 's/strcasestr/strcasestr2/g' autorespond.c",
            "$sed -i '' 's/PREFIX=\$(DESTDIR)\\/usr/PREFIX=\$(DESTDIR)$prefix/g' Makefile",
            'make', 'make install'
        );
    }

    $util->install_from_source(
        package        => "autorespond-$ver",
        site           => 'http://www.inter7.com',
        url            => '/devel',
        targets        => \@targets,
        bintest        => 'autorespond',
        debug          => $debug,
        source_sub_dir => 'mail',
    );

    if ( -x $util->find_bin( "autorespond", fatal => 0, debug => 0, ) ) {
        $log->audit( "autorespond: installed ok" );
        return 1;
    }

    return 0;
}

sub clamav {
    my $self  = shift;
    my %p = validate( @_, { %std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing only
    my $debug = $self->set_debug( $p{debug} );
    my $fatal = $self->set_fatal( $p{fatal} );

    my $prefix   = $conf->{'toaster_prefix'}      || "/usr/local";
    my $confdir  = $conf->{'system_config_dir'}   || "/usr/local/etc";
    my $share    = "$prefix/share/clamav";
    my $clamuser = $conf->{'install_clamav_user'} || "clamav";
    my $ver      = $conf->{'install_clamav'};

    unless ($ver) {
        $log->audit( "clamav: installing, skipping (disabled)" ) if $debug;
        return 0;
    }

    my $installed;    # once installed, we'll set this

    # install via ports if selected
    if ( $OSNAME eq "freebsd" && $ver eq "port" ) {
        $freebsd->install_port( "clamav", flags => "BATCH=yes WITHOUT_LDAP=1",);

        $self->clamav_update( debug=>$debug );
        $self->clamav_perms ( debug=>$debug );
        $self->clamav_start ( debug=>$debug );
        return 1;
    }

    # add the clamav user and group
    unless ( getpwuid($clamuser) ) {
        $self->group_add( "clamav", "90" );
        $self->user_add( $clamuser, 90, 90 );
    }

    unless ( getpwnam($clamuser) ) {
        print "User clamav user installation FAILED, I cannot continue!\n";
        return 0;
    }

    # install via ports if selected
    if ( $OSNAME eq "darwin" && $ver eq "port" ) {
        if ( $darwin->install_port( "clamav" ) ) {
            $log->audit( "clamav: installing, ok" );
        }
        $self->clamav_update( debug=>$debug );
        $self->clamav_perms ( debug=>$debug );
        $self->clamav_start ( debug=>$debug );
        return 1;
    }

    # port installs didn't work out, time to build from sources

    # set a default version of ClamAV if not provided
    if ( $ver eq "1" ) { $ver = "0.96.1"; }; # latest as of 6/2010

    # download the sources, build, and install ClamAV
    $util->install_from_source(
        package        => 'clamav-' . $ver,
        site           => 'http://' . $conf->{'toaster_sf_mirror'},
        url            => '/clamav',
        targets        => [ './configure', 'make', 'make install' ],
        bintest        => 'clamdscan',
        source_sub_dir => 'mail',
        debug          => $debug,
    );

    if ( -x $util->find_bin( "clamdscan", fatal => 0, debug => $debug)) {
        $log->audit( "clamav: installed ok" );
    }
    else {
        $log->audit( "clamav: install FAILED" );
        return 0;
    }

    $self->clamav_update(  debug=>$debug );
    $self->clamav_perms (  debug=>$debug );
    $self->clamav_start (  debug=>$debug );
}

sub clamav_perms {
    my $self  = shift;
    my %p = validate( @_, { %std_opts } );

    my $prefix  = $conf->{'toaster_prefix'}      || "/usr/local";
    my $confdir = $conf->{'system_config_dir'}   || "/usr/local/etc";
    my $clamuid = $conf->{'install_clamav_user'} || "clamav";
    my $share   = "$prefix/share/clamav";

    foreach my $file ( $share, "$share/daily.cvd", "$share/main.cvd",
        "$share/viruses.db", "$share/viruses.db2", "/var/log/freshclam.log", ) {

        print "setting the ownership of $file to $clamuid.\n";
        $util->chown( $file, uid => $clamuid, gid => 'clamav' ) if -e $file;
    }

    $util->syscmd( "pw user mod clamav -G qmail", debug => $p{debug} );
}

sub clamav_run {
# create a FreeBSD rc.d startup file

    my $self = shift;
    my %p = validate( @_, {
            'confdir' => { type => SCALAR,  },
            %std_opts
        },
    );

    my $debug = $self->set_debug( $p{debug} );
    my $fatal = $self->set_fatal( $p{fatal} );
    my $confdir = $p{'confdir'};

    my $RUN;
    my $run_f = "$confdir/rc.d/clamav.sh";

    unless ( -s $run_f ) {
        print "Creating $confdir/rc.d/clamav.sh startup file.\n";
        open( $RUN, ">", $run_f )
          or croak "clamav: couldn't open $run_f for write: $!";

        print $RUN <<EO_CLAM_RUN;
#!/bin/sh

case "\$1" in
    start)
        /usr/local/bin/freshclam -d -c 2 -l /var/log/freshclam.log
        echo -n " freshclam"
        ;;

    stop)
        /usr/bin/killall freshclam > /dev/null 2>&1
        echo -n " freshclam"
        ;;

    *)
        echo ""
        echo "Usage: `basename \$0` { start | stop }"
        echo ""
        exit 64
        ;;
esac
EO_CLAM_RUN

        close $RUN;

        $util->chmod(
            file => "$confdir/rc.d/freshclam.sh",
            mode => '0755',
            debug=> $debug,
        );

        $util->chmod(
            file => "$confdir/rc.d/clamav.sh",
            mode => '0755',
            debug=> $debug,
        );
    }
}

sub clamav_start {
    # get ClamAV running

    my $self  = shift;
    my %p = validate( @_, { %std_opts } );

    my $debug = $self->set_debug( $p{debug} );
    my $fatal = $self->set_fatal( $p{fatal} );

    if ( $util->is_process_running('clamd') ) {
        $log->audit( "clamav: starting up, ok (already running)" );
    }

    print "Starting up ClamAV...\n";

    if ( $OSNAME ne "freebsd" ) {
        $util->_incomplete_feature(
            {
                mess   => "start up ClamAV on $OSNAME",
                action =>
'You will need to start up ClamAV yourself and make sure it is configured to launch at boot time.',
            }
        );
        return;
    };

    $freebsd->conf_check(
        check => "clamav_clamd_enable",
        line  => 'clamav_clamd_enable="YES"',
        debug => $debug,
    );

    $freebsd->conf_check(
        check => "clamav_freshclam_enable",
        line  => 'clamav_freshclam_enable="YES"',
        debug => $debug,
    );

    print "(Re)starting ClamAV's clamd...";
    my $start = "/usr/local/etc/rc.d/clamav-freshclam";
    $start = "$start.sh" if ! -x $start;

    if ( -x $start ) {
        system "$start restart";
        print "done.\n";
    }
    else {
        print
            "ERROR: I could not find the startup (rc.d) file for clamAV!\n";
    }

    print "(Re)starting ClamAV's freshclam...";
    $start = "/usr/local/etc/rc.d/clamav-clamd";
    $start = "$start.sh" if ! -x $start;
    system "$start restart";

    if ( $util->is_process_running('clamd', debug=>0) ) {
        $log->audit( "clamav: starting up, ok" );
    }

    # These are no longer required as the FreeBSD ports now installs
    # startup files of its own.
    #clamav_run($confdir);
    if ( -e "/usr/local/etc/rc.d/clamav.sh" ) {
        unlink "/usr/local/etc/rc.d/clamav.sh";
    }

    if ( -e "/usr/local/etc/rc.d/freshclam.sh" ) {
        unlink "/usr/local/etc/rc.d/freshclam.sh";
    }
}

sub clamav_update {

    my $self  = shift;
    my %p = validate( @_, { %std_opts } );

    my $debug = $self->set_debug( $p{debug} );
    my $fatal = $self->set_fatal( $p{fatal} );

    # set up freshclam (keeps virus databases updated)
    my $logfile = "/var/log/freshclam.log";
    unless ( -e $logfile ) {
        $util->syscmd( "touch $logfile", debug=>0 );
        $util->chmod( file => $logfile, mode => '0644', debug=>0 );
        $self->clamav_perms(  debug=>0 );
    }

    my $freshclam = $util->find_bin( "freshclam", debug=>0 );

    if ( -x $freshclam ) {
        $util->syscmd( "$freshclam", debug => 0, fatal => 0 );
    }
    else { print "couldn't find freshclam!\n"; }
}

sub config {

    my $self  = shift;
    my %p = validate( @_, { %std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing only
    my $debug = $self->set_debug( $p{debug} );
    my $fatal = $self->set_fatal( $p{fatal} );

    # apply the platform specific changes to the config file
    $self->config_tweaks( debug=>$debug, fatal=>$fatal );

    my $file_name = "toaster-watcher.conf";
    my $file_path = $toaster->find_config(
        file  => $file_name,
        debug => $debug,
        fatal => $fatal,
    );
    $conf = $self->refresh_config( $file_path ) or return;

    $self->config_hostname();
    $self->config_postmaster();
    $self->config_test_email();
    $self->config_test_email_pass();
    $self->config_vpopmail_mysql_pass();
    $self->config_openssl();

    # format the config entries to match config file format
    my @fields = qw/ toaster_hostname toaster_admin_email toaster_test_email
        toaster_test_email_pass vpopmail_mysql_pass ssl_country ssl_state 
        ssl_locality ssl_organization /;
    push @fields, 'vpopmail_mysql_pass' if $conf->{'vpopmail_mysql'};

    my @lines = $util->file_read( $file_path, debug => 0 );
    foreach my $key ( @fields ) {
        foreach my $line (@lines) {
            if ( $line =~ /^$key\s*=/ ) {
                $line = sprintf( '%-34s = %s', $key, $conf->{$key} );
            }
        };
    };

    # write all the new settings to disk.
    $util->file_write( "/tmp/toaster-watcher.conf",
        lines => \@lines,
        debug => 0,
    );

    # save the changes back to the current file
    my $r = $util->install_if_changed(
            newfile  => "/tmp/toaster-watcher.conf",
            existing => $file_path,
            mode     => '0640',
            clean    => 1,
            notify   => -e $file_path ? 1 : 0,
            debug    => 0,
            fatal    => $fatal,
    )
    or return $log->error( "installing /tmp/toaster-watcher.conf to $file_path failed!",
        fatal => $fatal,
    );

    $r = $r == 1 ? "ok" : "ok (current)";
    $log->audit( "config: updating $file_path, $r" ) if $debug;

    # install $file_path in $prefix/etc/toaster-watcher.conf if it doesn't exist
    # already
    my $config_dir = $conf->{'system_config_dir'} || '/usr/local/etc';

    # if $config_dir is missing, create it
    $util->mkdir_system( dir => $config_dir, debug=>$debug )
        if ! -e $config_dir;

    my @configs = (
        { newfile  => $file_path, existing => "$config_dir/$file_name", mode => '0640', overwrite => 0 },
        { newfile  => $file_path, existing => "$config_dir/$file_name-dist", mode => '0640', overwrite => 1 },
        { newfile  => 'toaster.conf-dist', existing => "$config_dir/toaster.conf", mode => '0644', overwrite => 0 },
        { newfile  => 'toaster.conf-dist', existing => "$config_dir/toaster.conf-dist", mode => '0644', overwrite => 1 },
    );

    foreach ( @configs ) {
        next if -e $_->{existing} && ! $_->{overwrite};
        $util->install_if_changed(
            newfile  => $_->{newfile},
            existing => $_->{existing},
            mode     => $_->{mode},
            clean    => 0,
            notify   => 1,
            debug    => 0,
            fatal    => $fatal,
        );
    };
}

sub config_apply_tweaks {
    my $self = shift;
    my %p = validate( @_,
        { 
            file    => { type => SCALAR },
            changes => { type => ARRAYREF },
            %std_opts,
        },
    );

# changes is a list (array) of changes to apply to a text file 
# each change is a hash with two elements: search, replace. the contents of
# file is searched for lines that matches search. Matches are replaced by the
# replace string. If search2 is also supplied and search does not match, 
# search2 will be replaced.
# Ex:
# $changes = (
#    { search  => '#ssl_cert = /etc/ssl/certs/server.pem',
#      replace => 'ssl_cert = /etc/ssl/certs/server.pem',
#    },
# ); 
#
    # read in file
    my @lines = $util->file_read( $p{file} ) or return;

    my $total_found = 0;
    my @edits = @{ $p{changes} };
    foreach my $e ( @edits ) {
        my $search = $e->{search} or next;
        my $replace = $e->{replace} or next;
        my $search2 = $e->{search2};
        my $found = 0;

        if ( $search2 && $search2 eq 'section' ) {
# look for a multiline pattern such as: protocol manageseive {  ....  }
            my (@after, $in);
            foreach my $line ( @lines ) {
                if ( $in ) {
                    next if $line !~ /^ \s* \} \s* $/xms;
                    $in = 0;
                    next;
                }
                if ( $search eq $line ) {
                    $found++;
                    $in++;
                    next;
                };
                push @after, $line if ! $in;
            };
            @lines = @after;
        };
# search entire file for $search string
        for ( my $i = 0; $i < scalar @lines; $i++ ) {
            if ( $lines[$i] eq $search ) {
                $lines[$i] = $replace;
                $found++;
            };
        }
# search entire file for $search2 string
        if ( ! $found && $search2 ) {
            for ( my $i = 0; $i < scalar @lines; $i++ ) {
                if ( $lines[$i] eq $search2 ) {
                    $lines[$i] = $replace;
                    $found++;
                };
            }
        };
        if ( ! $found ) {
            $log->error( "attempt to replace\n$search\n\twith\n$replace\n\tfailed", fatal => 0);
        };
        $total_found += $found;
    };

    $log->audit( "config_tweaks replaced $total_found lines" );

    $util->file_write( $p{file}, lines => \@lines );
};

sub config_hostname {
    my $self = shift;

    return if ( $conf->{'toaster_hostname'} && $conf->{'toaster_hostname'} ne "mail.example.com" );

    $conf->{'toaster_hostname'} = $util->ask(
        "the hostname of this mail server",
        default  => hostname,
    );
    chomp $conf->{'toaster_hostname'};

    $log->audit( "toaster hostname set to $conf->{'toaster_hostname'}" )
      if $self->{debug};
};

sub config_openssl {
    my $self = shift;
    # OpenSSL certificate settings

    # country
    if ( $conf->{'ssl_country'} eq "SU" ) {
        print "             SSL certificate defaults\n";
        $conf->{'ssl_country'} =
          uc( $util->ask( "your 2 digit country code (US)", default  => "US" )
          );
    }
    $log->audit( "config: ssl_country, (" . $conf->{'ssl_country'} . ")" ) if $self->{debug};

    # state
    if ( $conf->{'ssl_state'} eq "saxeT" ) {
        $conf->{'ssl_state'} =
          $util->ask( "the name (non abbreviated) of your state" );
    }
    $log->audit( "config: ssl_state, (" . $conf->{'ssl_state'} . ")" ) if $self->{debug};

    # locality (city)
    if ( $conf->{'ssl_locality'} eq "dnalraG" ) {
        $conf->{'ssl_locality'} =
          $util->ask( "the name of your locality/city" );
    }
    $log->audit( "config: ssl_locality, (" . $conf->{'ssl_locality'} . ")" ) if $self->{debug};

    # organization
    if ( $conf->{'ssl_organization'} eq "moc.elpmaxE" ) {
        $conf->{'ssl_organization'} = $util->ask( "the name of your organization" );
    }
    $log->audit( "config: ssl_organization, (" . $conf->{'ssl_organization'} . ")" )
      if $self->{debug};
};

sub config_postmaster {
    my $self = shift;

    return if ( $conf->{'toaster_admin_email'} && $conf->{'toaster_admin_email'} ne "postmaster\@example.com" );

    $conf->{'toaster_admin_email'} = $util->ask(
        "the email address for administrative emails and notices\n".
            " (probably yours!)",
        default => "postmaster",
    ) || 'root';
 
    $log->audit(
        "toaster admin emails sent to $conf->{'toaster_admin_email'}, ok" )
      if $self->{debug};
};

sub config_test_email {
    my $self = shift;

    return if $conf->{'toaster_test_email'} ne "test\@example.com";

    $conf->{'toaster_test_email'} = $util->ask(
        "an email account for running tests",
        default  => "postmaster\@" . $conf->{'toaster_hostname'}
    );
    
    $log->audit( "toaster test account set to $conf->{'toaster_test_email'}" )
      if $self->{debug};
};

sub config_test_email_pass {
    my $self = shift;

    return if ( $conf->{'toaster_test_email_pass'} && $conf->{'toaster_test_email_pass'} ne "cHanGeMe" );

    $conf->{'toaster_test_email_pass'} = $util->ask( "the test email account password" );

    $log->audit(
        "toaster test password set to $conf->{'toaster_test_email_pass'}" )
      if $self->{debug};
};

sub config_tweaks {

    my $self  = shift;
    my %p = validate( @_, { %std_opts } );

    my $debug = $self->set_debug( $p{debug} );
    my $fatal = $self->set_fatal( $p{fatal} );

    my $hostname = hostname;
    my $status = "ok";

    my $file = $toaster->find_config(
        file  => 'toaster-watcher.conf',
        debug => $debug,
        fatal => $fatal,
    );

    # verify that find_config worked and $file is readable
    if ( ! -r $file ) {
        $log->audit( "config_tweaks: read test on $file, FAILED" );
        carp "find_config returned $file: $!\n";
        croak if $fatal;
        return;
    };

    my %changes;
    %changes = $self->config_tweaks_freebsd() if $OSNAME eq 'freebsd';
    %changes = $self->config_tweaks_darwin()  if $OSNAME eq 'darwin';
    %changes = $self->config_tweaks_linux()   if $OSNAME eq 'linux';

    if ( $hostname && $hostname =~ /mt-test/ ) {
        %changes = ( %changes, $self->config_tweaks_testing(%changes));
    };

    # foreach key of %changes, apply to $conf
    my @lines = $util->file_read( $file );

    foreach my $line (@lines) {
        next if $line =~ /^#/;  # comment lines
        next if $line !~ /=/;   # not a key = value

        my ( $key, $val ) = $toaster->parse_line( $line, strip => 0 );

        if ( defined $changes{$key} && $changes{$key} ne $val ) {
            $status = "changed";

            #print "\t setting $key to ". $changes{$key} . "\n" if $debug;

            $line = sprintf( '%-34s = %s', $key, $changes{$key} );

            print "\t$line\n";
        }
    }

    # all done unless changes are required
    return 1 unless ( $status && $status eq "changed" );

    # ask the user for permission to install
    return 1
      unless $util->yes_or_no(
'config_tweaks: The changes shown above are recommended for use on your system.
May I apply the changes for you?',
        timeout => 30,
      );

    # write $conf to temp file
    $util->file_write( "/tmp/toaster-watcher.conf",
        lines => \@lines,
        debug => 0,
    );

    # if the file ends with -dist, then save it back with out the -dist suffix
    # the find_config sub will automatically prefer the newer non-suffixed one
    if ( $file =~ m/(.*)-dist\z/ ) {
        $file = $1;
    };

    # update the file if there are changes
    my $r = $util->install_if_changed(
        newfile  => "/tmp/toaster-watcher.conf",
        existing => $file,
        clean    => 1,
        notify   => 0,
        debug    => 0,
    );

    return 0 unless $r;
    $r == 1 ? $r = "ok" : $r = "ok (current)";
    $log->audit( "config_tweaks: updated $file, $r" );
}

sub config_tweaks_darwin {
    my $self = shift;

    $log->audit( "config_tweaks: applying Darwin tweaks" );

    return (
        toaster_http_base    => '/Library/WebServer',
        toaster_http_docs    => '/Library/WebServer/Documents',
        toaster_cgi_bin      => '/Library/WebServer/CGI-Executables',
        toaster_prefix       => '/opt/local',
        toaster_src_dir      => '/opt/local/src',
        system_config_dir    => '/opt/local/etc',
        vpopmail_valias      => '0',
        install_mysql        => '0      # 0, 1, 2, 3, 40, 41, 5',
        install_portupgrade  => '0',
        filtering_maildrop_filter_file => '/opt/local/etc/mail/mailfilter',
        qmail_mysql_include  => '/opt/local/lib/mysql/libmysqlclient.a',
        vpopmail_home_dir    => '/opt/local/vpopmail',
        vpopmail_mysql       => '0',
        smtpd_use_mysql_relay_table => '0',
        qmailadmin_spam_command => '| /opt/local/bin/maildrop /opt/local/etc/mail/mailfilter',
        qmailadmin_http_images  => '/Library/WebServer/Documents/images',
        apache_suexec_docroot   => '/Library/WebServer/Documents',
        apache_suexec_safepath  => '/opt/local/bin:/usr/bin:/bin',
    );
};

sub config_tweaks_freebsd {

    $log->audit( "config_tweaks: applying FreeBSD tweaks" );

    return (
        install_squirrelmail => 'port    # 0, ver, port',
        install_autorespond  => 'port    # 0, ver, port',
#        install_isoqlog      => 'port    # 0, ver, port',
        install_ezmlm        => 'port    # 0, ver, port',
        install_courier_imap => '0       # 0, ver, port',
        install_dovecot      => 'port    # 0, ver, port',
        install_clamav       => 'port    # 0, ver, port',
        install_ripmime      => 'port    # 0, ver, port',
        install_cronolog     => 'port    # ver, port',
        install_daemontools  => 'port    # ver, port',
        install_qmailadmin   => 'port    # 0, ver, port',
    )
}

sub config_tweaks_linux {
    $log->audit( "config_tweaks: applying Linux tweaks " );

    return (
        toaster_http_base           => '/var/www',
        toaster_http_docs           => '/var/www',
        toaster_cgi_bin             => '/usr/lib/cgi-bin',
        vpopmail_valias             => '0',
        install_mysql               => '0      # 0, 1, 2, 3, 40, 41, 5',
        vpopmail_mysql              => '0',
        smtpd_use_mysql_relay_table => '0',
        qmailadmin_http_images      => '/var/www/images',
        apache_suexec_docroot       => '/var/www',
        apache_suexec_safepath      => '/usr/local/bin:/usr/bin:/bin',
        install_dovecot             => '1.0.2',
    )
}

sub config_tweaks_testing {
    my ($self, %changes) = @_;

    $log->audit( "config_tweaks: applying MT testing tweaks" );

    $changes{'toaster_hostname'}      = 'jail10.cadillac.net';
    $changes{'toaster_admin_email'}   = 'postmaster@jail10.cadillac.net';
    $changes{'toaster_test_email'}    = 'test@jail10.cadillac.net';
    $changes{'toaster_test_email_pass'}   = 'cHanGeMed';
    $changes{'install_squirrelmail_sql'}  = '1';
    $changes{'install_apache2_modperl'}   = '1';
    $changes{'install_apache_suexec'}     = '1';
    $changes{'install_phpmyadmin'}        = '1';
    $changes{'install_vqadmin'}           = '1';
    $changes{'install_openldap_client'}   = '1';
    $changes{'install_ezmlm_cgi'}         = '1';
    $changes{'install_dspam'}             = '1';
    $changes{'install_pyzor'}             = '1'; 
    $changes{'install_bogofilter'}        = '1';
    $changes{'install_dcc'}               = '1';
    $changes{'vpopmail_default_domain'}       = 'jail10.cadillac.net';
    $changes{'pop3_ssl_daemon'}               = 'qpop3d';

    return %changes;
}

sub config_vpopmail_mysql_pass {
    my $self = shift;

    return if ! $conf->{'vpopmail_mysql'};
    return if ( $conf->{'vpopmail_mysql_pass'} 
        && $conf->{'vpopmail_mysql_pass'} ne "supersecretword" );

    $conf->{'vpopmail_mysql_pass'} =
        $util->ask( "the password for securing vpopmails "
            . "database connection. You MUST enter a password here!",
        );

    $log->audit( "vpopmail MySQL password set to $conf->{'vpopmail_mysql_pass'}") if $self->{debug};
}

sub courier_imap {

    my $self  = shift;
    my %p = validate( @_, { %std_opts } );

    return $p{test_ok} if defined $p{test_ok};
    my $debug = $self->set_debug( $p{debug} );
    my $fatal = $self->set_fatal( $p{fatal} );

    my $ver = $conf->{'install_courier_imap'} or do {
        $log->audit( "courier: installing, skipping (disabled)" );
        $self->courier_startup_freebsd() if $OSNAME eq 'freebsd'; # disable startup
        return;
    };

    $log->audit("courier $ver is selected" );

    if ( $OSNAME eq "freebsd" && $ver eq "port" ) {
        $log->audit("using courier from FreeBSD ports" );
        $self->courier_authlib( debug => $debug, fatal => $fatal );
        $self->courier_imap_freebsd();
        $self->courier_startup( debug=>$debug );
        return 1 if $freebsd->is_port_installed( "courier-imap", debug=>0);
    }
    elsif ( $OSNAME eq "darwin" ) {
        return $darwin->install_port( "courier-imap", );
    }

    # if a specific version has been requested, install it from sources
    # but first, a default for users who didn't edit toaster-watcher.conf
    $ver = "4.8.0" if ( $ver eq "port" );

    my $site    = "http://" . $conf->{'toaster_sf_mirror'};
    my $confdir = $conf->{'system_config_dir'} || "/usr/local/etc";
    my $prefix  = $conf->{'toaster_prefix'} || "/usr/local";

    $ENV{"HAVE_OPEN_SMTP_RELAY"} = 1;    # circumvent bug in courier

    my $conf_args = "--prefix=$prefix --exec-prefix=$prefix --without-authldap --without-authshadow --with-authvchkpw --sysconfdir=/usr/local/etc/courier-imap --datadir=$prefix/share/courier-imap --libexecdir=$prefix/libexec/courier-imap --enable-workarounds-for-imap-client-bugs --disable-root-check --without-authdaemon";

    print "./configure $conf_args\n";
    my $make = $util->find_bin( "gmake", debug=>0, fatal=>0 ) ||
        $util->find_bin( "make", debug=>0);
    my @targets = ( "./configure " . $conf_args, $make, "$make install" );

    $util->install_from_source(
        package        => "courier-imap-$ver",
        site           => $site,
        url            => "/courier",
        targets        => \@targets,
        bintest        => "imapd",
        source_sub_dir => 'mail',
        debug          => $debug
    );

    $self->courier_startup(  debug=>$debug );
}

sub courier_imap_freebsd {
    my $self = shift;

#   my @defs = "WITH_VPOPMAIL=1";
#   push @defs, "WITHOUT_AUTHDAEMON=1";
#   push @defs, "WITH_CRAM=1";
#   push @defs, "AUTHMOD=authvchkpw";

    $freebsd->install_port( "courier-imap",
        #flags  => join( ",", @defs ),
        options => "#\n# This file was generated by mail-toaster
# No user-servicable parts inside!
# Options for courier-imap-4.1.1,1
_OPTIONS_READ=courier-imap-4.1.1,1
WITH_OPENSSL=true
WITHOUT_FAM=true
WITHOUT_DRAC=true
WITHOUT_TRASHQUOTA=true
WITHOUT_GDBM=true
WITHOUT_IPV6=true
WITHOUT_AUTH_LDAP=true
WITHOUT_AUTH_MYSQL=true
WITHOUT_AUTH_PGSQL=true
WITHOUT_AUTH_USERDB=true
WITH_AUTH_VCHKPW=true",
    );
}

sub courier_authlib {
    my $self  = shift;
    my %p = validate( @_, { %std_opts } );

    my $debug = $self->set_debug( $p{debug} );
    my $fatal = $self->set_fatal( $p{fatal} );

    my $prefix  = $conf->{'toaster_prefix'}    || "/usr/local";
    my $confdir = $conf->{'system_config_dir'} || "/usr/local/etc";

    if ( $OSNAME ne "freebsd" ) {
        print "courier-authlib build support is not available for $OSNAME yet.\n";
        return 0;
    };

    if ( ! $freebsd->is_port_installed( "courier-authlib", debug=>$debug ) ) {

        unlink "/var/db/ports/courier-authlib/options"
            if -f "/var/db/ports/courier-authlib/options";

        if ( -d "/usr/ports/security/courier-authlib" ) {

            $freebsd->install_port( "courier-authlib",
                options => "
# This file was generated by mail-toaster
# No user-servicable parts inside!
# Options for courier-authlib-0.58_2
_OPTIONS_READ=courier-authlib-0.58_2
WITHOUT_GDBM=true
WITHOUT_AUTH_LDAP=true
WITHOUT_AUTH_MYSQL=true
WITHOUT_AUTH_PGSQL=true
WITHOUT_AUTH_USERDB=true
WITH_AUTH_VCHKPW=true",
            );
        }

        if ( -d "/usr/ports/mail/courier-authlib-vchkpw" ) {
            $freebsd->install_port( "courier-authlib-vchkpw",
                flags => "AUTHMOD=authvchkpw",
            );
        }
    }

    # install a default authdaemonrc
    my $authrc = "$confdir/authlib/authdaemonrc";

    if ( ! -e $authrc ) {
        if ( -e "$authrc.dist" ) {
            print "installing default authdaemonrc.\n";
            copy("$authrc.dist", $authrc);
        }
    };

    if ( `grep 'authmodulelist=' $authrc | grep ldap` ) {
        $self->config_apply_tweaks(
            file => $authrc,
            changes => [
                {   search  => q{authmodulelist="authuserdb authvchkpw authpam authldap authmysql authpgsql"},
                    replace => q{authmodulelist="authvchkpw"},
                },
            ],
        );
        $log->audit( "courier_authlib: fixed up $authrc" );
    }

    $freebsd->conf_check(
        check => "courier_authdaemond_enable",
        line  => "courier_authdaemond_enable=\"YES\"",
        debug => $debug,
    );

    if ( ! -e "/var/run/authdaemond/pid" ) {
        my $start = "$prefix/etc/rc.d/courier-authdaemond";
        foreach ( $start, "$start.sh" ) {
            $util->syscmd( "$_ start", debug=>0) if -x $_;
        };
    };
    return 1;
}

sub courier_ssl {
    my $self = shift;

    my $confdir = $conf->{'system_config_dir'} || "/usr/local/etc";
    my $prefix  = $conf->{'toaster_prefix'} || "/usr/local";
    my $share   = "$prefix/share/courier-imap";

    # apply ssl_ values from t-w.conf to courier's .cnf files
    if ( ! -e "$share/pop3d.pem" || ! -e "$share/imapd.pem" ) {
        my $pop3d_ssl_conf = "$confdir/courier-imap/pop3d.cnf";
        my $imapd_ssl_conf = "$confdir/courier-imap/imapd.cnf";

        my $common_name = $conf->{'ssl_common_name'} || $conf->{'toaster_hostname'};
        my $org      = $conf->{'ssl_organization'};
        my $locality = $conf->{'ssl_locality'};
        my $state    = $conf->{'ssl_state'};
        my $country  = $conf->{'ssl_country'};

        my $sed_command = "sed -i .bak -e 's/US/$country/' ";
        $sed_command .= "-e 's/NY/$state/' ";
        $sed_command .= "-e 's/New York/$locality/' ";
        $sed_command .= "-e 's/Courier Mail Server/$org/' ";
        $sed_command .= "-e 's/localhost/$common_name/' ";

        print "$sed_command\n";
        system "$sed_command $pop3d_ssl_conf $imapd_ssl_conf";
    };

    # use the toaster generated cert, if available
    my $crt = "/usr/local/openssl/certs/server.pem";
    foreach my $courier_pem ( "$share/pop3d.pem", "$share/imapd.pem" ) {
        copy( $crt, $courier_pem ) if ( -f $crt && ! -e $courier_pem );
    };

    # generate self-signed SSL certificates for pop3/imap
    if ( ! -e "$share/pop3d.pem" ) {
        chdir $share;
        $util->syscmd( "./mkpop3dcert", debug => 0 );
    }

    if ( !-e "$share/imapd.pem" ) {
        chdir $share;
        $util->syscmd( "./mkimapdcert", debug => 0 );
    }
};

sub courier_startup {

    my $self  = shift;
    my %p = validate( @_, { %std_opts } );

    my $debug = $self->set_debug( $p{debug} );
    my $fatal = $self->set_fatal( $p{fatal} );

    my $prefix  = $conf->{'toaster_prefix'} || "/usr/local";
    my $ver     = $conf->{'install_courier_imap'};
    my $confdir = $conf->{'system_config_dir'} || "/usr/local/etc";

    if ( !chdir("$confdir/courier-imap") ) {
        print "could not chdir $confdir/courier-imap.\n" if $debug;
        die ""                                           if $fatal;
        return 0;
    }

    copy( "pop3d.cnf.dist",       "pop3d.cnf" )    if ( !-e "pop3d.cnf" );
    copy( "pop3d.dist",           "pop3d" )        if ( !-e "pop3d" );
    copy( "pop3d-ssl.dist",       "pop3d-ssl" )    if ( !-e "pop3d-ssl" );
    copy( "imapd.cnf.dist",       "imapd.cnf" )    if ( !-e "imapd.cnf" );
    copy( "imapd.dist",           "imapd" )        if ( !-e "imapd" );
    copy( "imapd-ssl.dist",       "imapd-ssl" )    if ( !-e "imapd-ssl" );
    copy( "quotawarnmsg.example", "quotawarnmsg" ) if ( !-e "quotawarnmsg" );

    $self->courier_ssl();

    if ( $OSNAME eq "freebsd" && $ver eq "port" ) {
        $self->courier_startup_freebsd();
    }
    else {
        my $libe = "$prefix/libexec/courier-imap";
        if ( -e "$libe/imapd.rc" ) {
            print "creating symlinks in /usr/local/sbin for courier daemons\n";
            symlink( "$libe/imapd.rc",     "$prefix/sbin/imap" );
            symlink( "$libe/pop3d.rc",     "$prefix/sbin/pop3" );
            symlink( "$libe/imapd-ssl.rc", "$prefix/sbin/imapssl" );
            symlink( "$libe/pop3d-ssl.rc", "$prefix/sbin/pop3ssl" );
        }
        else {
            print
              "FAILURE: sorry, I can't find the courier rc files on $OSNAME.\n";
        }
    }

    $self->courier_authlib();

    unless ( -e "/var/run/imapd-ssl.pid" ) {
        $util->syscmd( "$prefix/sbin/imapssl start", debug=>0 )
          if ( -x "$prefix/sbin/imapssl" );
    }

    unless ( -e "/var/run/imapd.pid" ) {
        $util->syscmd( "$prefix/sbin/imap start", debug=>0 )
          if ( -x "$prefix/sbin/imapssl" );
    }

    unless ( -e "/var/run/pop3d-ssl.pid" ) {
        $util->syscmd( "$prefix/sbin/pop3ssl start", debug=>0 )
          if ( -x "$prefix/sbin/pop3ssl" );
    }

    if ( $conf->{'pop3_daemon'} eq "courier" ) {

        if ( !-e "/var/run/pop3d.pid" ) {

            $util->syscmd( "$prefix/sbin/pop3 start", debug=>0 )
              if ( -x "$prefix/sbin/pop3" );
        }
    }
}

sub courier_startup_freebsd {
    my $self = shift;

    my $prefix  = $conf->{'toaster_prefix'} || "/usr/local";
    my $confdir = $conf->{'system_config_dir'} || "/usr/local/etc";

    # cleanup stale links, created long ago when rc.d files had .sh endings
    foreach ( qw/ imap imapssl pop3 pop3ssl / ) {
        if ( -e "$prefix/sbin/$_" ) {
            readlink "$prefix/sbin/$_" or unlink "$prefix/sbin/$_";
        };
    };

    if ( ! -e "$prefix/sbin/imap" ) {
        $log->audit( "setting up startup file shortcuts for daemons");
        symlink( "$confdir/rc.d/courier-imap-imapd", "$prefix/sbin/imap" );
        symlink( "$confdir/rc.d/courier-imap-pop3d", "$prefix/sbin/pop3" );
        symlink( "$confdir/rc.d/courier-imap-imapd-ssl", "$prefix/sbin/imapssl" );
        symlink( "$confdir/rc.d/courier-imap-pop3d-ssl", "$prefix/sbin/pop3ssl" );
    }

    my $start = $conf->{install_courier_imap} ? 'YES' : 'NO';

    $freebsd->conf_check(
        check => "courier_imap_imapd_enable",
        line  => "courier_imap_imapd_enable=\"$start\"",
        debug => 0,
    );

    $freebsd->conf_check(
        check => "courier_imap_imapdssl_enable",
        line  => "courier_imap_imapdssl_enable=\"$start\"",
        debug => 0,
    );

    $freebsd->conf_check(
        check => "courier_imap_imapd_ssl_enable",
        line  => "courier_imap_imapd_ssl_enable=\"$start\"",
        debug => 0,
    );

    $freebsd->conf_check(
        check => "courier_imap_pop3dssl_enable",
        line  => "courier_imap_pop3dssl_enable=\"$start\"",
        debug => 0,
    );

    $freebsd->conf_check(
        check => "courier_imap_pop3d_ssl_enable",
        line  => "courier_imap_pop3d_ssl_enable=\"$start\"",
        debug => 0,
    );

    if ( $conf->{'pop3_daemon'} eq "courier" ) {
        $freebsd->conf_check(
            check => "courier_imap_pop3d_enable",
            line  => "courier_imap_pop3d_enable=\"$start\"",
            debug => 0,
        );
    }
};

sub cpan {
    my $self  = shift;
    my %p = validate( @_, { %std_opts } );
    my $debug = $self->set_debug( $p{debug} );
    my $fatal = $self->set_fatal( $p{fatal} );

    if ( $OSNAME eq "freebsd" ) {

        $freebsd->install_port( "p5-Params-Validate" );
        $freebsd->install_port( "p5-Net-DNS",    
            options => "#\n# This file was generated by mail-toaster
# Options for p5-Net-DNS-0.58\n_OPTIONS_READ=p5-Net-DNS-0.58\nWITHOUT_IPV6=true",
        );
    }
    elsif ( $OSNAME eq "darwin" ) {
        if ( $util->find_bin( "port" ) ) {
            my @dports = qw(
              p5-net-dns   p5-html-template   p5-compress-zlib
              p5-timedate  p5-params-validate
            );

            # p5-mail-tools
            foreach (@dports) { $darwin->install_port( $_ ); }
        }
    }
    else {
        print "no ports for $OSNAME, installing from CPAN.\n";
    }

    $util->install_module( "Params::Validate", debug => $debug );
    $util->install_module( "Compress::Zlib",   debug => $debug );
    $util->install_module( "Crypt::PasswdMD5", debug => $debug );
    $util->install_module( "Net::DNS" );
    $util->install_module( "Quota", debug => $debug, fatal => 0 ) 
        if $conf->{'install_quota_tools'};
    $util->install_module( "Date::Format", debug => $debug, port  => "p5-TimeDate",);
    $util->install_module( "Date::Parse", debug => $debug );
    $util->install_module( "Mail::Send",  debug => $debug, port  => "p5-Mail-Tools",);
}

sub cronolog {
    my $self  = shift;
    my %p = validate( @_, { %std_opts } );
    my $debug = $self->set_debug( $p{debug} );
    my $fatal = $self->set_fatal( $p{fatal} );

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    my $ver = $conf->{'install_cronolog'} or do {
        $log->audit( "cronolog: installing, skipping (disabled)" );
        return;
    };

    if ( $OSNAME eq "freebsd" && $ver eq "port" ) {
        $self->cronolog_freebsd() and return;
        $log->error( "port install of cronolog failed!", fatal => 0);
    }

    if ( $util->find_bin( "cronolog", fatal => 0 ) ) {
        $log->audit( "cronolog: install cronolog, ok (exists)" ) if $debug;
        return 2;
    }

    $log->audit( "attempting cronolog install from source");

    if ( $ver eq "port" ) { $ver = "1.6.2" };  # a fallback version

    $util->install_from_source(
        package => "cronolog-$ver",
        site    => 'http://www.cronolog.org',
        url     => '/download',
        targets => [ './configure', 'make', 'make install' ],
        bintest => 'cronolog',
        debug   => $debug,
    );

    $util->find_bin( "cronolog" ) or return;

    $log->audit( "cronolog: install cronolog, ok" );
    return 1;
}

sub cronolog_freebsd {

    if ( $freebsd->is_port_installed( "cronolog" ) ) {
        $log->audit( "install cronolog, ok (exists)" );
        return 2;
    };

    return $freebsd->install_port( "cronolog",
        fatal => 0,
        options => "#\n
# This file is generated by mail-toaster
# No user-servicable parts inside!
# Options for cronolog-1.6.2_1
_OPTIONS_READ=cronolog-1.6.2_1
WITHOUT_SETUID_PATCH=true",
    );
};

sub daemontools {
    my $self  = shift;
    my %p = validate( @_, { %std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing only
    my $debug = $self->set_debug( $p{debug} );
    my $fatal = $self->set_fatal( $p{fatal} );

    my $ver = $conf->{'install_daemontools'} or do {
        $log->audit( "daemontools: installing, (disabled)" ) if $debug;
        return;
    };

    $self->daemontools_freebsd() if $OSNAME eq "freebsd";

    if ( $OSNAME eq "darwin" && $ver eq "port" ) {
        $darwin->install_port( "daemontools" );

        print
"\a\n\nWARNING: there is a bug in the OS 10.4 kernel that requires daemontools to be built with a special tweak. This must be done once. You will be prompted to install daemontools now. If you haven't already allowed this script to build daemontools from source, please do so now!\n\n";
        sleep 2;
    }

    # see if the svscan binary is already installed
    if ( -x $util->find_bin( "svscan", fatal => 0, debug => 0 ) )
    {
        $log->audit( "daemontools: installing, ok (exists)" ) if $debug;
        return 1;
    }

    $self->daemontools_src();
};

sub daemontools_src {

    my $ver = $conf->{'install_daemontools'};
    $ver = "0.76" if $ver eq "port";

    my $package = "daemontools-$ver";
    my $prefix  = $conf->{'toaster_prefix'} || "/usr/local";

    my @targets = ('package/install');
    my @patches;
    my $patch_args = "";    # cannot be undef

    if ( $OSNAME eq "darwin" ) {
        print "daemontools: applying fixups for Darwin.\n";
        @targets = (
            "echo cc -Wl,-x > src/conf-ld",
            "echo $prefix/bin > src/home",
            "echo x >> src/trypoll.c",
            "cd src",
            "make",
        );
    }
    elsif ( $OSNAME eq "linux" ) {
        print "daemontools: applying fixups for Linux.\n";
        @patches    = ('daemontools-0.76.errno.patch');
        $patch_args = "-p0";
    }
    elsif ( $OSNAME eq "freebsd" ) {
        @targets = (
            'echo "' . $conf->{'toaster_prefix'} . '" > src/home',
            "cd src", "make",
        );
    }

    $util->install_from_source(
        package    => $package,
        site       => 'http://cr.yp.to',
        url        => '/daemontools',
        targets    => \@targets,
        patches    => \@patches,
        patch_args => $patch_args,
        patch_url  => "$conf->{'toaster_dl_site'}$conf->{'toaster_dl_url'}/patches",
        bintest    => 'svscan',
    );

    if ( $OSNAME =~ /darwin|freebsd/i ) {

        # manually install the daemontools binaries in $prefix/local/bin
        chdir "$conf->{'toaster_src_dir'}/admin/$package";

        foreach ( $util->file_read( "package/commands" ) ) {
            my $install = $util->find_bin( 'install' );
            $util->syscmd( "$install src/$_ $prefix/bin", debug=>0 );
        }
    }

    return 1;
}

sub daemontools_freebsd {

    return 1 if $freebsd->is_port_installed( "daemontools", fatal=>0 );

    $freebsd->install_port( "daemontools", 
        options => '# This file is generated by Mail Toaster
# Options for daemontools-0.76_15
_OPTIONS_READ=daemontools-0.76_15
WITH_MAN=true
WITHOUT_S_EARLY=true
WITH_S_NORMAL=true
WITHOUT_SIGQ12=true
WITH_TESTS=true',
        fatal => 0,
    ) 
    or $log->error( "port install of daemontools failed!", fatal => 0);
};

sub daemontools_test {
    my $self = shift;

    print "checking daemontools binaries...\n";
    my @bins = qw{ multilog softlimit setuidgid supervise svok svscan tai64nlocal };
    foreach my $test ( @bins ) {
        my $bin = $util->find_bin( $test, fatal => 0, debug=>0);
        $log->test("  $test", -x $bin );
    };

    return;
}

sub dependencies {
    my $self  = shift;
    my %p = validate( @_, { %std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    my $debug = $self->set_debug( $p{debug} );
    my $fatal = $self->set_fatal( $p{fatal} );
    my $qmaildir = $conf->{'qmail_dir'} || "/var/qmail";

    $self->cpan( debug => $debug ); # install the prereq perl modules

    if ( $OSNAME eq "freebsd" ) {
        $self->dependencies_freebsd();
    }
    elsif ( $OSNAME eq "darwin" ) {
        my @dports =
          qw( cronolog gdbm gmake ucspi-tcp daemontools DarwinPortsStartup );

        push @dports, qw/aspell aspell-dict-en/ if $conf->{'install_aspell'};
        push @dports, "ispell"   if $conf->{'install_ispell'};
        push @dports, "maildrop" if $conf->{'install_maildrop'};
        push @dports, "openldap" if $conf->{'install_openldap_client'};
        push @dports, "gnupg"    if $conf->{'install_gnupg'};

        foreach (@dports) { $darwin->install_port( $_ ) }
    }
    else {
        dependencies_other( $debug );
    };

    if ( ! -x "$qmaildir/bin/qmail-queue" ) {
        $conf->{'qmail_chk_usr_patch'} = 0;
        require Mail::Toaster::Qmail;
        $qmail ||= Mail::Toaster::Qmail->new();
        $qmail->netqmail_virgin();
    }

    $self->daemontools();
    $self->autorespond();
}

sub dependencies_freebsd {
    my $self = shift;
    my $package = $conf->{'package_install_method'} || "packages";

    $self->periodic_conf();    # create /etc/periodic.conf
    $self->gmake_freebsd();
    $self->openssl_install();
    $self->stunnel() if $conf->{'pop3_ssl_daemon'} eq "qpop3d";
    $self->ucspi_tcp_freebsd();
    $self->cronolog_freebsd();

    my @to_install = { port => "p5-Params-Validate"  };

    push @to_install, { port => "setquota" }  if $conf->{'install_quota_tools'};
    push @to_install, { port => "portaudit" } if $conf->{'install_portaudit'};
    push @to_install, { port => "ispell", category => 'textproc' } 
        if $conf->{'install_ispell'};
    push @to_install, { port => 'gdbm'  };
    push @to_install, { port  => "openldap23-client",
        check => "openldap-client",
        } if $conf->{'install_openldap_client'};
    push @to_install, { port  => "qmail", flags   => "BATCH=yes",
        options => "#\n# Installed by Mail::Toaster 
# Options for qmail-1.03_7\n_OPTIONS_READ=qmail-1.03_7",
    };
    push @to_install, { port => "qmailanalog", fatal => 0 };
    push @to_install, { port => "qmail-notify", fatal => 0 }
        if $conf->{'install_qmail_notify'};

    # if package method is selected, try it
    if ( $package eq "packages" ) {
        foreach ( @to_install ) {
            my $port = $_->{port} || $_->{name};
            $freebsd->package_install( port => $port, fatal => 0 );
        };
    }

    foreach my $port (@to_install) {

        $freebsd->install_port( $port->{'port'},
            flags   => defined $port->{'flags'}  ? $port->{'flags'} : q{},
            options => defined $port->{'options'}? $port->{'options'}: q{},
            check   => defined $port->{'check'}  ? $port->{'check'}  : q{},
            fatal   => defined $port->{'fatal'}  ? $port->{'fatal'} : 1,
            category=> $port->{category},
        );
    }
};

sub dependencies_other {
    my $debug = shift;
    print "no ports for $OSNAME, installing from sources.\n";

    if ( $OSNAME eq "linux" ) {
        my $vpopdir = $conf->{'vpopmail_home_dir'} || "/usr/local/vpopmail";
        $qmail ||= Mail::Toaster::Qmail->new();
        $qmail->install_qmail_groups_users();

        $util->set_debug(0);
        $util->syscmd( "groupadd -g 89 vchkpw" );
        $util->syscmd( "useradd -g vchkpw -d $vpopdir vpopmail" );
        $util->syscmd( "groupadd clamav" );
        $util->syscmd( "useradd -g clamav clamav" );
        $util->set_debug($debug);
    }

    my @progs = qw(gmake expect cronolog autorespond );
    push @progs, "setquota" if $conf->{'install_quota_tools'};
    push @progs, "ispell" if $conf->{'install_ispell'};
    push @progs, "gnupg" if $conf->{'install_gnupg'};

    foreach (@progs) {
        if ( $util->find_bin( $_, debug=>0,fatal=>0 ) ) {
            $log->audit( "checking for $_, ok" );
        }
        else {
            print "$_ not installed. FAILED, please install manually.\n";
        }
    }
}

sub djbdns {
    my $self  = shift;
    my %p = validate( @_, { %std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing only
    my $debug = $self->set_debug( $p{debug} );
    my $fatal = $self->set_fatal( $p{fatal} );

    my $tinydns;

    if ( !$conf->{'install_djbdns'} ) {
        $log->audit( "djbdns: installing, skipping (disabled)" ) if $debug;
        return 0;
    }

    $self->daemontools(  debug=>$debug );
    $self->ucspi_tcp(  debug=>$debug );

    # test to see if it is installed.
    if ( -x $util->find_bin( 'tinydns', fatal => 0, debug=>$debug ) ) {
        $log->audit( "djbdns: installing djbdns, ok (already installed)" );
        return 1;
    }

    if ( $OSNAME eq "freebsd" ) {
        $freebsd->install_port( "djbdns" );

        # test to see if it installed.
        if ( -x $util->find_bin( 'tinydns', fatal => 0, debug=>$debug ) ) {
            $log->audit( "djbdns: installing djbdns, ok" );
            return 1;
        }
    }

    my @targets = ( 'make', 'make setup check' );

    if ( $OSNAME eq "linux" ) {
        unshift @targets,
          'echo gcc -O2 -include /usr/include/errno.h > conf-cc';
    }

    $util->install_from_source(
        package => "djbdns-1.05",
        site    => 'http://cr.yp.to',
        url     => '/djbdns',
        targets => \@targets,
        bintest => 'tinydns',
        debug   => $debug,
    );
}

sub docs {

    my $cmd;
    my $debug = 1;

    if ( !-f "README" && !-f "lib/toaster.conf.pod" ) {
        print <<"EO_NOT_IN_DIST_ERR";

   ERROR: This setup target can only be run in the Mail::Toaster distibution directory!

    Try switching into there and trying again.
EO_NOT_IN_DIST_ERR

        return;
    };

    # convert pod to text files
    my $pod2text = $util->find_bin( "pod2text", debug=>0);

    $util->syscmd("$pod2text bin/toaster_setup.pl       > README", debug=>0);
    $util->syscmd("$pod2text lib/toaster.conf.pod          > doc/toaster.conf", debug=>0);
    $util->syscmd("$pod2text lib/toaster-watcher.conf.pod  > doc/toaster-watcher.conf", debug=>0);


    # convert pod docs to HTML pages for the web site

    my $pod2html = $util->find_bin("pod2html", debug=>0);

    $util->syscmd( "$pod2html --title='toaster.conf' lib/toaster.conf.pod > doc/toaster.conf.html", 
        debug=>0, );
    $util->syscmd( "$pod2html --title='watcher.conf' lib/toaster-watcher.conf.pod  > doc/toaster-watcher.conf.html", 
        debug=>0, );
    $util->syscmd( "$pod2html --title='mailadmin' bin/mailadmin > doc/mailadmin.html", 
        debug=>0, );

    my @modules = qw/ Toaster   Apache  CGI     Darwin   DNS 
            Ezmlm     FreeBSD   Logs    Mysql   Perl 
            Qmail     Setup   Utility /;

    MODULE:
    foreach my $module (@modules ) {
        if ( $module =~ m/\AToaster\z/ ) {
            $cmd = "$pod2html --title='Mail::Toaster' lib/Mail/$module.pm > doc/modules/$module.html";
            print "$cmd\n" if $debug;
            next MODULE;
            $util->syscmd( $cmd, debug=>0 );
        };

        $cmd = "$pod2html --title='Mail::Toaster::$module' lib/Mail/Toaster/$module.pm > doc/modules/$module.html";
        warn "$cmd\n" if $debug;
        $util->syscmd( $cmd, debug=>0 );
    };

    unlink <pod2htm*>;
    #$util->syscmd( "rm pod2html*");
};

sub domainkeys {

    my $self  = shift;
    my %p = validate( @_, { %std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    my $debug = $self->set_debug( $p{debug} );

    if ( !$conf->{'qmail_domainkeys'} ) {
        $log->audit( "domainkeys: installing, skipping (disabled)" )
          if $debug;
        return 0;
    }

    # test to see if it is installed.
    if ( -f "/usr/local/include/domainkeys.h" ) {
        $log->audit( "domainkeys: installing domainkeys, ok (already installed)" );
        return 1;
    }

    if ( $OSNAME eq "freebsd" ) {
        $freebsd->install_port( "libdomainkeys" );

        # test to see if it installed.
        if ( -f "/usr/local/include/domainkeys.h" ) {
            $log->audit( "domainkeys: installing domainkeys, ok (already installed)" );
            return 1;
        }
    }

    my @targets = ( 'make', 'make setup check' );

    if ( $OSNAME eq "linux" ) {
        unshift @targets,
          'echo gcc -O2 -include /usr/include/errno.h > conf-cc';
    }

    $util->install_from_source(
        package => "libdomainkeys-0.68",
        site    => 'http://superb-east.dl.sourceforge.net',
        url     => '/sourceforge/domainkeys',
        targets => \@targets,
        debug   => $debug,
    );
}

sub dovecot {

    my $self  = shift;
    my %p = validate( @_, { %std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    my $debug = $self->set_debug( $p{debug} );
    my $fatal = $self->set_fatal( $p{fatal} );

    my $ver = $conf->{'install_dovecot'} or do {
        $log->audit( "dovecot install not selected.");
        return;
    };

    if ( $ver eq "port" || $ver eq "1" ) {

        if ( $util->find_bin( "dovecot", fatal => 0 ) ) {
            print "dovecot: is already installed...done.\n\n";
            return $self->dovecot_start();
        }

    print "dovecot: installing...\n";

        if ( $OSNAME eq "freebsd" ) {
            $self->dovecot_install_freebsd() or return;
            return $self->dovecot_start();
        }
        elsif ( $OSNAME eq "darwin" ) {
            return 1 if $darwin->install_port( "dovecot" );
        }

        if ( $util->find_bin( "dovecot", fatal => 0 ) ) {
            print "dovecot: install successful.\n";
            return $self->dovecot_start();
        }

        $ver = "1.0.7";
    }

    my $dovecot = $util->find_bin( "dovecot", fatal => 0 );
    if ( -x $dovecot ) {
        my $installed = `$dovecot --version`;

        if ( $ver eq $installed ) {
            print
              "dovecot: the selected version ($ver) is already installed!\n";
            $self->dovecot_start();
            return 1;
        }
    }

    $util->install_from_source(
        package        => "dovecot-$ver",
        site           => 'http://www.dovecot.org',
        url            => '/releases',
        targets        => [ './configure', 'make', 'make install' ],
        bintest        => 'dovecot',
        debug          => 1,
        source_sub_dir => 'mail',
    );

    $self->dovecot_start();
}

sub dovecot_conf {
    my $self = shift;
    my $dconf = '/usr/local/etc/dovecot.conf';
    if ( ! -f $dconf ) {
        foreach ( qw{ /opt/local/etc /etc } ) {
            $dconf = "$_/dovecot.conf";
            last if -e $dconf;
        };
        return $log->error( "could not locate dovecot.conf. Toaster modifications not applied.");
    };

    my $updated = `grep 'Mail Toaster' $dconf`;
    if ( $updated ) {
        $log->audit( "Toaster modifications detected, skipping config" );
        return 1;
    };

    $self->config_apply_tweaks(
        file => $dconf,
        changes => [
            {   search  => "protocols = imap pop3 imaps pop3s managesieve",
                replace => "protocols = imap pop3 imaps pop3s",
            },
            {   search  => "protocol pop3 {",
                search2 => "section",
                replace => "protocol pop3 {
  pop3_uidl_format = %08Xu%08Xv
  mail_plugins = quota
  pop3_client_workarounds = outlook-no-nuls oe-ns-eoh
}",
            },
            {   search  => "protocol managesieve {",
                search2 => "section",
                replace => " ",
            },
            {   search  => "#shutdown_clients = yes",
                replace => "#shutdown_clients = yes\nshutdown_clients = no",
            },
            {   search  => "#ssl_cert_file = /etc/ssl/certs/dovecot.pem",
                replace => "#ssl_cert_file = /etc/ssl/certs/dovecot.pem
ssl_cert_file = /var/qmail/control/servercert.pem",
            },
            {   search  => "#ssl_key_file = /etc/ssl/private/dovecot.pem",
                replace => "#ssl_key_file = /etc/ssl/private/dovecot.pem
ssl_key_file = /var/qmail/control/servercert.pem",
            },
            {   search  => "#login_greeting = Dovecot ready.",
                replace => "#login_greeting = Dovecot ready.
login_greeting = Mail Toaster (Dovecot) ready.",
            },
            {
                search  => "mail_location = mbox:~/mail/:INBOX=/var/mail/%u",
                replace => "#mail_location = mbox:~/mail/:INBOX=/var/mail/%u
mail_location = maildir:~/Maildir",
            },
            {   search  => "first_valid_uid = 1000",
                replace => "#first_valid_uid = 1000
first_valid_uid = 89",
            },
            {   search  => "#last_valid_uid = 0",
                replace => "#last_valid_uid = 0
last_valid_uid = 89",
            },
            {   search  => "first_valid_gid = 1000",
                replace => "#first_valid_gid = 1000
first_valid_gid = 89",
            },
            {   search  => "#last_valid_gid = 0",
                replace => "#last_valid_gid = 0\nlast_valid_gid = 89",
            },
            {   search  => "  #mail_plugins = ",
                replace => "  #mail_plugins = \n  mail_plugins = quota imap_quota",
            },
            {   search  => "  sendmail_path = /usr/sbin/sendmail",
                replace => "#  sendmail_path = /usr/sbin/sendmail
  sendmail_path = /var/qmail/bin/sendmail",
            },
            {   search  => "auth_username_format = %Ln",
                replace => "#auth_username_format = %Ln
auth_username_format = %Lu",
            },
            {   search  => "  mechanisms = plain login",
                replace => "  mechanisms = plain login digest-md5 cram-md5",
            },
            {   search  => "  passdb pam {",
                search2 => "section",
                replace => " ",
            },
            {   search  => "  #passdb vpopmail {",
                replace => "  passdb vpopmail {\n  }",
            },
            {   search  => "  #userdb vpopmail {",
                replace => "  userdb vpopmail {\n  }",
            },
            {   search  => "  user = root",
                replace => "  user = vpopmail",
            },
            {   search  => "  #quota = maildir",
                replace => "  quota = maildir",
            },
        ],
    );
};

sub dovecot_install_freebsd {
    my $self = shift;

    return 1 if $freebsd->is_port_installed('dovecot');

    $log->audit( "starting port install of dovecot" );

    $freebsd->install_port( "dovecot",
        options => "
# This file is generated by Mail Toaster.
# Options for dovecot-1.2.4_1
_OPTIONS_READ=dovecot-1.2.4_1
WITH_KQUEUE=true
WITH_SSL=true
WITHOUT_IPV6=true
WITH_POP3=true
WITH_LDA=true
WITHOUT_MANAGESIEVE=true
WITHOUT_GSSAPI=true
WITH_VPOPMAIL=true
WITHOUT_BDB=true
WITHOUT_LDAP=true
WITHOUT_PGSQL=true
WITHOUT_MYSQL=true
WITHOUT_SQLITE=true
",
    ) or return;

    return if ! $freebsd->is_port_installed('dovecot');

    my $config = "/usr/local/etc/dovecot.conf";
    if ( ! -e $config ) {
        if ( -e "/usr/local/etc/dovecot-example.conf" ) {
            copy("/usr/local/etc/dovecot-example.conf", $config);
        }
        else {
            $log->error("unable to find dovecot.conf sample", fatal => 0);
            sleep 3;
            return;
        };
    };

    # append dovecot_enable to /etc/rc.conf
    $freebsd->conf_check(
        check => "dovecot_enable",
        line  => 'dovecot_enable="YES"',
    );

    return 1;
}

sub dovecot_start {

    my $self = shift;
    my $debug = $self->{'debug'};

    unless ( $OSNAME eq "freebsd" ) {
        $log->error( "sorry, no dovecot startup support yet on $OSNAME", fatal => 0);
        return;
    };

    $self->dovecot_conf() or return;

    # start dovecot
    if ( -x "/usr/local/etc/rc.d/dovecot" ) {
        $util->syscmd("/usr/local/etc/rc.d/dovecot restart", debug=>0);
    };
}

sub enable_all_spam {

    my $self  = shift;
    my $debug = $self->{'debug'};

    my $qmail_dir = $conf->{'qmail_dir'} || "/var/qmail";
    my $spam_cmd  = $conf->{'qmailadmin_spam_command'} || 
        '| /usr/local/bin/maildrop /usr/local/etc/mail/mailfilter';

    require Mail::Toaster::Qmail;
    $qmail ||= Mail::Toaster::Qmail->new();

    my @domains = $qmail->get_domains_from_assign(
            assign => "$qmail_dir/users/assign",
            debug  => $debug
        );

    my $number_of_domains = @domains;
    print "enable_all_spam: found $number_of_domains domains.\n" if $debug;

    for (my $i = 0; $i < $number_of_domains; $i++) {

        my $domain = $domains[$i]{'dom'};
        print "Enabling spam processing for $domain mailboxes...\n" if $debug;

        my @paths = `~vpopmail/bin/vuserinfo -d -D $domain`;

        PATH:
        foreach my $path (@paths) {
            chomp($path);
            if ( ! $path || ! -d $path) {
                print "$path does not exist!\n";
                next PATH;
            };

            my $qpath = "$path/.qmail";
            if (-f $qpath) {
                print ".qmail already exists in $path.\n";
                next PATH;
            };

            print ".qmail created in $path.\n";
            system "echo \"$spam_cmd \" >> $path/.qmail";

            my $uid = getpwnam("vpopmail");
            my $gid = getgrnam("vchkpw");
            chown( $uid, $gid, "$path/.qmail" );
            chmod oct('0644'), "$path/.qmail";
        }
    }

    return 1;
}

sub expat {
    my $self  = shift;
    my %p = validate( @_, { %std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    my $debug = $self->set_debug( $p{debug} );
    my $fatal = $self->set_fatal( $p{fatal} );

    if ( !$conf->{'install_expat'} ) {
        $log->audit( "expat: installing, skipping (disabled)" ) if $debug;
        return 0;
    }

    if ( $OSNAME eq "freebsd" ) {
        if ( -d "/usr/ports/textproc/expat" ) {
            $freebsd->install_port( "expat" );
        }
        else {
            $freebsd->install_port( "expat", dir  => 'expat2');
        }
    }
    elsif ( $OSNAME eq "darwin" ) {
        $darwin->install_port( "expat" );
    }
    else {
        print "Sorry, build support for expat on $OSNAME is incomplete.\n";
    }
}

sub expect {

    my $self  = shift;
    my %p = validate( @_, { %std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    my $debug = $self->set_debug( $p{debug} );
    my $fatal = $self->set_fatal( $p{fatal} );

    if ( $OSNAME eq "freebsd" ) {
        $freebsd->install_port( "expect",
            flags => "WITHOUT_X11=yes",
            fatal => $fatal,
        );
    }
}

sub ezmlm {

    my $self  = shift;
    my %p = validate( @_, { %std_opts } );

    my $debug = $self->set_debug( $p{debug} );
    my $fatal = $self->set_fatal( $p{fatal} );

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    my $ver     = $conf->{'install_ezmlm'};
    my $confdir = $conf->{'system_config_dir'} || "/usr/local/etc";

    if ( !$ver ) {
        $log->audit( "installing Ezmlm-Idx, (disabled)" ) if $debug;
        return;
    }

    my $ezmlm = $util->find_bin( 'ezmlm-sub', dir => '/usr/local/bin/ezmlm',
        debug => $debug,
        fatal => 0
    );

    # if it is already installed
    if ( $ezmlm && -x $ezmlm ) {
        $log->audit( "installing Ezmlm-Idx, ok (installed)" );
        return $self->ezmlm_cgi(  debug=>$debug );
    }

    if (   $OSNAME eq "freebsd"
        && $ver eq "port"
        && !$freebsd->is_port_installed( "ezmlm", debug=>$debug, fatal=>0 ) )
    {
        $self->ezmlm_makefile_fixup( );

        my $defs = "";
        my $opts = "WITHOUT_MYSQL=true";
        if ( $conf->{'install_ezmlm_mysql'} ) {
            $defs .= "WITH_MYSQL=yes";
            $opts = "WITH_MYSQL=true";
        };

        if ( $freebsd->install_port( "ezmlm-idx",
                options => "# This file was generated by mail-toaster
# No user-servicable parts inside!
# Options for ezmlm-idx-0.444
_OPTIONS_READ=ezmlm-idx-0.444
$opts
WITHOUT_PGSQL=true",
                flags   => $defs,
            )
          )
        {
            chdir("$confdir/ezmlm");
            copy( "ezmlmglrc.sample", "ezmlmglrc" )
              or $util->error( "copy ezmlmglrc failed: $!");

            copy( "ezmlmrc.sample", "ezmlmrc" )
              or $util->error( "copy ezmlmrc failed: $!");

            copy( "ezmlmsubrc.sample", "ezmlmsubrc" )
              or $util->error( "copy ezmlmsubrc failed: $!");

            return $self->ezmlm_cgi(  debug=>$debug );
        }

        print "\n\nFAILURE: ezmlm-idx install failed!\n\n";
        return;
    }

    print "ezmlm: attemping to install ezmlm from sources.\n";

    my $ezmlm_dist = "ezmlm-0.53";
    my $idx     = "ezmlm-idx-$ver";
    my $site    = "http://www.ezmlm.org";
    my $src     = $conf->{'toaster_src_dir'} || "/usr/local/src/mail";
    my $httpdir = $conf->{'toaster_http_base'} || "/usr/local/www";
    my $cgi     = $conf->{'qmailadmin_cgi-bin_dir'};

    $cgi = -d $cgi ? $cgi : $toaster->get_toaster_cgibin();

    # figure out where to install the CGI

    $util->cwd_source_dir( "$src/mail" );

    if ( -d $ezmlm_dist ) {
        unless (
            $util->source_warning( package => $ezmlm_dist, src => "$src/mail" ) )
        {
            carp "\nezmlm: OK then, skipping install.\n";
            return 0;
        }
        else {
            print "ezmlm: removing any previous build sources.\n";
            $util->syscmd( "rm -rf $ezmlm_dist" );
        }
    }

    unless ( -e "$ezmlm_dist.tar.gz" ) {
        $util->get_url( "$site/archive/$ezmlm_dist.tar.gz" );
    }

    unless ( -e "$idx.tar.gz" ) {
        $util->get_url( "$site/archive/$ver/$idx.tar.gz" );
    }

    $util->extract_archive( "$ezmlm_dist.tar.gz" )
      or croak "Couldn't expand $ezmlm_dist.tar.gz: $!\n";

    $util->extract_archive( "$idx.tar.gz" )
      or croak "Couldn't expand $idx.tar.gz: $!\n";

    $util->syscmd( "mv $idx/* $ezmlm_dist/", debug=>$debug );
    $util->syscmd( "rm -rf $idx", debug=>$debug );

    chdir($ezmlm_dist);

    $util->syscmd( "patch < idx.patch", debug=>$debug );

    if ( $OSNAME eq "darwin" ) {
        my $local_include = "/usr/local/mysql/include";
        my $local_lib     = "/usr/local/mysql/lib";

        if ( !-d $local_include ) {
            $local_include = "/opt/local/include/mysql";
            $local_lib     = "/opt/local/lib/mysql";
        }

        $util->file_write( "sub_mysql/conf-sqlcc",
            lines => ["-I$local_include"],
            debug => $debug,
        );

        $util->file_write( "sub_mysql/conf-sqlld",
            lines => ["-L$local_lib -lmysqlclient -lm"],
            debug => $debug,
        );
    }
    elsif ( $OSNAME eq "freebsd" ) {
        $util->file_write( "sub_mysql/conf-sqlcc",
            lines => ["-I/usr/local/include/mysql"],
            debug => $debug,
        );

        $util->file_write( "sub_mysql/conf-sqlld",
            lines => ["-L/usr/local/lib/mysql -lmysqlclient -lnsl -lm"],
            debug => $debug,
        );
    }

    $util->file_write( "conf-bin", lines => ["/usr/local/bin"], debug=>$debug );
    $util->file_write( "conf-man", lines => ["/usr/local/man"], debug=>$debug );
    $util->file_write( "conf-etc", lines => ["/usr/local/etc"], debug=>$debug );

    $util->syscmd( "make", debug=>$debug );
    $util->syscmd( "chmod 775 makelang", debug=>$debug );

#$util->syscmd( "make mysql" );  # haven't figured this out yet (compile problems)
    $util->syscmd( "make man", debug=>$debug );
    $util->syscmd( "make setup", debug=>$debug );

    $self->ezmlm_cgi(  debug=>$debug );
    return 1;
}

sub ezmlm_cgi {

    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => $debug },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
       $debug = $p{'debug'};

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    return unless ( $conf->{'install_ezmlm_cgi'} );

    if ( $OSNAME eq "freebsd" ) {
        $freebsd->install_port( "p5-Archive-Tar", 
            options=>"#
# This file was generated by Mail::Toaster
# No user-servicable parts inside!
# Options for p5-Archive-Tar-1.30
_OPTIONS_READ=p5-Archive-Tar-1.30
WITHOUT_TEXT_DIFF=true", 
        );
    }

    $util->install_module( "Email::Valid", debug => 0,);
    $util->install_module( "Mail::Ezmlm", debug => 0,);

    return 1;
}

sub ezmlm_makefile_fixup {

    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => $debug },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
       $debug = $p{'debug'};

    my $file = "/usr/ports/mail/ezmlm-idx/Makefile";

    # fix a problem in the ports Makefile (no longer necessary as of 7/21/06)
    my $mysql = $conf->{'install_ezmlm_mysql'};

    return 1 if ( $mysql == 323 || $mysql == 3 );
    return 1 if ( ! `grep mysql323 $file`);

    my @lines = $util->file_read( $file, debug=>0 );
    foreach (@lines) {
        if ( $_ =~ /^LIB_DEPENDS\+\=\s+mysqlclient.10/ ) {
            $_ = "LIB_DEPENDS+=  mysqlclient.12:\${PORTSDIR}/databases/mysql40-client";
        }
    }
    $util->file_write( $file, lines => \@lines, debug=>0 );
}

sub filtering {

    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => $debug },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
       $debug = $p{'debug'};

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    if ( $OSNAME eq "freebsd" ) {

        $self->maildrop(debug=>$debug) if ( $conf->{'install_maildrop'} );

        $freebsd->install_port( "p5-Archive-Tar", 
			options=> "# This file was generated by mail-toaster
# No user-servicable parts inside!
# Options for p5-Archive-Tar-1.30
_OPTIONS_READ=p5-Archive-Tar-1.30
WITHOUT_TEXT_DIFF=true",
        );

        $freebsd->install_port( "p5-Mail-Audit" );
        $freebsd->install_port( "unzip" );

        $self->razor(  debug=>$debug );

        $freebsd->install_port( "pyzor" ) if $conf->{'install_pyzor'};
        $freebsd->install_port( "bogofilter" ) if $conf->{'install_bogofilter'};
        $freebsd->install_port( "dcc-dccd", flags => "WITHOUT_SENDMAIL=yes", ) if $conf->{'install_dcc'};

        $freebsd->install_port( "procmail" ) if $conf->{'install_procmail'};
        $freebsd->install_port( "p5-Email-Valid" );
    }

    $self->spamassassin ( debug=>$debug );
    $self->razor        ( debug=>$debug );
    $self->clamav       ( debug=>$debug );
    $self->simscan      ( debug=>$debug );
}

sub filtering_test {
    my $self  = shift;
    my %p = validate( @_, { %std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    $self->simscan_test( );

    print "\n\nFor more ways to test your Virus scanner, go here: 
\n\t http://www.testvirus.org/\n\n";
}

sub gmake_freebsd {

# iconv to suppress a prompt, and because gettext requires it
    $freebsd->install_port( 'libiconv',
        options => "#\n# This file was generated by mail-toaster
# Options for libiconv-1.13.1_1
_OPTIONS_READ=libiconv-1.13.1_1
WITH_EXTRA_ENCODINGS=true
WITHOUT_EXTRA_PATCHES=true\n",
    );

# required by gmake
    $freebsd->install_port( "gettext",
        options => "#\n# This file was generated by mail-toaster
# Options for gettext-0.14.5_2
_OPTIONS_READ=gettext-0.14.5_2\n",
    );

    $freebsd->install_port( 'gmake' );
};

sub gnupg_install {
    my $self = shift;
    return if ! $conf->{'install_gnupg'};

    if ( $conf->{package_install_method} eq 'packages' ) {
        $freebsd->package_install( port => "gnupg", debug=>0, fatal => 0 );
        return 1 if $freebsd->is_port_installed('gnupg');
    };

    $freebsd->install_port( "gnupg", 
        debug   => 0,
        options => "# This file was generated by mail-toaster
# No user-servicable parts inside!
# Options for gnupg-1.4.5
_OPTIONS_READ=gnupg-1.4.5
WITHOUT_LDAP=true
WITHOUT_LIBICONV=true
WITHOUT_LIBUSB=true
WITHOUT_SUID_GPG=true
WITH_NLS=true",
    );
};

sub group_add {
    my $self = shift;
    my ($group, $gid) = @_;
    return if ! $group;
    return if $self->group_exists($group);
    my $cmd;
    if ( $OSNAME eq 'linux' ) {
        $cmd = $util->find_bin('groupadd');
        $cmd .= " -g $gid" if $gid;    
        $cmd .= " $group";
    }
    elsif ( $OSNAME eq 'freebsd' ) {
        $cmd = $util->find_bin( 'pw' );
        $cmd .= " groupadd -n $group";
        $cmd .= " -g $gid" if $gid;
    }
    elsif ( $OSNAME eq 'darwin' ) {
        $cmd = $util->find_bin( "dscl", fatal => 0 );
        my $path = "/groups/$group";
        if ($cmd) {    # use dscl 10.5+
            $util->syscmd( "$cmd . -create $path" );
            $util->syscmd( "$cmd . -createprop $path gid $gid") if $gid;
            $util->syscmd( "$cmd . -createprop $path passwd '*'" );
        }
        else {
            $cmd = $util->find_bin( "niutil", fatal => 0 );
            $util->syscmd( "$cmd -create . $path" );
            $util->syscmd( "$cmd -createprop . $path gid $gid") if $gid;
            $util->syscmd( "$cmd -createprop . $path passwd '*'" );
        }
        return 1;
    }
    else {
        warn "unable to create users on OS $OSNAME\n";
        return;
    };
    return $util->syscmd( $cmd );
};

sub group_exists {
    my $self = shift; 
    my $group = lc(shift) or die "missing group";
    my $gid = getgrnam($group);
    return ( $gid && $gid > 0 ) ? $gid : undef;
};  

sub imap_test_auth {

    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => $debug },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
       $debug = $p{'debug'};

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    $self->imap_test_auth_nossl( $debug );
    $self->imap_test_auth_ssl( $debug );
};

sub imap_test_auth_nossl {
    my $self = shift;
    my $debug = shift;

    my $r = $util->install_module("Mail::IMAPClient", debug => 0);
    $log->test("checking Mail::IMAPClient", $r );
    if ( ! $r ) {
        print "skipping imap test authentications\n";
        return;
    };

    # an authentication that should succeed
    my $imap = Mail::IMAPClient->new(
        User     => $conf->{'toaster_test_email'} || 'test2@example.com',
        Password => $conf->{'toaster_test_email_pass'} || 'cHanGeMe',
        Server   => 'localhost',
    );
    if ( !defined $imap ) {
        $log->test( "imap connection", $imap );
        return;
    };

    $log->test( "authenticate IMAP user with plain passwords", 
        $imap->IsAuthenticated() );

    my @features = $imap->capability
        or warn "Couldn't determine capability: $@\n";
    print "Your IMAP server supports: " . join( ',', @features ) . "\n\n"
        if $debug;
    $imap->logout;

    print "an authentication that should fail\n";
    $imap = Mail::IMAPClient->new(
        Server => 'localhost',
        User   => 'no_such_user',
        Pass   => 'hi_there_log_watcher'
    )
    or do {
        $log->test( "imap connection that should fail", 0);
        return 1;
    };
    $log->test( "  imap connection", $imap->IsConnected() );
    $log->test( "  test auth that should fail", !$imap->IsAuthenticated() );
    $imap->logout;
    return;
};

sub imap_test_auth_ssl {
    my ($self, $debug) = @_;

    my $user = $conf->{'toaster_test_email'}      || 'test2@example.com';
    my $pass = $conf->{'toaster_test_email_pass'} || 'cHanGeMe';

    my $r = $util->install_module( "IO::Socket::SSL", debug => 0,);
    $log->test( "checking IO::Socket::SSL ", $r);
    if ( ! $r ) {
        print "skipping IMAP SSL tests due to missing SSL support\n";
        return;
    };

    require IO::Socket::SSL;
    my $socket = IO::Socket::SSL->new(
        PeerAddr => 'localhost',
        PeerPort => 993,
        Proto    => 'tcp'
    );
    $log->test( "  imap SSL connection", $socket);
    return if ! $socket;
    
    print "  connected with " . $socket->get_cipher() . "\n";
    print $socket ". login $user $pass\n";
    ($r) = $socket->peek =~ /OK/i;
    $log->test( "  auth IMAP SSL with plain password", $r ? 0 : 1);
    print $socket ". logout\n";
    close $socket;

#  no idea why this doesn't work, so I just forge an authentication by printing directly to the socket
#	my $imapssl = Mail::IMAPClient->new( Socket=>$socket, User=>$user, Password=>$pass) or warn "new IMAP failed: ($@)\n";
#	$imapssl->IsAuthenticated() ? print "ok\n" : print "FAILED.\n";

# doesn't work yet because courier doesn't support CRAM-MD5 via the vchkpw auth module
#	print "authenticating IMAP user with CRAM-MD5...";
#	$imap->connect;
#	$imap->authenticate();
#	$imap->IsAuthenticated() ? print "ok\n" : print "FAILED.\n";
#
#	print "logging out...";
#	$imap->logout;
#	$imap->IsAuthenticated() ? print "FAILED.\n" : print "ok.\n";
#	$imap->IsConnected() ? print "connection open.\n" : print "connection closed.\n";

}

sub is_newer {

    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'min'   => { type => SCALAR },
            'cur'   => { type => SCALAR },
            'debug' => { type => SCALAR, optional => 1, default => $debug },
        },
    );

    my ( $min, $cur ) = ( $p{'min'}, $p{'cur'} );

    $debug = $p{'debug'};

    my @mins = split( q{\.}, $min );
    my @curs = split( q{\.}, $cur );

    #use Data::Dumper;
    #print Dumper(@mins, @curs);

    if ( $curs[0] > $mins[0] ) { return 1; }    # major version num
    if ( $curs[1] > $mins[1] ) { return 1; }    # minor version num
    if ( $curs[2] && $mins[2] && $curs[2] > $mins[2] ) { return 1; }    # revision level
    if ( $curs[3] && $mins[3] && $curs[3] > $mins[3] ) { return 1; }    # just in case

    return 0;
}

sub isoqlog {
    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
       $debug = $p{'debug'};

    my $ver = $conf->{'install_isoqlog'}
        or return $log->error( "isoqlog: skipping b/c install_isoqlog is disabled",fatal=>0 );

    my $return = 0;

    if ( $ver eq "port" ) {
        if ( $OSNAME eq "freebsd" ) {
            if ( $freebsd->is_port_installed( "isoqlog", debug=>$debug ) ) {
                $log->audit( "isoqlog: installing, ok (exists)" );
                $return = 2;
            }
            else {
                $freebsd->install_port( "isoqlog" );
                if ( $freebsd->is_port_installed( "isoqlog", debug=>$debug ) ) {
                    $log->audit( "isoqlog: installing, ok" );
                    $return = 1;
                }
            }
        }
        else {
            $log->audit(
                "isoqlog: install_isoqlog = port is not valid for $OSNAME!, FAILED" );
            return 0;
        }
    }
    else {
        if ( -x $util->find_bin( "isoqlog", fatal => 0, debug=>$debug ) ) {
            $log->audit( "isoqlog: installing., ok (exists)" );
            $return = 2;
        }
    }

    return $return if $util->find_bin( "isoqlog", fatal => 0, debug=>$debug );

    $log->audit( "isoqlog not found. Trying to install v$ver from sources for $OSNAME!");

    $ver = 2.2 if ( $ver eq "port" || $ver == 1 );

    my $configure = "./configure ";

    if ( $conf->{'toaster_prefix'} ) {
        $configure .= "--prefix=" . $conf->{'toaster_prefix'} . " ";
        $configure .= "--exec-prefix=" . $conf->{'toaster_prefix'} . " ";
    }

    if ( $conf->{'system_config_dir'} ) {
        $configure .= "--sysconfdir=" . $conf->{'system_config_dir'} . " ";
    }

    $log->audit( "isoqlog: building with $configure" );

    $util->install_from_source(
        package => "isoqlog-$ver",
        site    => 'http://www.enderunix.org',
        url     => '/isoqlog',
        targets => [ $configure, 'make', 'make install', 'make clean' ],
        bintest => 'isoqlog',
        debug   => $debug,
        source_sub_dir => 'mail',
    );

    if ( $conf->{'toaster_prefix'} ne "/usr/local" ) {
        symlink( "/usr/local/share/isoqlog",
            $conf->{'toaster_prefix'} . "/share/isoqlog" );
    }

    if ( $util->find_bin( "isoqlog", fatal => 0, debug=>$debug ) ) {
        $self->isoqlog_conf( debug=>$debug );
        return 1;
    };

    return;
}

sub isoqlog_conf {

    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => $debug },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
       $debug = $p{'debug'};

    # isoqlog doesn't honor --sysconfdir yet
    #my $etc = $conf->{'system_config_dir'} || "/usr/local/etc";
    my $etc  = "/usr/local/etc";
    my $file = "$etc/isoqlog.conf";

    if ( -e $file ) {
        $log->audit( "isoqlog_conf: creating $file, ok (exists)" );
        return 2;
    }

    my @lines;

    my $htdocs = $conf->{'toaster_http_docs'} || "/usr/local/www/data";
    my $hostn  = $conf->{'toaster_hostname'}  || hostname;
    my $logdir = $conf->{'qmail_log_base'}    || "/var/log/mail";
    my $qmaild = $conf->{'qmail_dir'}         || "/var/qmail";
    my $prefix = $conf->{'toaster_prefix'}    || "/usr/local";

    push @lines, <<EO_ISOQLOG;
#isoqlog Configuration file

logtype     = "qmail-multilog"
logstore    = "$logdir/send"
domainsfile = "$qmaild/control/rcpthosts"
outputdir   = "$htdocs/isoqlog"
htmldir     = "$prefix/share/isoqlog/htmltemp"
langfile    = "$prefix/share/isoqlog/lang/english"
hostname    = "$hostn"

maxsender   = 100
maxreceiver = 100
maxtotal    = 100
maxbyte     = 100
EO_ISOQLOG

    $util->file_write( $file, lines => \@lines, debug=>$debug )
      or croak "couldn't write $file: $!\n";
    $log->audit( "isoqlog_conf: creating $file, ok" );

    $util->syscmd( "isoqlog", fatal => 0, debug => $debug,);

    unless ( -e "$htdocs/isoqlog" ) {
        mkdir oct('0755'), "$htdocs/isoqlog";
    }

    # what follows is one way to fix the missing images problem. The better
    # way is with an apache alias directive such as:
    # Alias /isoqlog/images/ "/usr/local/share/isoqlog/htmltemp/images/"
    # that is now included in the Apache 2.0 patch

    unless ( -e "$htdocs/isoqlog/images" ) {
        $util->syscmd( "cp -r /usr/local/share/isoqlog/htmltemp/images $htdocs/isoqlog/images",
            debug=>$debug,
        );
    }
}

sub lighttpd {
    my $self = shift;

    if ( $OSNAME eq 'freebsd' ) {
        $self->lighttpd_freebsd();
    }
    else {
        $util->find_bin( 'lighttpd', fatal=>0) 
            or return $log->error("no support for install lighttpd on $OSNAME. Report this error to support\@tnpi.net");
    };

    $self->lighttpd_config();
};

sub lighttpd_freebsd {
    my $self = shift;

    $freebsd->install_port( "lighttpd",
        options => "#\n# This file was generated by mail-toaster
# Options for lighttpd-1.4.26_3
_OPTIONS_READ=lighttpd-1.4.26_3
WITH_BZIP2=true
WITHOUT_CML=true
WITHOUT_FAM=true
WITHOUT_GDBM=true
WITHOUT_H264=true
WITHOUT_IPV6=true
WITHOUT_MAGNET=true
WITHOUT_MEMCACHE=true
WITHOUT_MYSQL=true
WITHOUT_NODELAY=true
WITHOUT_OPENLDAP=true
WITH_OPENSSL=true
WITH_SPAWNFCGI=true
WITHOUT_VALGRIND=true
WITHOUT_WEBDAV=true\n",
    );

    $freebsd->conf_check(
        check => "lighttpd_enable",
        line  => 'lighttpd_enable="YES"',
    );

    my @logs = qw/ lighttpd.error.log lighttpd.access.log /;
    foreach ( @logs ) {
        $util->file_write( "/var/log/$_",
            lines => [''],
        ) 
        if ! -e "/var/log/$_";
        my (undef,undef,$uid,$gid) = getpwnam('www');
        chown( $uid, $gid, "/var/log/$_");
    };

    system "/usr/local/etc/rc.d/lighttpd restart";
};

sub lighttpd_config {
    my $self = shift;

    my $conf = '/usr/local/etc/lighttpd.conf';

    `grep toaster $conf` 
        and return $log->audit("lighttpd configuration already done");

    $self->config_apply_tweaks(
        file    => $conf,
        changes => [
            {   search  => q{#                               "mod_alias",},
                replace => q{                                "mod_alias",},
            },
            {   search  => q{#                               "mod_auth",},
                replace => q{                                "mod_auth",},
            },
            {   search  => q{#                               "mod_setenv",},
                replace => q{                                "mod_setenv",},
            },
            {   search  => q{#                               "mod_fastcgi",},
                replace => q{                                "mod_fastcgi",},
            },
            {   search  => q{#                               "mod_cgi",},
                replace => q{                                "mod_cgi",},
            },
            {   search  => q{#                               "mod_compress",},
                replace => q{                                "mod_compress",},
            },
            {   search  => q{server.document-root        = "/usr/local/www/data/"},
                replace => q{server.document-root        = "/usr/local/www/toaster/"},
            },
            {   search  => q{#include /etc/lighttpd/lighttpd-inc.conf},
                replace => q{include "/usr/local/etc/lighttpd-inc.conf"},
            },
        ],
    );

    my $include = <<'EO_LIGHTTPD_INCLUDE'
# avoid upload hang: http://redmine.lighttpd.net/boards/2/topics/show/141
server.network-backend = "writev",

alias.url = (  "/cgi-bin/"       => "/usr/local/www/cgi-bin/",
               "/squirrelmail/"  => "/usr/local/www/squirrelmail/",
               "/sqwebmail/"     => "/usr/local/www/toaster/sqwebmail/",
               "/roundcube/"     => "/usr/local/www/roundcube/",
               "/v-webmail/"     => "/usr/local/www/v-webmail/htdocs/",
               "/isoqlog/images/"=> "/usr/local/share/isoqlog/htmltemp/images/",
               "/phpMyAdmin/"    => "/usr/local/www/phpMyAdmin/",
               "/rrdutil/"       => "/usr/local/rrdutil/html/",
               "/munin/"         => "/usr/local/www/munin/",
               "/awstatsclasses" => "/usr/local/www/awstats/classes/",
               "/awstatscss"     => "/usr/local/www/awstats/css/",
               "/awstatsicons"   => "/usr/local/www/awstats/icons/",
               "/awstats/"       => "/usr/local/www/awstats/cgi-bin/",
            )

$HTTP["url"] =~ "^/awstats/" {
    cgi.assign = ( "" => "/usr/bin/perl" )
}

$HTTP["url"] =~ "^/cgi-bin" {
     cgi.assign = ( "" => "" )
}

$SERVER["socket"] == ":443" {
   ssl.engine   = "enable"
   ssl.pemfile = "/usr/local/openssl/certs/server.pem"
# sqwebmail needs this
   setenv.add-environment = ( "HTTPS" => "on" )
}
    
fastcgi.server = ( 
                    ".php" =>
                       ( "localhost" =>
                         (
                           "socket"       => "/tmp/php-fastcgi.socket",
                           "bin-path"     => "/usr/local/bin/php-cgi",
                           "idle-timeout" => 1200,
                           "min-procs"    => 1,
                           "max-procs"    => 3,
                           "bin-environment" => (
                                "PHP_FCGI_CHILDREN"     => "2",
                                "PHP_FCGI_MAX_REQUESTS" => "100"
                           ),
                         )
                       )
                  )

auth.backend               = "htdigest"
auth.backend.htdigest.userfile = "/usr/local/etc/lighttpd.passwd"

auth.require      = ( "/isoqlog" =>
                       (
                          "method"  => "digest",
                          "realm"   => "isoqlog",
                          "require" => "user=matt"
                        ),
                    )
EO_LIGHTTPD_INCLUDE
;

    $util->file_write('/usr/local/etc/lighttpd-inc.conf',
        lines => [ $include ],
    );
    
};

sub logmonster {

    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'fatal'   => { type => BOOLEAN, optional => 1, default => 1 },
            'debug'   => { type => BOOLEAN, optional => 1, default => $debug },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
       $debug = $p{'debug'};

    my $perlbin = $util->find_bin( "perl", debug => $debug );

    my @targets = ( "$perlbin Makefile.PL", "make", "make install" );
    push @targets, "make test" if $debug;

    $util->install_module_from_src( 'Apache-Logmonster',
        site    => 'http://www.tnpi.net',
        archive => 'Apache-Logmonster',
        url     => '/internet/www/logmonster',
        targets => \@targets,
        debug   => $debug,
    );
}

sub maildrop {

    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'fatal'   => { type => BOOLEAN, optional => 1, default => 1 },
            'debug'   => { type => BOOLEAN, optional => 1, default => $debug },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
       $debug = $p{'debug'};

    my $ver = $conf->{'install_maildrop'};

    unless ($ver) {
        print "skipping maildrop install because it's not enabled!\n";
        return 0;
    }

    my $prefix = $conf->{'toaster_prefix'} || "/usr/local";

    if ( $ver eq "port" || $ver eq "1" ) {
        if ( $OSNAME eq "freebsd" ) {
            $freebsd->install_port( "maildrop", flags => "WITH_MAILDIRQUOTA=1",);
        }
        elsif ( $OSNAME eq "darwin" ) {
            $darwin->install_port( "maildrop" );
        }
        $ver = "2.0.2";
    }

    if ( !-x $util->find_bin( "maildrop", fatal => 0, debug=>$debug ) ) {

        $util->install_from_source(
            package => 'maildrop-' . $ver,
            site    => 'http://' . $conf->{'toaster_sf_mirror'},
            url     => '/courier',
            targets => [
                './configure --prefix=' . $prefix . ' --exec-prefix=' . $prefix,
                'make',
                'make install-strip',
                'make install-man'
            ],
            source_sub_dir => 'mail',
            debug   => $debug,
        );
    }

    # make sure vpopmail user is set up (owner of mailfilter file)
    my $uid = getpwnam("vpopmail");
    my $gid = getgrnam("vchkpw");

    croak "maildrop: didn't get uid or gid for vpopmail:vchkpw!"
      unless ( $uid && $gid );

    my $etcmail = "$prefix/etc/mail";
    unless ( -d $etcmail ) {
        mkdir( $etcmail, oct('0755') )
          or $util->mkdir_system( dir => $etcmail, mode=>'0755', debug=>$debug );
    }

    $self->maildrop_filter();

    my $sub_file = "$prefix/sbin/subscribeIMAP.sh";

    my $sub_bin = $util->find_bin( "$prefix/sbin/subscribeIMAP.sh", debug => 0, fatal => 0 );
    unless ( $sub_bin && -e $sub_bin ) {

        my $chown = $util->find_bin( 'chown' );
        my $chmod = $util->find_bin( 'chmod' );

        my @lines;
        push @lines, '#!/bin/sh
#
# This subscribes the folder passed as $1 to courier imap
# so that Maildir reading apps (Sqwebmail, Courier-IMAP) and
# IMAP clients (squirrelmail, Mailman, etc) will recognize the
# extra mail folder.

# Matt Simerson - 12 June 2003

LIST="$2/Maildir/courierimapsubscribed"

if [ -f "$LIST" ]; then
	# if the file exists, check it for the new folder
	TEST=`cat "$LIST" | grep "INBOX.$1"`

	# if it is not there, add it
	if [ "$TEST" = "" ]; then
		echo "INBOX.$1" >> $LIST
	fi
else
	# the file does not exist so we define the full list
	# and then create the file.
	FULL="INBOX\nINBOX.Sent\nINBOX.Trash\nINBOX.Drafts\nINBOX.$1"

	echo -e $FULL > $LIST
	' . $chown . ' vpopmail:vchkpw $LIST
	' . $chmod . ' 644 $LIST
fi
';

        $util->file_write( $sub_file, lines => \@lines, debug=>$debug )
          or croak "maildrop: FAILED: couldn't write $sub_file: $!\n";

        $util->chmod(
            file_or_dir => $sub_file,
            mode        => '0555',
            sudo        => $UID == 0 ? 0 : 1,
            debug       => $debug,
        );
    }

    my $log = $conf->{'qmail_log_base'} || "/var/log/mail";

    unless ( -d $log ) {

        $util->mkdir_system( dir => $log, debug => 0 );

        # set its ownership to be that of the qmail log user
        $util->chown( $log,
            uid   => $conf->{'qmail_log_user'},
            gid   => $conf->{'qmail_log_group'},
            sudo  => $UID == 0 ? 0 : 1,
        );
    }

    my $logf = "$log/maildrop.log";

    unless ( -e $logf ) {

        $util->file_write( $logf, lines => ["begin"], debug=>$debug );

        # set the ownership of the maildrop log to the vpopmail user
        $util->chown( $logf,
            uid   => $uid,
            gid   => $gid,
            sudo  => 1,
            debug => $debug,
        );

        #chown($uid, $gid, $logf) or croak "maildrop: chown $logf failed!";
    }
}

sub maildrop_filter {

    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => $debug },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
       $debug = $p{'debug'};

    warn "maildrop_filter: debugging enabled.\n" if $debug;

    my $prefix  = $conf->{'toaster_prefix'} || "/usr/local";
    my $logbase = $conf->{'qmail_log_base'};

    # if any of these are set
    #$debug ||= $conf->{'toaster_debug'};

    unless ($logbase) {
        $logbase = -d "/var/log/qmail" ? "/var/log/qmail"
                 : "/var/log/mail";
    }

    my $filterfile = $conf->{'filtering_maildrop_filter_file'}
      || "$prefix/etc/mail/mailfilter";

    my ( $path, $file ) = $util->path_parse($filterfile);

    unless ( -d $path ) { $util->mkdir_system( dir => $path, debug=>$debug ) }

    unless ( -d $path ) {
        carp "Sorry, $path doesn't exist and I couldn't create it.\n";
        return 0;
    }

    my @lines = $self->maildrop_filter_file(
        logbase => $logbase,
        debug   => $debug,
    );

    my $user  = $conf->{'vpopmail_user'}  || "vpopmail";
    my $group = $conf->{'vpopmail_group'} || "vchkpw";

    # if the mailfilter file doesn't exist, create it
    if ( !-e $filterfile ) {
        $util->file_write( $filterfile, 
            lines => \@lines, 
            mode  => '0600', 
            debug => $debug,
        );

        $util->chown( $filterfile,
            uid   => $user,
            gid   => $group,
            debug => $debug,
        );

        $log->audit("installed new $filterfile, ok");
    }

    # write out filter to a new file
    $util->file_write( "$filterfile.new", 
        lines => \@lines, 
        mode  =>'0600', 
        debug => $debug,
    );

    $util->chown( "$filterfile.new",
        uid  => $user,
        gid  => $group,
        debug => $debug,
    );

    $util->install_if_changed(
        newfile  => "$filterfile.new",
        existing => $filterfile,
        uid      => $user,
        gid      => $group,
        mode     => '0600',
        clean    => 0,
        debug    => $debug,
        notify   => 1,
        archive  => 1,
    );

    $file = "/etc/newsyslog.conf";
    if ( -e $file ) {
        unless (`grep maildrop $file`) {
            $util->file_write( $file,
                lines =>
                  ["/var/log/mail/maildrop.log $user:$group 644	3	1000 *	Z"],
                append => 1,
                debug  => $debug,
            );
        }
    }
}

sub maildrop_filter_file {

    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'logbase' => { type => SCALAR, },
            'fatal'   => { type => BOOLEAN, optional => 1, default => 1 },
            'debug'   => { type => BOOLEAN, optional => 1, default => $debug },
        },
    );

    my $logbase = $p{'logbase'};
    my $fatal   = $p{'fatal'};
       $debug   = $p{'debug'};

    my $prefix  = $conf->{'toaster_prefix'} || "/usr/local";
    my $filterfile = $conf->{'filtering_maildrop_filter_file'}
      || "$prefix/etc/mail/mailfilter";

    my @lines = 'SHELL="/bin/sh"';
    push @lines, <<"EOMAILDROP";
import EXT
import HOST
VHOME=`pwd`
TIMESTAMP=`date "+\%b \%d \%H:\%M:\%S"`
MAILDROP_OLD_REGEXP="1"

##
#  title:  mailfilter-site
#  author: Matt Simerson
#  version 2.12
#
#  This file is automatically generated by toaster_setup.pl, 
#  DO NOT HAND EDIT, your changes may get overwritten!
#
#  Make changes to toaster-watcher.conf, and run 
#  toaster_setup.pl -s maildrop to rebuild this file. Old versions
#  are preserved as $filterfile.timestamp
#
#  Usage: Install this file in your local etc/mail/mailfilter. On 
#  your system, this is $prefix/etc/mail/mailfilter
#
#  Create a .qmail file in each users Maildir as follows:
#  echo "| $prefix/bin/maildrop $prefix/etc/mail/mailfilter" \
#      > ~vpopmail/domains/example.com/user/.qmail
#
#  You can also use qmailadmin v1.0.26 or higher to do that for you
#  via it is --enable-modify-spam and --enable-spam-command options.
#  This is the default behavior for your Mail::Toaster.
#
# Environment Variables you can import from qmail-local:
#  SENDER  is  the envelope sender address
#  NEWSENDER is the forwarding envelope sender address
#  RECIPIENT is the envelope recipient address, local\@domain
#  USER is user
#  HOME is your home directory
#  HOST  is the domain part of the recipient address
#  LOCAL is the local part
#  EXT  is  the  address extension, ext.
#  HOST2 is the portion of HOST preceding the last dot
#  HOST3 is the portion of HOST preceding the second-to-last dot
#  HOST4 is the portion of HOST preceding the third-to-last dot
#  EXT2 is the portion of EXT following the first dash
#  EXT3 is the portion following the second dash; 
#  EXT4 is the portion following the third dash.
#  DEFAULT  is  the  portion corresponding to the default part of the .qmail-... file name
#  DEFAULT is not set if the file name does not end with default
#  DTLINE  and  RPLINE are the usual Delivered-To and Return-Path lines, including newlines
#
# qmail-local will be calling maildrop. The exit codes that qmail-local
# understands are:
#     0 - delivery is complete
#   111 - temporary error
#   xxx - unknown failure
##
EOMAILDROP

    $conf->{'filtering_debug'} ? push @lines, qq{logfile "$logbase/maildrop.log"}
                               : push @lines, qq{#logfile "$logbase/maildrop.log"};

    push @lines, <<'EOMAILDROP2';
log "$TIMESTAMP - BEGIN maildrop processing for $EXT@$HOST ==="

# I have seen cases where EXT or HOST is unset. This can be caused by 
# various blunders committed by the sysadmin so we should test and make
# sure things are not too messed up.
#
# By exiting with error 111, the error will be logged, giving an admin
# the chance to notice and fix the problem before the message bounces.

if ( $EXT eq "" )
{ 
        log "  FAILURE: EXT is not a valid value ($EXT)"
        log "=== END ===  $EXT@$HOST failure (EXT variable not imported)"
        EXITCODE=111
        exit
}

if ( $HOST eq "" )
{ 
        log "  FAILURE: HOST is not a valid value ($HOST)"
        log "=== END ===  $EXT@$HOST failure (HOST variable not imported)"
        EXITCODE=111
        exit
}

EOMAILDROP2

    my $spamass_method = $conf->{'filtering_spamassassin_method'};

    if ( $spamass_method eq "user" || $spamass_method eq "domain" ) {

        push @lines, <<"EOMAILDROP3";
##
# Note that if you want to pass a message larger than 250k to spamd
# and have it processed, you will need to also set spamc -s. See the
# spamc man page for more details.
##

exception {
	if ( /^X-Spam-Status: /:h )
	{
		# do not pass through spamassassin if the message already
		# has an X-Spam-Status header. 

		log "Message already has X-Spam-Status header, skipping spamc"
	}
	else
	{
		if ( \$SIZE < 256000 ) # Filter if message is less than 250k
		{
			`test -x $prefix/bin/spamc`
			if ( \$RETURNCODE == 0 )
			{
				log `date "+\%b \%d \%H:\%M:\%S"`" \$PID - running message through spamc"
#				log "   running message through spamc"
				exception {
					xfilter '$prefix/bin/spamc -u "\$EXT\@\$HOST"'
				}
			}
			else
			{
				log "   WARNING: no $prefix/bin/spamc binary!"
			}
		}
	}
}
EOMAILDROP3

    }

    push @lines, <<"EOMAILDROP4";
##
# Include any rules set up for the user - this gives the 
# administrator a way to override the sitewide mailfilter file
#
# this is also the "suggested" way to set individual values
# for maildrop such as quota.
##

`test -r \$VHOME/.mailfilter`
if( \$RETURNCODE == 0 )
{
	log "   including \$VHOME/.mailfilter"
	exception {
		include \$VHOME/.mailfilter
	}
}

## 
# create the maildirsize file if it does not already exist
# (could also be done via "deliverquota user\@dom.com 10MS,1000C)
##

`test -e \$VHOME/Maildir/maildirsize`
if( \$RETURNCODE == 1)
{
	VUSERINFO="$prefix/vpopmail/bin/vuserinfo"
	`test -x \$VUSERINFO`
	if ( \$RETURNCODE == 0)
	{
		log "   creating \$VHOME/Maildir/maildirsize for quotas"
		`\$VUSERINFO -Q \$EXT\@\$HOST`

		`test -s "\$VHOME/Maildir/maildirsize"`
   		if ( \$RETURNCODE == 0 )
   		{
     			`/usr/sbin/chown vpopmail:vchkpw \$VHOME/Maildir/maildirsize`
				`/bin/chmod 640 \$VHOME/Maildir/maildirsize`
		}
	}
	else
	{
		log "   WARNING: cannot find vuserinfo! Please edit mailfilter"
	}
}

EOMAILDROP4

    push @lines, <<'EOMAILDROP5';
##
# Set MAILDIRQUOTA. If this is not set, maildrop and deliverquota
# will not enforce quotas for message delivery.
#
# I find this much easier than creating yet another config file
# to store this in. This way, any time the quota is changed in
# vpopmail, it will get noticed by maildrop immediately.
##

`test -e $VHOME/Maildir/maildirsize`
if( $RETURNCODE == 0)
{
	MAILDIRQUOTA=`/usr/bin/head -n1 $VHOME/Maildir/maildirsize`
}

##
# The message should be tagged, so lets bag it.
##
# HAM:  X-Spam-Status: No, score=-2.6 required=5.0
# SPAM: X-Spam-Status: Yes, score=8.9 required=5.0
#
# Note: SA < 3.0 uses "hits" instead of "score"
#
# if ( /^X-Spam-Status: *Yes/)  # test if spam status is yes
# The following regexp matches any spam message and sets the
# variable $MATCH2 to the spam score.

if ( /X-Spam-Status: Yes, (hits|score)=![0-9]+\.[0-9]+! /:h)
{
EOMAILDROP5

    my $score     = $conf->{'filtering_spama_discard_score'};
    my $pyzor     = $conf->{'filtering_report_spam_pyzor'};
    my $sa_report = $conf->{'filtering_report_spam_spamassassin'};

    if ($score) {

        push @lines, <<"EOMAILDROP6";
	# if the message scored a $score or higher, then there is no point in
	# keeping it around. SpamAssassin already knows it as spam, and
	# has already "autolearned" from it if you have that enabled. The
	# end user likely does not want it. If you wanted to cc it, or
	# deliver it elsewhere for inclusion in a spam corpus, you could
	# easily do so with a cc or xfilter command

	if ( \$MATCH2 >= $score )   # from Adam Senuik post to mail-toasters
	{
EOMAILDROP6

        if ( $pyzor && !$sa_report ) {

            push @lines, <<"EOMAILDROP7";
		`test -x $prefix/bin/pyzor`
		if( \$RETURNCODE == 0 )
		{
			# if the pyzor binary is installed, report all messages with
			# high spam scores to the pyzor servers
		
			log "   SPAM: score \$MATCH2: reporting to Pyzor"
			exception {
				xfilter "$prefix/bin/pyzor report"
			}
		}
EOMAILDROP7
        }

        if ($sa_report) {

            push @lines, <<"EOMAILDROP8";

		# new in version 2.5 of Mail::Toaster mailfiter
		`test -x $prefix/bin/spamassassin`
		if( \$RETURNCODE == 0 )
		{
			# if the spamassassin binary is installed, report messages with
			# high spam scores to spamassassin (and consequently pyzor, dcc,
			# razor, and SpamCop)
		
			log "   SPAM: score \$MATCH2: reporting spam via spamassassin -r"
			exception {
				xfilter "$prefix/bin/spamassassin -r"
			}
		}
EOMAILDROP8
        }

        push @lines, <<"EOMAILDROP9";
		log "   SPAM: score \$MATCH2 exceeds $score: nuking message!"
		log "=== END === \$EXT\@\$HOST success (discarded)"
		EXITCODE=0
		exit
	}
EOMAILDROP9
    }

    push @lines, <<"EOMAILDROP10";
	# if the user does not have a Spam folder, we create it.

	`test -d \$VHOME/Maildir/.Spam`
	if( \$RETURNCODE == 1 )
	{
		log "   creating \$VHOME/Maildir/.Spam "
		`maildirmake -f Spam \$VHOME/Maildir`
		`$prefix/sbin/subscribeIMAP.sh Spam \$VHOME`
	}

	log "   SPAM: score \$MATCH2: delivering to \$VHOME/Maildir/.Spam"

	# make sure the deliverquota binary exists and is executable
	# if not, then we cannot enforce quotas. If you do not check
	# for this, and the binary is missing, maildrop silently
	# discards mail. Do not ask how I know this.

	`test -x $prefix/bin/deliverquota`
	if ( \$RETURNCODE == 1 )
	{
		log "   WARNING: no deliverquota!"
		log "=== END ===  \$EXT\@\$HOST success"
		exception {
			to "\$VHOME/Maildir/.Spam"
		}
	}
	else
	{
		exception {
			xfilter "$prefix/bin/deliverquota -w 90 \$VHOME/Maildir/.Spam"
		}

		if ( \$RETURNCODE == 0 )
		{
			log "=== END ===  \$EXT\@\$HOST  success (quota)"
			EXITCODE=0
			exit
		}
		else
		{
			if( \$RETURNCODE == 77)
			{
				log "=== END ===  \$EXT\@\$HOST  bounced (quota)"
				to "|/var/qmail/bin/bouncesaying '\$EXT\@\$HOST is over quota'"
			}
			else
			{
				log "=== END ===  \$EXT\@\$HOST failure (unknown deliverquota error)"
				to "\$VHOME/Maildir/.Spam"
			}
		}
	}
}

if ( /^X-Spam-Status: No, hits=![\\-]*[0-9]+\\.[0-9]+! /:h)
{
	log "   message is clean (\$MATCH2)"
}

##
# Include any other rules that the user might have from
# sqwebmail or other compatible program
##

`test -r \$VHOME/Maildir/.mailfilter`
if( \$RETURNCODE == 0 )
{
	log "   including \$VHOME/Maildir/.mailfilter"
	exception {
		include \$VHOME/Maildir/.mailfilter
	}
}

log "   delivering to \$VHOME/Maildir"

`test -x $prefix/bin/deliverquota`
if ( \$RETURNCODE == 1 )
{
	log "   WARNING: no deliverquota!"
	log "=== END ===  \$EXT\@\$HOST success"
	exception {
		to "\$VHOME/Maildir"
	}
}
else
{
	exception {
		xfilter "$prefix/bin/deliverquota -w 90 \$VHOME/Maildir"
	}

	##
	# check to make sure the message was delivered
	# returncode 77 means that out maildir was overquota - bounce mail
	##
	if( \$RETURNCODE == 77)
	{
		#log "   BOUNCED: bouncesaying '\$EXT\@\$HOST is over quota'"
		log "=== END ===  \$EXT\@\$HOST  bounced"
		to "|/var/qmail/bin/bouncesaying '\$EXT\@\$HOST is over quota'"
	}
	else
	{
		log "=== END ===  \$EXT\@\$HOST  success (quota)"
		EXITCODE=0
		exit
	}
}

log "WARNING: This message should never be printed!"
EOMAILDROP10

    return @lines;
}

sub maillogs {

    my $self  = shift;
    my %p = validate( @_, { %std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing only
    my $debug = $self->set_debug( $p{debug} );
    my $fatal = $self->set_fatal( $p{fatal} );

    my $user  = $conf->{'qmail_log_user'}  || "qmaill";
    my $group = $conf->{'qmail_log_group'} || "qnofiles";

    my $uid = getpwnam($user);
    my $gid = getgrnam($group);

    unless ( $uid && $gid ) {
        print "\nFAILED! The user $user or group $group does not exist.\n";
        return 0;
    }

    $toaster->supervise_dirs_create( debug => $debug );

    # if it exists, make sure it's owned by qmail:qnofiles
    my $logdir = $conf->{'qmail_log_base'} || "/var/log/mail";
    if ( -w $logdir ) {
        chown( $uid, $gid, $logdir ) or carp "Couldn't chown $logdir to $uid: $!\n";
        $log->audit( "maillogs: setting ownership of $logdir, ok" );
    }

    unless ( -d $logdir ) {
        mkdir( $logdir, oct('0755') )
          or croak "maillogs: couldn't create $logdir: $!";
        chown( $uid, $gid, $logdir ) or croak "maillogs: couldn't chown $logdir: $!";
        $log->audit( "maillogs: creating $logdir, ok" );
    }

    foreach my $prot (qw/ send smtp pop3 submit /) {

        unless ( -d "$logdir/$prot" ) {

            $log->audit( "maillogs: creating $logdir/$prot, ok" );
            mkdir( "$logdir/$prot", oct('0755') )
              or croak "maillogs: couldn't create: $!";
        }
        else {
            $log->audit( "maillogs: create $logdir/$prot, ok (exists)" );
        }
        chown( $uid, $gid, "$logdir/$prot" )
          or croak "maillogs: chown $logdir/$prot failed: $!";
    }

    my $maillogs = $util->find_bin( "/usr/local/bin/maillogs", debug => 0);
    die "maillogs FAILED: couldn't find maillogs!\n" if ! -x $maillogs;

    my $r = $util->install_if_changed(
        newfile  => $maillogs,
        existing => "$logdir/send/sendlog",
        uid      => $uid,
        gid      => $gid,
        mode     => '0755',
        clean    => 0,
        debug    => $debug,
    );

    return 0 unless $r;
    $r == 1 ? $r = "ok" : $r = "ok (current)";
    $log->audit( "maillogs: update $logdir/send/sendlog, $r" );

    $r = $util->install_if_changed(
        newfile  => $maillogs,
        existing => "$logdir/smtp/smtplog",
        uid      => $uid,
        gid      => $gid,
        mode     => '0755',
        clean    => 0,
        debug    => $debug,
    );

    $r == 1
      ? $r = "ok"
      : $r = "ok (current)";

    $log->audit( "maillogs: update $logdir/smtp/smtplog, $r" );

    $r = $util->install_if_changed(
        newfile  => $maillogs,
        existing => "$logdir/pop3/pop3log",
        uid      => $uid,
        gid      => $gid,
        mode     => '0755',
        clean    => 0,
        debug    => $debug,
    );

    $r == 1
      ? $r = "ok"
      : $r = "ok (current)";

    $log->audit( "maillogs: update $logdir/pop3/pop3log, $r" );

    $self->cronolog(  debug=>$debug );
    $self->isoqlog(  debug=>$debug );

    require Mail::Toaster::Logs;
    my $logs = Mail::Toaster::Logs->new(conf=>$conf);
    $logs->verify_settings();
}

sub mrm {

    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'fatal'   => { type => BOOLEAN, optional => 1, default => 1 },
            'debug'   => { type => BOOLEAN, optional => 1, default => $debug },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
       $debug = $p{'debug'};

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    my $perlbin = $util->find_bin( "perl" );

    my @targets = ( "$perlbin Makefile.PL", "make", "make install" );
    push @targets, "make test" if $debug;

    $util->install_module_from_src(
        'Mysql-Replication',
        archive => 'Mysql-Replication.tar.gz',
        url     => '/internet/sql/mrm',
        targets => \@targets,
    );
}

sub munin {
    my $self = shift;

    $freebsd->install_port('munin-node');

# the newer (default) version of rrdtool requires an obscene amount 
# of x11 software be installed
    $freebsd->install_port('rrdtool12'); 
    $freebsd->install_port('p5-Date-Manip');
    $freebsd->install_port('munin-master');

#munin_node_enable="YES"
    $freebsd->conf_check(
        check => "munin_node_enable",
        line  => 'munin_node_enable="YES"',
    );

    return 1;
};

sub mysql {

    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => $debug },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    require Mail::Toaster::Mysql;
    my $mysql = Mail::Toaster::Mysql->new( toaster => $toaster );

    return $mysql->install( conf  => $conf, debug => $p{debug} );
}

sub nictool {

    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => $debug },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
       $debug = $p{'debug'};

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    $conf->{'install_expat'} = 1;    # this must be set for expat to install

    $self->expat(  debug=>$debug );
    $self->rsync(  debug=>$debug );
    $self->djbdns( debug=>$debug );
    $self->mysql(  debug=>$debug );

    # make sure these perl modules are installed
    $util->install_module( "LWP::UserAgent",
        port => 'p5-libwww',
        debug      => $debug,
    );
    $util->install_module( "SOAP::Lite", debug      => $debug,);
    $util->install_module( "RPC::XML", debug      => $debug,);
    $util->install_module( "DBI", debug      => $debug,);
    $util->install_module( "DBD::mysql", debug      => $debug,);

    if ( $OSNAME eq "freebsd" ) {
        if ( $conf->{'install_apache'} == 2 ) {
            $freebsd->install_port( "p5-Apache-DBI", flags => "WITH_MODPERL2=yes",);
        }
    }

    $util->install_module( "Apache::DBI", debug  => $debug,);
    $util->install_module( "Apache2::SOAP", debug  => $debug,);

    # install NicTool Server
    my $perlbin   = $util->find_bin( "perl", fatal => 0 );
    my $version   = "NicToolServer-2.03";
    my $http_base = $conf->{'toaster_http_base'};

    my @targets = ( "$perlbin Makefile.PL", "make", "make install" );

    push @targets, "make test" if $debug;

    push @targets, "mv ../$version $http_base"
      unless ( -d "$http_base/$version" );

    push @targets, "ln -s $http_base/$version $http_base/NicToolServer"
      unless ( -l "$http_base/NicToolServer" );

    $util->install_module_from_src( $version,
        archive => "$version.tar.gz",
        site    => 'http://www.nictool.com',
        url     => '/download/',
        targets => \@targets,
        debug  => $debug,
    );

    # install NicTool Client
    $version = "NicToolClient-2.03";
    @targets = ( "$perlbin Makefile.PL", "make", "make install" );
    push @targets, "make test" if $debug;

    push @targets, "mv ../$version $http_base" if ( !-d "$http_base/$version" );
    push @targets, "ln -s $http_base/$version $http_base/NicToolClient"
      if ( !-l "$http_base/NicToolClient" );

    $util->install_module_from_src( $version,
        archive => "$version.tar.gz",
        site    => 'http://www.nictool.com',
        url     => '/download/',
        targets => \@targets,
        debug  => $debug,
    );
}

sub openssl_cert {
    my $self = shift;

    my $dir = "/usr/local/openssl/certs";
    my $csr = "$dir/server.csr";
    my $crt = "$dir/server.crt";
    my $key = "$dir/server.key";
    my $pem = "$dir/server.pem";

    $util->mkdir_system(dir=>$dir, debug=>0) if ! -d $dir;

    my $openssl = $util->find_bin('openssl', debug=>0);
    system "$openssl genrsa 1024 > $key" if ! -e $key;
    $log->error( "ssl cert key generation failed!") if ! -e $key;

    system "$openssl req -new -key $key -out $csr" if ! -e $csr;
    $log->error( "cert sign request ($csr) generation failed!") if ! -e $csr;

    system "$openssl req -x509 -days 999 -key $key -in $csr -out $crt" if ! -e $crt;
    $log->error( "cert generation ($crt) failed!") if ! -e $crt;

    system "cat $key $crt > $pem" if ! -e $pem;
    $log->error( "pem generation ($pem) failed!") if ! -e $pem;

    return 1;
};

sub openssl_conf {

    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => $debug },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    return $p{test_ok} if defined $p{test_ok};

    my $fatal = $p{'fatal'};
       $debug = $p{'debug'};

    if ( !$conf->{'install_openssl'} ) {
        $log->audit( "openssl: configuring, skipping (disabled)" ) if $debug;
        return;
    }

    return if ( defined $conf->{'install_openssl_conf'} 
                    && !$conf->{'install_openssl_conf'} );

    # make sure openssl libraries are available
    $self->openssl_install();

    my $sslconf = $self->openssl_conf_find_config();

    # get/set the settings to alter
    my $country  = $conf->{'ssl_country'}      || "US";
    my $state    = $conf->{'ssl_state'}        || "Texas";
    my $org      = $conf->{'ssl_organization'} || "DisOrganism, Inc.";
    my $locality = $conf->{'ssl_locality'}     || "Dallas";
    my $name     = $conf->{'ssl_common_name'}  || $conf->{'toaster_hostname'}
      || "mail.example.com";
    my $email = $conf->{'ssl_email_address'}   || $conf->{'toaster_admin_email'}
      || "postmaster\@example.com";

    # update openssl.cnf with our settings
    my $inside;
    my $discard;
    my @lines = $util->file_read( $sslconf, debug=>0 );
    foreach my $line (@lines) {

        next if $line =~ /^#/;    # comment lines
        $inside++ if ( $line =~ /req_distinguished_name/ );
        next unless $inside;
        $discard++ if ( $line =~ /emailAddress_default/ && $line !~ /example\.com/ );

        $line = "countryName_default\t\t= $country" 
            if $line =~ /^countryName_default/;
        $line = "stateOrProvinceName_default\t= $state" 
            if $line =~ /^stateOrProvinceName_default/;
        $line = "localityName\t\t\t= Locality Name (eg, city)\nlocalityName_default\t\t= $locality" if $line =~ /^localityName\s+/;

        $line = "0.organizationName_default\t= $org"
            if $line =~ /^0.organizationName_default/;
        $line = "commonName_max\t\t\t= 64\ncommonName_default\t\t= $name"
            if $line =~ /^commonName_max/;
        $line = "emailAddress_max\t\t= 64\nemailAddress_default\t\t= $email"
            if $line =~ /^emailAddress_max/;
    }

    if ($discard) {
        $log->audit( "openssl: updating $sslconf, ok (no change)" );
        return 2;
    }

    my $tmpfile = "/tmp/openssl.cnf";
    $util->file_write( $tmpfile, lines => \@lines, debug => 0 );
    $util->install_if_changed(
        newfile  => $tmpfile,
        existing => $sslconf,
        debug    => 0,
    );

    return $self->openssl_cert();
}

sub openssl_conf_find_config {
    my $self = shift;

    # figure out where openssl.cnf is
    my $sslconf = "/etc/ssl/openssl.cnf";

    if ( $OSNAME eq "freebsd" ) { 
        $sslconf = "/etc/ssl/openssl.cnf";   # built-in
        $self->openssl_conf_freebsd( $sslconf );
    }
    elsif ( $OSNAME eq "darwin" ) {
        $sslconf = "/System/Library/OpenSSL/openssl.cnf";
    }
    elsif ( $OSNAME eq "linux" ) { 
        if ( ! -e $sslconf ) {
# centos (and probably RedHat/Fedora)
            $sslconf = "/etc/share/ssl/openssl.cnf"; 
        };
    }

    $log->error( "openssl: could not find your openssl.cnf file!") if ! -e $sslconf;
    $log->error( "openssl: no write permission to $sslconf!" ) if ! -w $sslconf;

    $log->audit( "openssl: found $sslconf, ok" );
    return $sslconf;
};

sub openssl_conf_freebsd {
    my $self = shift;
    my $conf = shift or return;

    if ( ! -e $conf && -e '/usr/local/openssl/openssl.cnf.sample' ) {
        mkpath "/etc/ssl";
        system "cp /usr/local/openssl/openssl.cnf.sample $conf";
    };

    if ( -d "/usr/local/openssl" ) {
        if ( ! -e "/usr/local/openssl/openssl.cnf" ) {
            symlink($conf, "/usr/local/openssl/openssl.cnf");
        };
    };
};

sub openssl_get_ciphers {
    my $self = shift;
    my $ciphers = shift;
    my $openssl = $util->find_bin( 'openssl', debug=>0 );

    my $s = $ciphers eq 'all'    ? 'ALL'
        : $ciphers eq 'high'   ? 'HIGH:!SSLv2'
        : $ciphers eq 'medium' ? 'HIGH:MEDIUM:!SSLv2'
        : $ciphers eq 'pci'    ? 'DEFAULT:!ADH:!LOW:!EXP:!SSLv2:+HIGH:+MEDIUM'
        :                        'DEFAULT';
    $ciphers = `$openssl ciphers $s`;
    chomp $ciphers;
    return $ciphers;
};

sub openssl_install {
    my $self = shift; 

    return if ! $conf->{'install_openssl'};

    if ( $OSNAME eq 'freebsd' ) {
        if (!$freebsd->is_port_installed( 'openssl' ) ) {
            $self->openssl_install_freebsd();
        };
    }
    else {
        my $bin = $util->find_bin('openssl',debug=>0,fatal=>0);
        if ( ! $bin ) {
            warn "no openssl support for OS $OSNAME, please install manually.\n";
        }
        else {
            warn "using detected openssl on $OSNAME.\n";
        };
    };
};

sub openssl_install_freebsd {
    my $self = shift;

    return $freebsd->install_port( 'openssl',
        category=> 'security',
        options => "# This file is auto-generated by mail-toaster
# No user-servicable parts inside!
# Options for openssl-1.0.0_1
_OPTIONS_READ=openssl-1.0.0_1
WITHOUT_I386=true
WITH_SSE2=true
WITH_ASM=true
WITH_ZLIB=true
WITHOUT_MD2=true
WITHOUT_RC5=true
WITHOUT_RFC3779=true
WITHOUT_DTLS_BUGS=true
WITHOUT_DTLS_RENEGOTIATION=true
WITHOUT_DTLS_HEARTBEAT=true
WITHOUT_TLS_EXTRACTOR=true
WITHOUT_SCTP=true",
    );
};

sub periodic_conf {

    return if -e "/etc/periodic.conf";

    open my $PERIODIC, '>>', '/etc/periodic.conf';
    print $PERIODIC '
#--periodic.conf--
# 210.backup-aliases
daily_backup_aliases_enable="NO"                       # Backup mail aliases

# 440.status-mailq
daily_status_mailq_enable="YES"                         # Check mail status
daily_status_mailq_shorten="NO"                         # Shorten output
daily_status_include_submit_mailq="NO"                 # Also submit queue

# 460.status-mail-rejects
daily_status_mail_rejects_enable="NO"                  # Check mail rejects
daily_status_mail_rejects_logs=3                        # How many logs to check
#-- end --
';
    close $PERIODIC;
}

sub pop3_test_auth {

    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => $debug },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
       $debug = $p{'debug'};

    my @features;

    $OUTPUT_AUTOFLUSH = 1;

    my $r = $util->install_module( "Mail::POP3Client", debug => 0,);
    $log->test("checking Mail::POP3Client", $r );
    if ( ! $r ) {
        print "skipping POP3 tests\n";
        return;
    };

    my %auths = (
        'POP3'          => { type => 'PASS',     descr => 'plain text' },
        'POP3-APOP'     => { type => 'APOP',     descr => 'APOP' },
        'POP3-CRAM-MD5' => { type => 'CRAM-MD5', descr => 'CRAM-MD5' },
        'POP3-SSL'      => { type => 'PASS', descr => 'plain text', ssl => 1 },
        'POP3-SSL-APOP' => { type => 'APOP', descr => 'APOP', ssl => 1 },
        'POP3-SSL-CRAM-MD5' => { type => 'CRAM-MD5', descr => 'CRAM-MD5', ssl => 1 },
    );

    foreach ( sort keys %auths ) {
        pop3_auth( $_, $auths{$_}, $debug );
    }

    sub pop3_auth {

        my ( $key, $v, $debug ) = @_;

        my $type  = $v->{'type'};
        my $descr = $v->{'descr'};

        my $user = $conf->{'toaster_test_email'}        || 'test2@example.com';
        my $pass = $conf->{'toaster_test_email_pass'}   || 'cHanGeMe';
        my $host = $conf->{'pop3_ip_address_listen_on'} || 'localhost';
        $host = "localhost" if ( $host =~ /system|qmail|all/i );

        my $pop = Mail::POP3Client->new(
            HOST      => $host,
            AUTH_MODE => $type,
            USESSL    => $v->{ssl} ? 1 : 0,
        );

        $pop->User($user);
        $pop->Pass($pass);
        $pop->Connect() >= 0 || warn $pop->Message();
        $log->test( "  $key authentication", ($pop->State() eq "TRANSACTION"));

        if ( my @features = $pop->Capa() ) {
            print "  POP3 server supports: " . join( ",", @features ) . "\n"
              if $debug;
        }
        $pop->Close;
    }

    return 1;
}

sub php {
    my $self = shift;

    if ( $OSNAME eq 'freebsd' ) {
        return $self->php_freebsd();
    };

    my $php = $util->find_bin('php',fatal=>0);
    $log->error( "no php install support for $OSNAME yet, and php is not installed. Please install and try again." );
    return;
};

sub php_freebsd {
    my $self = shift;

    my $apache = $conf->{install_apache} ? 'WITH' : 'WITHOUT';

    $freebsd->install_port( "php5",
        category=> 'lang',
        options => "#\n# This file was generated by mail-toaster
# Options for php5-5.3.2_1
_OPTIONS_READ=php5-5.3.2_1
WITH_CLI=true
WITH_CGI=true
${apache}_APACHE=true
WITHOUT_DEBUG=true
WITH_SUHOSIN=true
WITHOUT_MULTIBYTE=true
WITH_IPV6=true
WITHOUT_MAILHEAD=true\n",
    ) or return;

    my $config = "/usr/local/etc/php.ini";
    if ( ! -e $config ) {
        copy("$config-production", $config) if -e "$config-production";
        chmod oct('0644'), $config;
    };

    return 1 if -f $config;
    return;
};

sub phpmyadmin {

    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => $debug },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
       $debug = $p{'debug'};

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    unless ( $conf->{'install_phpmyadmin'} ) {
        print "phpMyAdmin install disabled. Set install_phpmyadmin in " 
            . "toaster-watcher.conf if you want to install it.\n";
        return 0;
    }

    # prevent t1lib from installing X11
    if ( $OSNAME eq "freebsd" ) {
        $freebsd->install_port( "t1lib", flags => "WITHOUT_X11=yes" );

        if (    !$freebsd->is_port_installed( "xorg-libraries", debug=>$debug )
            and !$freebsd->is_port_installed( "XFree86-Libraries", debug=>$debug ) )
        {
            if (
                $util->yes_or_no(
"php-gd requires x11 libraries. Shall I try installing the xorg-libraries package?"
                )
              )
            {
                $freebsd->package_install( port => "XFree86-Libraries", debug=>$debug  );
            }
        }
        if ( $conf->{'install_php'} eq "4" ) {
            $freebsd->install_port( "php4-gd" );
        } elsif ( $conf->{'install_php'} eq "5" ) {
            $freebsd->install_port( "php5-gd" );
        };
    }

    require Mail::Toaster::Mysql;
    my $mysql = Mail::Toaster::Mysql->new( toaster => $toaster );
    $mysql->phpmyadmin_install($conf);
}

sub ports {

    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => $debug },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
       $debug = $p{'debug'};

    if ( $OSNAME eq "freebsd" ) {
        $freebsd->ports_update(conf=>$conf, debug=>$debug);
    }
    elsif ( $OSNAME eq "darwin" ) {
        $darwin->ports_update();
    }
    else {
        print "Sorry, no ports support for $OSNAME yet.\n";
    }
}

sub qmailadmin {

    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => $debug },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
       $debug = $p{'debug'};

    my $ver = $conf->{'install_qmailadmin'};

    unless ($ver) {
        print "skipping qmailadmin install, it's not selected!\n";
        return 0;
    }

    my $package = "qmailadmin-$ver";
    my $site    = "http://" . $conf->{'toaster_sf_mirror'};
    my $url     = "/qmailadmin";

    my $toaster = "$conf->{'toaster_dl_site'}$conf->{'toaster_dl_url'}";
    $toaster ||= "http://mail-toaster.org";

    my $httpdir = $conf->{'toaster_http_base'} || "/usr/local/www";

    my $cgi = $conf->{'qmailadmin_cgi-bin_dir'};
    unless ( $cgi && -e $cgi ) {
        $cgi = $conf->{'toaster_cgi_bin'};
        unless ( $cgi && -e $cgi ) {
            -d "/usr/local/www/cgi-bin.mail"
              ? $cgi = "/usr/local/www/cgi-bin.mail"
              : $cgi = "/usr/local/www/cgi-bin";
        }
    }

    my $docroot = $conf->{'qmailadmin_http_docroot'};
    unless ( $docroot && -e $docroot ) {
        $docroot = $conf->{'toaster_http_docs'};
        unless ( $docroot && -e $docroot ) {
            if ( -d "/usr/local/www/mail" ) {
                $docroot = "/usr/local/www/mail";
            }
            elsif ( -d "/usr/local/www/data/mail" ) {
                $docroot = "/usr/local/www/data/mail";
            }
            else { $docroot = "/usr/local/www/data"; }
        }
    }

    my ($help);
    $help++ if $conf->{'qmailadmin_help_links'};

    if ( $ver eq "port" ) {
        if ( $OSNAME ne "freebsd" ) {
            print
              "FAILURE: Sorry, no port install of qmailadmin (yet). Please edit
toaster-watcher.conf and select a version of qmailadmin to install.\n";
            return 0;
        }

        $self->qmailadmin_port_install( $debug );
        $self->qmailadmin_help( $debug) if $help;
        return 1;
    }

    my $conf_args;

    if ( -x "$cgi/qmailadmin" ) {
        return 0
          unless $util->yes_or_no(
            "qmailadmin is installed, do you want to reinstall?",
            timeout  => 60,
          );
    }

    if ( $conf->{'qmailadmin_domain_autofill'} ) {
        $conf_args = " --enable-domain-autofill=Y";
        print "domain autofill: yes\n";
    }

    if ( $util->yes_or_no( "\nDo you want spam options? " ) ) {
        $conf_args .=
            " --enable-modify-spam=Y"
            . " --enable-spam-command=\""
            . $conf->{'qmailadmin_spam_command'} . "\"";
    }

    if ( $conf->{'qmailadmin_modify_quotas'} ) {
        $conf_args .= " --enable-modify-quota=y";
        print "modify quotas: yes\n";
    }

    if ( $conf->{'qmailadmin_install_as_root'} ) {
        $conf_args .= " --enable-vpopuser=root";
        print "install as root: yes\n";
    }

    $conf_args .= " --enable-htmldir=" . $docroot . "/qmailadmin";
    $conf_args .= " --enable-imagedir=" . $docroot . "/qmailadmin/images";
    $conf_args .= " --enable-imageurl=/qmailadmin/images";
    $conf_args .= " --enable-cgibindir=" . $cgi;
    $conf_args .= " --enable-autoresponder-path=".$conf->{'toaster_prefix'}."/bin";

    if ( $conf->{'qmailadmin_help_links'} ) {
        $conf_args .= " --enable-help=y";
        $help = 1;
    }

    if ( $OSNAME eq "darwin" ) {
        my $vpopdir = $conf->{'vpopmail_home_dir'} || "/usr/local/vpopmail";
        $util->syscmd( "ranlib $vpopdir/lib/libvpopmail.a", debug => 0 );
    }

    my $make = $util->find_bin( "gmake", fatal=>0, debug=>0) ||
        $util->find_bin( "make", debug=>0 );

    $util->install_from_source(
        package   => $package,
        site      => $site,
        url       => $url,
        targets   =>
          [ "./configure " . $conf_args, "$make", "$make install-strip" ],
        debug          => $debug,
        source_sub_dir => 'mail',
    );

    $self->qmailadmin_help( $debug ) if $help;

    return 1;
}

sub qmailadmin_help {
    my $self = shift;
    my $debug = shift;

    my $ver     = $conf->{'qmailadmin_help_links'} or return;
    my $cgi     = $conf->{'qmailadmin_cgi-bin_dir'};
    my $docroot = $conf->{qmailadmin_http_docroot} || $conf->{toaster_http_docs};
    my $helpdir = $docroot . "/qmailadmin/images/help";

    if ( -d $helpdir ) {
        $log->audit( "qmailadmin: installing help files, ok (exists)" );
        return 1;
    }

    my $src  = $conf->{'toaster_src_dir'} || "/usr/local/src";
       $src .= "/mail";
 
    print "qmailadmin: Installing help files in $helpdir\n";
    $util->cwd_source_dir( $src, debug=>$debug );

    my $helpfile = "qmailadmin-help-$ver";
    unless ( -e "$helpfile.tar.gz" ) {
        my $url = "http://$conf->{toaster_sf_mirror}/qmailadmin/qmailadmin-help/$ver/$helpfile.tar.gz";
        print "qmailadmin: fetching helpfile tarball from $url.\n";
        $util->get_url( $url );
    }

    if ( !-e "$helpfile.tar.gz" ) {
        carp "qmailadmin: FAILED: help files couldn't be downloaded!\n";
        return;
    }

    $util->extract_archive( "$helpfile.tar.gz" );

    move( $helpfile, $helpdir ) or
        $log->error( "Could not move $helpfile to $helpdir");

    $log->audit( "qmailadmin: installed help files, ok" );
}

sub qmailadmin_port_install {
    my $self = shift;
    my $cgi = $conf->{qmailadmin_cgi_bin_dir} || $conf->{toaster_cgi_bin};
    my $docroot = $conf->{qmailadmin_http_docroot} || $conf->{toaster_http_docs};
    my $debug = @_;

    my ( @args, $cgi_sub, $docroot_sub );

    push @args, "WITH_DOMAIN_AUTOFILL=yes" if $conf->{'qmailadmin_domain_autofill'};
    push @args, "WITH_MODIFY_QUOTA=yes"    if $conf->{'qmailadmin_modify_quotas'};
    push @args, "WITH_HELP=yes" if $conf->{'qmailadmin_help_links'};
    push @args, 'CGIBINSUBDIR=""';

    if ( $cgi && $cgi =~ /\/usr\/local\/(.*)$/ ) { 
        $cgi_sub = $1; 
        chop $cgi_sub if $cgi_sub =~ /\/$/; # remove trailing /
        push @args, "CGIBINDIR=\"$cgi_sub\"";
    }

    if ( $docroot =~ /\/usr\/local\/(.*)$/ ) {
        chop $cgi_sub if $cgi_sub =~ /\/$/; # remove trailing /
        $docroot_sub = $1;
    }
    push @args, "WEBDATADIR=\"$docroot_sub\"";
    push @args, 'WEBDATASUBDIR="qmailadmin"';

    push @args, "QMAIL_DIR=\"$conf->{'qmail_dir'}\""
        if $conf->{'qmail_dir'} ne "/var/qmail";

    if ( $conf->{'qmailadmin_spam_option'} ) {
        push @args, "WITH_SPAM_DETECTION=yes";
        push @args, "SPAM_COMMAND=\"$conf->{'qmailadmin_spam_command'}\""
            if $conf->{'qmailadmin_spam_command'};
    }

    $freebsd->install_port( "qmailadmin", flags => join( ",", @args ) );

    if ( $conf->{'qmailadmin_install_as_root'} ) {
        my $gid = getgrnam("vchkpw");
        chown( 0, $gid, "/usr/local/$cgi_sub/qmailadmin" );
    }
}

sub razor {

    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => $debug },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
       $debug = $p{'debug'};

    my $ver = $conf->{'install_razor'};

    unless ( $ver ) {
        $log->audit( "razor: installing, skipping (disabled)" )
          if $debug;
        return 0;
    }

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    $util->install_module( "Digest::Nilsimsa", debug      => $debug,);
    $util->install_module( "Digest::SHA1", debug      => $debug,);

    if ( $ver eq "port" ) {
        if ( $OSNAME eq "freebsd" ) {
            $freebsd->install_port( "razor-agents" );
        }
        elsif ( $OSNAME eq "darwin" ) {
            # old ports tree, deprecated
            $darwin->install_port( "razor" );    
            # this one should work
            $darwin->install_port( "p5-razor-agents" );
        }
    }

    if ( $util->find_bin( "razor-client", fatal => 0, debug=>$debug ) ) {
        print "It appears you have razor installed, skipping manual build.\n";
        $self->razor_config($debug);
        return 1;
    }

    $ver = "2.80" if ( $ver == 1 || $ver eq "port" );

    $util->install_module_from_src( 'razor-agents-' . $ver,
        archive => 'razor-agents-' . $ver . '.tar.gz',
        site    => 'http://umn.dl.sourceforge.net/sourceforge',
        url     => '/razor',
        conf    => $conf,
        debug   => $debug,
    );

    $self->razor_config($debug);
    return 1;
}

sub razor_config {

    my $self  = shift;
    my $debug = $self->{'debug'};

    print "razor: beginning configuration.\n";

    if ( -d "/etc/razor" ) {
        print "razor_config: it appears you have razor configured, skipping.\n";
        return 1;
    }

    my $client = $util->find_bin( "razor-client", fatal => 0, debug=>$debug );
    my $admin  = $util->find_bin( "razor-admin",  fatal => 0, debug=>$debug );

    # for old versions of razor
    if ( -x $client && !-x $admin ) {
        $util->syscmd( $client, debug=>0 );
    }

    unless ( -x $admin ) {
        print "FAILED: couldn't find $admin!\n";
        return 0;
    }

    $util->syscmd( "$admin -home=/etc/razor -create -d", debug=>0 );
    $util->syscmd( "$admin -home=/etc/razor -register -d", debug=>0 );

    my $file = "/etc/razor/razor-agent.conf";
    if ( -e $file ) {
        my @lines = $util->file_read( $file );
        foreach my $line (@lines) {
            if ( $line =~ /^logfile/ ) {
                $line = 'logfile                = /var/log/razor-agent.log';
            }
        }
        $util->file_write( $file, lines => \@lines, debug=>0 );
    }

    $file = "/etc/newsyslog.conf";
    if ( -e $file ) {
        if ( !`grep razor-agent $file` ) {
            $util->file_write( $file,
                lines  => ["/var/log/razor-agent.log	600	5	1000 *	Z"],
                append => 1,
                debug  => 0,
            );
        }
    }

    print "razor: configuration completed.\n";
    return 1;
}

sub refresh_config {
    my ($self, $file_path) = @_;

    if ( ! -f $file_path ) {
        $log->audit( "config: $file_path is missing!, FAILED" );
        return;
    };

    warn "found: $file_path \n" if $self->{debug};

    # refresh our $conf  (required for setup -s all) 
    $conf = $toaster->parse_config(
        file  => $file_path,
        debug => $self->{debug},
        fatal => $self->{fatal},
    );

    $self->set_config($conf);

    warn "refreshed \$conf from: $file_path \n" if $self->{debug};
    return $conf;
};

sub ripmime {

    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => $debug },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
       $debug = $p{'debug'};

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    my $ver = $conf->{'install_ripmime'}; 
    if ( !$ver ) {
        print "ripmime install not selected.\n";
        return 0;
    }

    print "rimime: installing...\n";

    if ( $ver eq "port" || $ver eq "1" ) {

        if ( $util->find_bin( "ripmime", fatal => 0 ) ) {
            print "ripmime: is already installed...done.\n\n";
            return 1;
        }

        if ( $OSNAME eq "freebsd" ) {
            if ( $freebsd->install_port( "ripmime" ) ) {
                return 1;
            }
        }
        elsif ( $OSNAME eq "darwin" ) {
            if ( $darwin->install_port( "ripmime" ) ) {
                return 1;
            }
        }

        if ( $util->find_bin( "ripmime", fatal => 0 ) ) {
            print "ripmime: ripmime has been installed successfully.\n";
            return 1;
        }

        $ver = "1.4.0.6";
    }

    my $ripmime = $util->find_bin( "ripmime", fatal => 0 );
    if ( -x $ripmime ) {
        my $installed = `$ripmime -V`;
        ($installed) = $installed =~ /v(.*) - /;

        if ( $ver eq $installed ) {
            print
              "ripmime: the selected version ($ver) is already installed!\n";
            return 1;
        }
    }

    $util->install_from_source(
        package        => "ripmime-$ver",
        site           => 'http://www.pldaniels.com',
        url            => '/ripmime',
        targets        => [ 'make', 'make install' ],
        bintest        => 'ripmime',
        debug          => 1,
        source_sub_dir => 'mail',
    );
}

sub roundcube {
    my $self  = shift;
    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => $self->{'debug'} },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
    my $debug = $p{'debug'};

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    if ( ! $conf->{'install_roundcube'} ) {
        print "not installing roundcube, not selected!\n";
        return 0;
    };

    if ( $OSNAME eq "freebsd" ) {
        $self->php() or return;
        $self->roundcube_freebsd() or return;
    }
    else {
        print
"please install roundcube manually. Support for install on $OSNAME is not available yet.\n";
        return;
    }

    return 1;
}

sub roundcube_freebsd {
    my $self = shift;
    my $debug = shift;
    my $mysql = $conf->{install_mysql} ? 'WITH_MYSQL' : 'WITHOUT_MYSQL';
    my $sqlite = $conf->{install_mysql} ? 'WITHOUT_SQLITE' : 'WITH_SQLITE';

    $freebsd->install_port( "roundcube", 
        category=> 'mail',
        options => "# This file generated by Mail::Toaster
# Options for roundcube-0.3_1,1
_OPTIONS_READ=roundcube-0.3_1,1
$mysql=true
WITHOUT_PGSQL=true
$sqlite=true
WITHOUT_SSL=true
WITHOUT_LDAP=true
WITHOUT_PSPELL=true
WITHOUT_NSC=true
WITHOUT_AUTOCOMP=true
",
    ) or return;

    $self->roundcube_config();
};

sub roundcube_config {
    my $self = shift;
    my $rcdir = "/usr/local/www/roundcube";
    my $config = "$rcdir/config/db.inc.php";
    my $pass = $conf->{install_roundcube_db_pass};

    if ( ! -f $config ) {
        warn "unable to find roundcube/config/db.inc.php. Edit it with appropriate DSN settings\n";
        return;
    };

    $self->config_apply_tweaks(
        file => "$rcdir/config/main.inc.php",
        changes => [
            {   search  => q{$rcmail_config['default_host'] = '';},
                replace => q{$rcmail_config['default_host'] = 'localhost';},
            },
        ],
    );

    return $self->roundcube_config_mysql() if $conf->{install_mysql};

    my $spool = '/var/spool/roundcubemail';
    mkpath $spool;
    my (undef,undef,$uid,$gid) = getpwnam('www');
    chown $uid, $gid, $spool;

    $self->config_apply_tweaks(
        file => $config,
        changes => [
            {   search  => q{$rcmail_config['db_dsnw'] = 'mysql://roundcube:pass@localhost/roundcubemail';},
                replace => q{$rcmail_config['db_dsnw'] = 'sqlite:////var/spool/roundcubemail/sqlite.db?mode=0646';},
            },
        ],
    );
};

sub roundcube_config_mysql {
    my $self = shift;

    my $rcdir = "/usr/local/www/roundcube";
    my $config = "$rcdir/config/db.inc.php";
    my $pass = $conf->{install_roundcube_db_pass};

    if ( ! `grep mysql $config | grep pass` ) {
        $log->audit( "roundcube database permission already configured" );
        return 1;
    };

    $self->config_apply_tweaks(
        file => $config,
        changes => [
            {   search  => q{$rcmail_config['db_dsnw'] = 'mysql://roundcube:pass@localhost/roundcubemail';},
                replace => "\$rcmail_config['db_dsnw'] = 'mysql://roundcube:$pass\@localhost/roundcubemail';",
            },
        ],
    );

    require Mail::Toaster::Mysql;
    my $mysql = Mail::Toaster::Mysql->new( toaster => $toaster );
    my $host = $conf->{vpopmail_mysql_repl_master};
    my $dot = $mysql->parse_dot_file( ".my.cnf", "[mysql]", 0 )
        || { user => 'root', pass => '', host => $host };
    my ( $dbh, $dsn, $drh ) = $mysql->connect( $dot );
    return if !$dbh;

    my $query = "GRANT ALL PRIVILEGES ON roundcubemail.* to 'roundcube'\@'$host' IDENTIFIED BY '$pass'";
    my $sth = $mysql->query( $dbh, $query );
    if ( $sth->errstr ) {
        $sth->finish;
        return $log->error( "roundcube database configuration failed. Configure manually" );
    };

    $log->audit( "roundcube database permissions configured" );
    $mysql->query( $dbh, "CREATE DATABASE roundcubemail" );
    $sth->finish;
    my $mybin = $util->find_bin('mysql',debug=>0);
    system "cat $rcdir/SQL/mysql.initial.sql | $mysql roundcubemail";
    return 1;
};

sub rsync {

    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => $debug },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
       $debug = $p{'debug'};

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    if ( $OSNAME eq "freebsd" ) {
        $freebsd->install_port( "rsync" );
    }
    elsif ( $OSNAME eq "darwin" ) { 
        $darwin->install_port( "rsync" );
    }
    else {
        die
"please install rsync manually. Support for $OSNAME is not available yet.\n";
    }

    return $util->find_bin('rsync',debug=>0);
}

sub set_debug {
    my ($self, $debug) = @_;
    return $self->{debug} if ! defined $debug;
    $self->{debug} = $debug;
    return $debug;
};

sub set_config {
    my $self = shift;
    my $newconf = shift;
    return $self->{conf} if ! $newconf;
    $self->{conf} = $newconf;
    $conf = $newconf;
    return $newconf;
};

sub set_fatal {
    my ($self, $fatal) = @_;
    return $self->{fatal} if ! defined $fatal;
    $self->{fatal} = $fatal;
    return $fatal;
};

sub simscan {
    my $self  = shift;
    my %p = validate( @_, {
            fatal => { type => BOOLEAN, optional => 1, },
            debug => { type => BOOLEAN, optional => 1, },
            test_ok => { type => BOOLEAN, optional => 1, },
        },
    );

    my $debug = $self->set_debug( $p{debug} );
    my $fatal = $self->set_fatal( $p{fatal} );

    if ( ! $conf->{'install_simscan'} ) {
        $log->audit( "vqadmin: installing, skipping (disabled)" );
        return;
    }

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    my $ver     = $conf->{'install_simscan'};
    if ( $OSNAME eq 'freebsd' ) {
        $self->simscan_freebsd_port();
        return if $ver eq 'port';
    };

    my $user    = $conf->{'simscan_user'} || "clamav";
    my $reje    = $conf->{'simscan_spam_hits_reject'};
    my $qdir    = $conf->{'qmail_dir'};
    my $custom  = $conf->{'simscan_custom_smtp_reject'};

    if ( -x "$qdir/bin/simscan" ) {
        return 0
            if ! $util->yes_or_no(
                "simscan is already installed, do you want to reinstall?",
                timeout => 60,
            );
    }

    my $bin;
    my $confcmd = "./configure ";
    $confcmd .= "--enable-user=$user ";
    $confcmd .= $self->simscan_ripmime( $conf, $ver, $debug );
    $confcmd .= $self->simscan_clamav( $conf, $debug );
    $confcmd .= $self->simscan_spamassassin( $conf, $debug );
    $confcmd .= $self->simscan_regex( $conf, $debug );
    $confcmd .= "--enable-received=y "       if $conf->{'simscan_received'};
    $confcmd .= "--enable-spam-hits=$reje "  if ($reje);
    $confcmd .= "--enable-attach=y " if $conf->{'simscan_block_attachments'};
    $confcmd .= "--enable-qmaildir=$qdir "   if $qdir;
    $confcmd .= "--enable-qmail-queue=$qdir/bin/qmail-queue " if $qdir;
    $confcmd .= "--enable-per-domain=y "     if $conf->{'simscan_per_domain'};
    $confcmd .= "--enable-custom-smtp-reject=y " if $custom;
    $confcmd .= "--enable-spam-passthru=y " if $conf->{'simscan_spam_passthru'};

    if ( $conf->{'simscan_quarantine'} && -d $conf->{'simscan_quarantine'} ) {
        $confcmd .= "--enable-quarantinedir=$conf->{'simscan_quarantine'}";
    }

    print "configure: $confcmd\n";
    my $patches = [];
    push @$patches, 'simscan-1.4.0-clamav.3.patch' if $confcmd =~ /clamavdb/;

    $util->install_from_source(
       'package'      => "simscan-$ver",
#       site           => 'http://www.inter7.com',
        site           => "http://downloads.sourceforge.net",
        url            => '/simscan',
        targets        => [ $confcmd, 'make', 'make install-strip' ],
        bintest        => "$qdir/bin/simscan",
        debug          => $debug,
        source_sub_dir => 'mail',
        patches        => $patches,
        patch_url      => "$conf->{'toaster_dl_site'}$conf->{'toaster_dl_url'}/patches",
    );

    $self->simscan_conf(  debug=>$debug );
}

sub simscan_clamav {
    my ( $self, $conf, $debug ) = @_;

    return '' if ! $conf->{'simscan_clamav'};

    my $bin = $util->find_bin( "clamdscan", fatal => 0, debug=>$debug );
    croak "couldn't find $bin, install ClamAV!\n" if !-x $bin;

    my $cmd .= "--enable-clamdscan=$bin ";
    $cmd .= "--enable-clamavdb-path=";
    $cmd .= -d "/var/db/clamav"  ?  "/var/db/clamav "
          : -d "/usr/local/share/clamav" ? "/usr/local/share/clamav "
          : -d "/opt/local/share/clamav" ? "/opt/local/share/clamav "
          : croak "can't find the ClamAV db path!";

    $bin = $util->find_bin( "sigtool", fatal => 0, debug => $debug );
    croak "couldn't find $bin, install ClamAV!" if ! -x $bin;
    $cmd .= "--enable-sigtool-path=$bin ";
    return $cmd;
};

sub simscan_conf {

    my $self  = shift;
    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1 },
            'debug' => { type => BOOLEAN, optional => 1 },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $debug = $self->set_debug( $p{debug} );
    my $fatal = $self->set_fatal( $p{fatal} );

    my ( $file, @lines );

    my $reje = $conf->{'simscan_spam_hits_reject'};

    my @attach;
    if ( $conf->{'simscan_block_attachments'} ) {

        $file = "/var/qmail/control/ssattach";
        foreach ( split( /,/, $conf->{'simscan_block_types'} ) ) {
            push @attach, ".$_";
        }
        $util->file_write( $file, lines => \@attach, debug=>$debug );
    }

    $file = "/var/qmail/control/simcontrol";
    if ( !-e $file ) {
        my @opts;
        $conf->{'simscan_clamav'}
          ? push @opts, "clam=yes"
          : push @opts, "clam=no";

        $conf->{'simscan_spamassassin'}
          ? push @opts, "spam=yes"
          : push @opts, "spam=no";

        $conf->{'simscan_trophie'}
          ? push @opts, "trophie=yes"
          : push @opts, "trophie=no";

        $reje
          ? push @opts, "spam_hits=$reje"
          : print "no reject.\n";

        if ( @attach > 0 ) {
            my $line  = "attach=";
            my $first = shift @attach;
            $line .= "$first";
            foreach (@attach) { $line .= ":$_"; }
            push @opts, $line;
        }

        @lines = "#postmaster\@example.com:" . join( ",", @opts );
        push @lines, "#example.com:" . join( ",", @opts );
        push @lines, "#";
        push @lines, ":" . join( ",",             @opts );

        if ( -e $file ) {
            $util->file_write( "$file.new", lines => \@lines, debug=>$debug );
            print
"\nNOTICE: simcontrol written to $file.new. You need to review and install it!\n";
        }
        else {
            $util->file_write( $file, lines => \@lines, debug=>$debug );
        }
    }

    my $user  = $conf->{'simscan_user'}       || 'simscan';
    my $group = $conf->{'smtpd_run_as_group'} || 'qmail';

    $util->syscmd( "pw user mod simscan -G qmail,clamav", debug => $debug );
    $util->chown( '/var/qmail/simscan', uid => $user, gid => $group );
    $util->chmod( dir => '/var/qmail/simscan', mode => '0770' );

    if ( -x "/var/qmail/bin/simscanmk" ) {
        $util->syscmd( "/var/qmail/bin/simscanmk", debug=>$debug );
        system "/var/qmail/bin/simscanmk";
    }
}

sub simscan_freebsd_port {
    my $self = shift;

    my @args;
    push @args, "SPAMC_ARGS=" . $conf->{simscan_spamc_args} if $conf->{simscan_spamc_args};
    push @args, 'SPAM_HITS=' . $conf->{simscan_spam_hits_reject} if $conf->{simscan_spam_hits_reject};
    push @args, 'SIMSCAN_USER=' . $conf->{simscan_user} if $conf->{simscan_user};

    # this can be removed when the simscan port Makefile is fixed. 4/11/2009
    my $file = '/usr/ports/mail/simscan/Makefile';
    my @lines = $util->file_read( $file );
    my $error = 'CONFIGURE_ARGS+=--enable-spamc-args=${SPAMC_ARGS}';
    foreach my $line (@lines) {
        if ( $line =~ /\Q$error/ ) {
            $line = 'CONFIGURE_ARGS+=--enable-spamc-args="${SPAMC_ARGS}"' . "\n";
        }
    }
    $util->file_write( $file, lines => \@lines, debug=>0 );

    $freebsd->install_port( "simscan",
        category => 'mail',
        flags => join( ",", @args ),
        options => "# This file is generated by Mail::Toaster
# No user-servicable parts inside!
# Options for simscan-1.4.0_6
_OPTIONS_READ=simscan-1.4.0_6
WITH_CLAMAV=true
WITH_RIPMIME=true
WITH_SPAMD=true
WITH_USER=true
WITH_DOMAIN=true
WITH_ATTACH=true
WITHOUT_DROPMSG=true
WITHOUT_PASSTHRU=true
WITH_HEADERS=true
WITHOUT_DSPAM=true",
    );

    return $self->simscan_conf();
};

sub simscan_regex {
    my ($self, $conf, $debug ) = @_;
    return '' if ! $conf->{'simscan_regex_scanner'};

    if ( $OSNAME eq "freebsd" ) {
        $freebsd->install_port( "pcre" );
    }
    else {
        print "\n\nNOTICE: Be sure to install pcre!!\n\n";
    }
    return "--enable-regex=y ";
};

sub simscan_ripmime {
    my ($self, $conf, $ver, $debug) = @_;

    if ( ! $self->is_newer( min => "1.0.8", cur => $ver ) ) {
        print "ripmime doesn't work with simcan < 1.0.8\n";
        return '';
    };

    return "--disable-ripmime " if ! $conf->{'simscan_ripmime'};

    my $bin = $util->find_bin( "ripmime", fatal => 0, debug=>0);
    unless ( -x $bin ) {
        croak "couldn't find $bin, install ripmime!\n";
    }
    $self->ripmime( debug => $debug );
    return "--enable-ripmime=$bin ";
};

sub simscan_spamassassin {
    my ($self, $conf, $debug) = @_;

    return '' if ! $conf->{'simscan_spamassassin'};

    my $spamc = $util->find_bin( "spamc", fatal => 0, debug=>$debug );
    my $cmd = "--enable-spam=y --enable-spamc-user=y --enable-spamc=$spamc ";

    my $spamc_args = $conf->{'simscan_spamc_args'};
    $cmd .= "--enable-spamc-args=$spamc_args " if $spamc_args;

    if ( $conf->{'simscan_received'} ) {
        my $bin = $util->find_bin( "spamassassin", fatal => 0, debug=>$debug );
        croak "couldn't find $bin, install SpamAssassin!\n" if !-x $bin;
        $cmd .= "--enable-spamassassin-path=$bin ";
    }
    return $cmd;
};

sub simscan_test {

    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => $debug },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
       $debug = $p{'debug'};

    my $qdir = $conf->{'qmail_dir'};

    if ( ! $conf->{'install_simscan'} ) {
        print "simscan installation disabled, skipping test!\n";
        return;
    }

    print "testing simscan...";
    my $scan = "$qdir/bin/simscan";
    unless ( -x $scan ) {
        print "FAILURE: Simscan could not be found at $scan!\n";
        return;
    }

    $ENV{"QMAILQUEUE"} = $scan;
    $toaster->email_send( type => "clean" );
    $toaster->email_send( type => "attach" );
    $toaster->email_send( type => "virus" );
    $toaster->email_send( type => "clam" );
    $toaster->email_send( type => "spam" );
}

sub smtp_test_auth {

    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => $debug },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
       $debug = $p{'debug'};

    my $r = $util->install_module( "Net::SMTP_auth", debug=>0);
    $log->test( "checking Net::SMTP_auth", $r );
    if ( ! $r ) {
        print "skipping SMTP auth tests\n";
        return;
    };

    my $host = $conf->{'smtpd_listen_on_address'} || 'localhost';
       $host = "localhost" if ( $host =~ /system|qmail|all/i );

    my $smtp = Net::SMTP_auth->new($host);
    $log->test( "connect to smtp port on $host", $smtp );
    return 0 if ! defined $smtp;

    my @auths = $smtp->auth_types();
    $log->test( "  get list of SMTP AUTH methods", scalar @auths);
    $smtp->quit;

    $self->smtp_test_auth_pass($host, \@auths);
    $self->smtp_test_auth_fail($host, \@auths);
};

sub smtp_test_auth_pass {
    my $self = shift;
    my $host = shift;
    my $auths = shift or die "invalid params\n";

    my $user = $conf->{'toaster_test_email'}      || 'test2@example.com';
    my $pass = $conf->{'toaster_test_email_pass'} || 'cHanGeMe';

    # test each authentication method the server advertises
    foreach (@$auths) {

        my $smtp = Net::SMTP_auth->new($host);
        my $r = $smtp->auth( $_, $user, $pass );
        $log->test( "  authentication with $_", $r );
        next if ! $r;

        $smtp->mail( $conf->{'toaster_admin_email'} );
        $smtp->to('postmaster');
        $smtp->data();
        $smtp->datasend("To: postmaster\n");
        $smtp->datasend("\n");
        $smtp->datasend("A simple test message\n");
        $smtp->dataend();

        $smtp->quit;
        $log->test("  sending after auth $_", 1 );
    }
}

sub smtp_test_auth_fail {
    my $self = shift;
    my $host = shift;
    my $auths = shift or die "invalid params\n";

    my $user = 'non-exist@example.com';
    my $pass = 'non-password';

    foreach (@$auths) {
        my $smtp = Net::SMTP_auth->new($host);
        my $r = $smtp->auth( $_, $user, $pass );
        $log->test( "  failed authentication with $_", ! $r );
        $smtp->quit;
    }
}

sub socklog {

    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'ip'    => { type => SCALAR, },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => $debug },
        },
    );

    my $ip    = $p{'ip'};
    my $fatal = $p{'fatal'};
       $debug = $p{'debug'};

    my $user  = $conf->{'qmail_log_user'}  || "qmaill";
    my $group = $conf->{'qmail_log_group'} || "qnofiles";

    my $uid = getpwnam($user);
    my $gid = getgrnam($group);

    my $log = $conf->{'qmail_log_base'};
    unless ( -d $log ) { $log = "/var/log/mail" }

    if ( $OSNAME eq "freebsd" ) {
        $freebsd->install_port( "socklog" );
    }
    else {
        print "\n\nNOTICE: Be sure to install socklog!!\n\n";
    }
    socklog_qmail_control( "send", $ip, $user, undef, $log );
    socklog_qmail_control( "smtp", $ip, $user, undef, $log );
    socklog_qmail_control( "pop3", $ip, $user, undef, $log );

    unless ( -d $log ) {
        mkdir( $log, oct('0755') ) or croak "socklog: couldn't create $log: $!";
        chown( $uid, $gid, $log ) or croak "socklog: couldn't chown  $log: $!";
    }

    foreach my $prot (qw/ send smtp pop3 /) {
        unless ( -d "$log/$prot" ) {
            mkdir( "$log/$prot", oct('0755') )
              or croak "socklog: couldn't create $log/$prot: $!";
        }
        chown( $uid, $gid, "$log/$prot" )
          or croak "socklog: couldn't chown $log/$prot: $!";
    }
}

sub socklog_qmail_control {

    my ( $serv, $ip, $user, $supervise, $log, $debug ) = @_;

    $ip        ||= "192.168.2.9";
    $user      ||= "qmaill";
    $supervise ||= "/var/qmail/supervise";
    $log       ||= "/var/log/mail";

    my $run_f = "$supervise/$serv/log/run";

    if ( -s $run_f ) {
        print "socklog_qmail_control skipping: $run_f exists!\n";
        return 1;
    }

    print "socklog_qmail_control creating: $run_f...";
    my @socklog_run_file = <<EO_SOCKLOG;
#!/bin/sh
LOGDIR=$log
LOGSERVERIP=$ip
PORT=10116

PATH=/var/qmail/bin:/usr/local/bin:/usr/bin:/bin
export PATH

exec setuidgid $user multilog t s4096 n20 \
  !"tryto -pv tcpclient -v \$LOGSERVERIP \$PORT sh -c 'cat >&7'" \
  \${LOGDIR}/$serv
EO_SOCKLOG
    $util->file_write( $run_f, lines => \@socklog_run_file, debug=>$debug );

#	open(my $RUN, ">", $run_f) or croak "socklog_qmail_control: couldn't open for write: $!";
#	close $RUN;
    chmod oct('0755'), $run_f or croak "socklog: couldn't chmod $run_f: $!";
    print "done.\n";
}

sub spamassassin {
    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => $debug },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
       $debug = $p{'debug'};

    if ( !$conf->{'install_spamassassin'} ) {
        $log->audit( "spamassassin: installing, skipping (disabled)" );
        return;
    }

    return $p{test_ok} if defined $p{test_ok};

    if ( $OSNAME eq "freebsd" ) {
        $self->spamassassin_freebsd();
    }
    elsif ( $OSNAME eq "darwin" ) {
        $darwin->install_port( "procmail" ) 
            if $conf->{'install_procmail'};
        $darwin->install_port( "unzip" );
        $darwin->install_port( "p5-mail-audit" );
        $darwin->install_port( "p5-mail-spamassassin" );
        $darwin->install_port( "bogofilter" ) if $conf->{'install_bogofilter'};
    }

    $util->install_module( "Time::HiRes", debug=>$debug, );
    $util->install_module( "Mail::Audit", debug=>$debug, );
    $util->install_module( "Mail::SpamAssassin", debug=>$debug );
    $self->maildrop(  debug=>$debug );

    $self->spamassassin_sql(  debug=>$debug ) if ( $conf->{'install_spamassassin_sql'} );
}

sub spamassassin_freebsd {
    my $self = shift;

    my $mysql = "WITHOUT_MYSQL=true";
    if ( $conf->{install_spamassassin_sql} ) {
        $mysql = "WITH_MYSQL=true";
    };

    $freebsd->install_port( "p5-Mail-SPF" );
    $freebsd->install_port( "p5-Mail-SpamAssassin",
        category => 'mail',
        flags => "WITHOUT_SSL=1 BATCH=yes",
        options => "# This file is generated by Mail::Toaster
# Options for p5-Mail-SpamAssassin-3.2.5_2
_OPTIONS_READ=p5-Mail-SpamAssassin-3.2.5_2
WITH_AS_ROOT=true
WITH_SPAMC=true
WITHOUT_SACOMPILE=true
WITH_DKIM=true
WITHOUT_SSL=true
WITHOUT_GNUPG=true 
$mysql  
WITHOUT_PGSQL=true
WITH_RAZOR=true
WITH_SPF_QUERY=true
WITH_RELAY_COUNTRY=true",
        debug => 0,
    );

    # the old port didn't install the spamd.sh file
    # new versions install sa-spamd.sh and require the rc.conf flag
    my $start = -f "/usr/local/etc/rc.d/spamd.sh" ? "/usr/local/etc/rc.d/spamd.sh"
                : -f "/usr/local/etc/rc.d/spamd"    ? "/usr/local/etc/rc.d/spamd"
                : "/usr/local/etc/rc.d/sa-spamd";   # current location, 9/23/06

    my $flags = $conf->{'install_spamassassin_flags'};

    $freebsd->conf_check(
        check => "spamd_enable",
        line  => 'spamd_enable="YES"',
        debug => 0,
    );

    $freebsd->conf_check(
        check => "spamd_flags",
        line  => qq{spamd_flags="$flags"},
        debug => 0,
    );
    
    $self->spamassassin_update();

    unless ( $util->is_process_running("spamd") ) {
        if ( -x $start ) {
            print "Starting SpamAssassin...";
            $util->syscmd( "$start restart", debug=>0 );
            print "done.\n";
        }
        else { print "WARN: couldn't start SpamAssassin's spamd.\n"; }
    }
};

sub spamassassin_sql {

    # set up the mysql database for use with SpamAssassin
    # http://svn.apache.org/repos/asf/spamassassin/branches/3.0/sql/README

    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => $debug },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
       $debug = $p{'debug'};

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    if ( ! $conf->{'install_spamassassin_sql'} ) {
        print "SpamAssasin MySQL integration not selected. skipping.\n";
        return 0;
    }

    if ( $OSNAME eq "freebsd" ) {

        # is SpamAssassin installed?
        if ( ! $freebsd->is_port_installed( "p5-Mail-SpamAssassin", debug=>$debug ) ) {
            print "SpamAssassin is not installed, skipping database setup.\n";
            return;
        }

        # have we been here already?
        if ( -f "/usr/local/etc/mail/spamassassin/sql.cf" ) {
            print "SpamAssassing database setup already done...skipping.\n";
            return 1;
        };

        print "SpamAssassin is installed, setting up MySQL databases\n";

        my $user = $conf->{'install_spamassassin_dbuser'};
        my $pass = $conf->{'install_spamassassin_dbpass'};

        require Mail::Toaster::Mysql;
        my $mysql = Mail::Toaster::Mysql->new( toaster => $toaster );

        my $dot = $mysql->parse_dot_file( ".my.cnf", "[mysql]", 0 );
        my ( $dbh, $dsn, $drh ) = $mysql->connect( $dot, 1 );

        if ($dbh) {
            my $query = "use spamassassin";
            my $sth = $mysql->query( $dbh, $query, 1 );
            if ( $sth->errstr ) {
                print "vpopmail: oops, no spamassassin database.\n";
                print "vpopmail: creating MySQL spamassassin database.\n";
                $query = "CREATE DATABASE spamassassin";
                $sth   = $mysql->query( $dbh, $query );
                $query =
"GRANT ALL PRIVILEGES ON spamassassin.* TO $user\@'localhost' IDENTIFIED BY '$pass'";
                $sth = $mysql->query( $dbh, $query );
                $sth = $mysql->query( $dbh, "flush privileges" );
                $sth->finish;
            }
            else {
                print "spamassassin: spamassassin database exists!\n";
                $sth->finish;
            }
        }

        my $mysqlbin = $util->find_bin( "mysql", fatal => 0, debug=>$debug );
        my $sqldir = "/usr/local/share/doc/p5-Mail-SpamAssassin/sql";
        foreach (qw/bayes_mysql.sql awl_mysql.sql userpref_mysql.sql/) {
            $util->syscmd( "$mysqlbin spamassassin < $sqldir/$_", debug=>$debug )
              if ( -f "$sqldir/$_" );
        }

        my $file = "/usr/local/etc/mail/spamassassin/sql.cf";
        unless ( -f $file ) {
            my @lines = <<EO_SQL_CF;
user_scores_dsn                 DBI:mysql:spamassassin:localhost
user_scores_sql_username        $conf->{'install_spamassassin_dbuser'}
user_scores_sql_password        $conf->{'install_spamassassin_dbpass'}
#user_scores_sql_table           userpref

bayes_store_module              Mail::SpamAssassin::BayesStore::SQL
bayes_sql_dsn                   DBI:mysql:spamassassin:localhost
bayes_sql_username              $conf->{'install_spamassassin_dbuser'}
bayes_sql_password              $conf->{'install_spamassassin_dbpass'}
#bayes_sql_override_username    someusername

auto_whitelist_factory          Mail::SpamAssassin::SQLBasedAddrList
user_awl_dsn                    DBI:mysql:spamassassin:localhost
user_awl_sql_username           $conf->{'install_spamassassin_dbuser'}
user_awl_sql_password           $conf->{'install_spamassassin_dbpass'}
user_awl_sql_table              awl
EO_SQL_CF
            $util->file_write( $file, lines => \@lines );
        }
    }
    else {
        print
"Sorry, automatic MySQL SpamAssassin setup is not available on $OSNAME yet. You must
do this process manually by locating the *_mysql.sql files that arrived with SpamAssassin. Run
each one like this:
	mysql spamassassin < awl_mysql.sql
	mysql spamassassin < bayes_mysql.sql
	mysql spamassassin < userpref_mysql.sql

Then configure SpamAssassin to use them by creating a sql.cf file in SpamAssassin's etc dir with
the following contents:

	user_scores_dsn                 DBI:mysql:spamassassin:localhost
	user_scores_sql_username        $conf->{'install_spamassassin_dbuser'}
	user_scores_sql_password        $conf->{'install_spamassassin_dbpass'}

	# default query
	#SELECT preference, value FROM _TABLE_ WHERE username = _USERNAME_ OR username = '\@GLOBAL' ORDER BY username ASC
	# global, then domain level
	#SELECT preference, value FROM _TABLE_ WHERE username = _USERNAME_ OR username = '\@GLOBAL' OR username = '@~'||_DOMAIN_ ORDER BY username ASC
	# global overrides user prefs
	#SELECT preference, value FROM _TABLE_ WHERE username = _USERNAME_ OR username = '\@GLOBAL' ORDER BY username DESC
	# from the SA SQL README
	#user_scores_sql_custom_query     SELECT preference, value FROM _TABLE_ WHERE username = _USERNAME_ OR username = '\$GLOBAL' OR username = CONCAT('%',_DOMAIN_) ORDER BY username ASC

	bayes_store_module              Mail::SpamAssassin::BayesStore::SQL
	bayes_sql_dsn                   DBI:mysql:spamassassin:localhost
	bayes_sql_username              $conf->{'install_spamassassin_dbuser'}
	bayes_sql_password              $conf->{'install_spamassassin_dbpass'}
	#bayes_sql_override_username    someusername

	auto_whitelist_factory       Mail::SpamAssassin::SQLBasedAddrList
	user_awl_dsn                 DBI:mysql:spamassassin:localhost
	user_awl_sql_username        $conf->{'install_spamassassin_dbuser'}
	user_awl_sql_password        $conf->{'install_spamassassin_dbpass'}
	user_awl_sql_table           awl
";
    }
}

sub spamassassin_update {
    my $self = shift;

    my $update = $util->find_bin( "sa-update", fatal => 0 ) or return;
    system $update and do {
        $log->error( "error updating spamassassin rules", fatal => 0);
    };
    $log->audit( "trying again without GPG" );

    system "$update --nogpg" and 
        return $log->error( "error updating spamassassin rules", fatal => 0);

    return 1;
};

sub squirrelmail {
    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => $debug },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
       $debug = $p{'debug'};

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    my $ver = $conf->{'install_squirrelmail'}
        or return $log->error( "skipping squirrelmail install. it's not enabled.",fatal=>0);

    if ( $OSNAME eq "freebsd" && $ver eq "port" ) {
        $self->php();
        $self->squirrelmail_freebsd() and return;
    };

    $ver = "1.4.6" if $ver eq 'port';

    print "squirrelmail: attempting to install from sources.\n";

    my $htdocs = $conf->{'toaster_http_docs'} || "/usr/local/www/data";
    my $srcdir = $conf->{'toaster_src_dir'}   || "/usr/local/src";
    $srcdir .= "/mail";

    unless ( -d $htdocs ) {
        $htdocs = "/var/www/data" if ( -d "/var/www/data" );    # linux
        $htdocs = "/Library/Webserver/Documents"
          if ( -d "/Library/Webserver/Documents" );             # OS X
    }

    if ( -d "$htdocs/squirrelmail" ) {
        print "Squirrelmail is already installed, I won't install it again!\n";
        return 0;
    }

    $util->install_from_source(
        package        => "squirrelmail-$ver",
        site           => "http://" . $conf->{'toaster_sf_mirror'},
        url            => "/squirrelmail",
        targets        => ["mv $srcdir/squirrelmail-$ver $htdocs/squirrelmail"],
        source_sub_dir => 'mail',
    );

    $self->squirrelmail_config();
    $self->squirrelmail_mysql();
}

sub squirrelmail_freebsd {
    my $self = shift;

    my @squirrel_flags;
    push @squirrel_flags, 'WITH_APACHE2=1' if ( $conf->{'install_apache'} == 2 );
    push @squirrel_flags, 'WITH_DATABASE=1' if $conf->{'install_squirrelmail_sql'};

    $freebsd->install_port( "squirrelmail", 
        flags => join(',', @squirrel_flags), 
    );
    $freebsd->install_port( "squirrelmail-quota_usage-plugin" );

    return if ! $freebsd->is_port_installed( "squirrelmail" );
    my $sqdir = "/usr/local/www/squirrelmail";
    return if ! -d $sqdir;

    $self->squirrelmail_config();
    $self->squirrelmail_mysql() if $conf->{'install_squirrelmail_sql'};

    return 1;
}

sub squirrelmail_mysql {
    my $self  = shift;

    return if ! $conf->{'install_squirrelmail_sql'};

    if ( $OSNAME eq "freebsd" ) {
        $freebsd->install_port( "pear-DB" );

        print
'\nHEY!  You need to add include_path = ".:/usr/local/share/pear" to php.ini.\n\n';

        $freebsd->install_port( "squirrelmail-sasql-plugin" );
    }

    my $db   = "squirrelmail";
    my $user = "squirrel";
    my $pass = $conf->{'install_squirrelmail_sql_pass'} || "secret";
    my $host = "localhost";

    require Mail::Toaster::Mysql;
    my $mysql = Mail::Toaster::Mysql->new( toaster => $toaster );

    my $dot = $mysql->parse_dot_file( ".my.cnf", "[mysql]", 0 );
    my ( $dbh, $dsn, $drh ) = $mysql->connect( $dot, 1 );

    if ($dbh) {
        my $query = "use squirrelmail";
        my $sth   = $mysql->query( $dbh, $query, 1 );

        if ( !$sth->errstr ) {
            print "squirrelmail: squirrelmail database already exists.\n";
            $sth->finish;
            return 1;
        }

        print "squirrelmail: creating MySQL database for squirrelmail.\n";
        $query = "CREATE DATABASE squirrelmail";
        $sth   = $mysql->query( $dbh, $query );

        $query =
"GRANT ALL PRIVILEGES ON $db.* TO $user\@'$host' IDENTIFIED BY '$pass'";
        $sth = $mysql->query( $dbh, $query );

        $query =
"CREATE TABLE squirrelmail.address ( owner varchar(128) DEFAULT '' NOT NULL,
nickname varchar(16) DEFAULT '' NOT NULL, firstname varchar(128) DEFAULT '' NOT NULL,
lastname varchar(128) DEFAULT '' NOT NULL, email varchar(128) DEFAULT '' NOT NULL,
label varchar(255), PRIMARY KEY (owner,nickname), KEY firstname (firstname,lastname));
";
        $sth = $mysql->query( $dbh, $query );

        $query =
"CREATE TABLE squirrelmail.global_abook ( owner varchar(128) DEFAULT '' NOT NULL, nickname varchar(16) DEFAULT '' NOT NULL, firstname varchar(128) DEFAULT '' NOT NULL,
lastname varchar(128) DEFAULT '' NOT NULL, email varchar(128) DEFAULT '' NOT NULL,
label varchar(255), PRIMARY KEY (owner,nickname), KEY firstname (firstname,lastname));";

        $sth = $mysql->query( $dbh, $query );

        $query =
"CREATE TABLE squirrelmail.userprefs ( user varchar(128) DEFAULT '' NOT NULL, prefkey varchar(64) DEFAULT '' NOT NULL, prefval BLOB DEFAULT '' NOT NULL, PRIMARY KEY (user,prefkey))";
        $sth = $mysql->query( $dbh, $query );

        $sth->finish;
        return 1;
    }

    print "

WARNING: I could not connect to your database server!  If this is a new install, 
you will need to connect to your database server and run this command manually:

mysql -u root -h $host -p
CREATE DATABASE squirrelmail;
GRANT ALL PRIVILEGES ON $db.* TO $user\@'$host' IDENTIFIED BY '$pass';
CREATE TABLE squirrelmail.address (
owner varchar(128) DEFAULT '' NOT NULL,
nickname varchar(16) DEFAULT '' NOT NULL,
firstname varchar(128) DEFAULT '' NOT NULL,
lastname varchar(128) DEFAULT '' NOT NULL,
email varchar(128) DEFAULT '' NOT NULL,
label varchar(255),
PRIMARY KEY (owner,nickname),
KEY firstname (firstname,lastname)
);
CREATE TABLE squirrelmail.global_abook (
owner varchar(128) DEFAULT '' NOT NULL,
nickname varchar(16) DEFAULT '' NOT NULL,
firstname varchar(128) DEFAULT '' NOT NULL,
lastname varchar(128) DEFAULT '' NOT NULL,
email varchar(128) DEFAULT '' NOT NULL,
label varchar(255),
PRIMARY KEY (owner,nickname),
KEY firstname (firstname,lastname)
);
CREATE TABLE squirrelmail.userprefs (
user varchar(128) DEFAULT '' NOT NULL,
prefkey varchar(64) DEFAULT '' NOT NULL,
prefval BLOB DEFAULT '' NOT NULL,
PRIMARY KEY (user,prefkey)
);
quit;

If this is an upgrade, you can probably ignore this warning.

";
}

sub squirrelmail_config {
    my $self  = shift;

    my $sqdir = "/usr/local/www/squirrelmail";
    return 1 if -e "$sqdir/config/config.php";

    chdir("$sqdir/config");
    print "squirrelmail: installing a default config.php\n";

    copy('config_default.php', 'config.php');

    my $mailhost = $conf->{'toaster_hostname'};
    my $dsn      = '';

    if ( $conf->{'install_squirrelmail_sql'} ) {
        my $pass = $conf->{install_squirrelmail_sql_pass} || 's3kret';
        $dsn = "mysql://squirrel:$pass\@localhost/squirrelmail";
    }

    my $string = <<"EOCONFIG";
\$signout_page  = 'https://$mailhost/';
\$provider_name     = 'Powered by Mail::Toaster';
\$provider_uri     = 'http://www.tnpi.net/wiki/Mail_Toaster';
\$domain                 = '$mailhost';
\$useSendmail            = true;
\$imap_server_type       = 'courier';
\$addrbook_dsn = '$dsn';
\$prefs_dsn = '$dsn';
?>
EOCONFIG
      ;

    $util->file_write( "config_local.php", lines => [ $string ] );
}

sub sqwebmail {

    my $self  = shift;
    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1 },
            'debug' => { type => BOOLEAN, optional => 1 },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $debug = $self->set_debug( $p{debug} );
    my $fatal = $self->set_fatal( $p{fatal} );

    my $ver = $conf->{'install_sqwebmail'};
    if ( ! $ver ) {
        print "Sqwebmail installation is disabled!\n";
        return;
    }

    my $httpdir = $conf->{'toaster_http_base'} || "/usr/local/www";
    my $cgi     = $conf->{'toaster_cgi_bin'};
    my $prefix  = $conf->{'toaster_prefix'} || "/usr/local";

    unless ( $cgi && -d $cgi ) { $cgi = "$httpdir/cgi-bin" }

    my $datadir = $conf->{'toaster_http_docs'};
    unless ( -d $datadir ) {
        if    ( -d "$httpdir/data/mail" ) { $datadir = "$httpdir/data/mail"; }
        elsif ( -d "$httpdir/mail" )      { $datadir = "$httpdir/mail"; }
        else { $datadir = "$httpdir/data"; }
    }

    my $mime = -e "$prefix/etc/apache2/mime.types"  ? "$prefix/etc/apache2/mime.types"
             : -e "$prefix/etc/apache22/mime.types" ? "$prefix/etc/apache22/mime.types"
             : "$prefix/etc/apache/mime.types";

    my $cachedir = "/var/run/sqwebmail";

    if ( $OSNAME eq "freebsd" && $ver eq "port" ) {
        return $self->sqwebmail_freebsd_port();
    };

    $ver = "5.3.1" if $ver eq "port";

    if ( -x "$prefix/libexec/sqwebmail/sqwebmaild" ) {
        if ( !$util->yes_or_no(
                "Sqwebmail is already installed, re-install it?",
                timeout  => 300
            )
          )
        {
            print "ok, skipping.\n";
            return;
        }
    }

    my $package = "sqwebmail-$ver";
    my $site    = "http://" . $conf->{'toaster_sf_mirror'} . "/courier";
    my $src     = $conf->{'toaster_src_dir'} || "/usr/local/src";

    $util->cwd_source_dir( "$src/mail" );

    if ( -d "$package" ) {
        unless ( $util->source_warning( $package, 1, $src ) ) {
            carp "sqwebmail: OK, skipping sqwebmail.\n";
            return;
        }
    }

    unless ( -e "$package.tar.bz2" ) {
        $util->get_url( "$site/$package.tar.bz2" );
        unless ( -e "$package.tar.bz2" ) {
            croak "sqwebmail FAILED: coudn't fetch $package\n";
        }
    }

    $util->extract_archive( "$package.tar.bz2" );

    chdir($package) or croak "sqwebmail FAILED: coudn't chdir $package\n";

    my $cmd = "./configure --prefix=$prefix --with-htmldir=$prefix/share/sqwebmail "
        . "--with-cachedir=/var/run/sqwebmail --enable-webpass=vpopmail "
        . "--with-module=authvchkpw --enable-https --enable-logincache "
        . "--enable-imagedir=$datadir/webmail --without-authdaemon "
        . "--enable-mimetypes=$mime --enable-cgibindir=" . $cgi;

    if ( $OSNAME eq "darwin" ) { $cmd .= " --with-cacheowner=daemon"; };

    my $make  = $util->find_bin("gmake", fatal=>0, debug=>0);
    $make   ||= $util->find_bin("make", fatal=>0, debug=>0);

    $util->syscmd( $cmd, debug=>$debug );
    $util->syscmd( "$make configure-check", debug=>$debug );
    $util->syscmd( "$make check", debug=>$debug );
    $util->syscmd( "$make", debug=>$debug );

    my $share = "$prefix/share/sqwebmail";
    if ( -d $share ) {
        $util->syscmd( "make install-exec", debug=>$debug );
        print
          "\n\nWARNING: I have only installed the $package binaries, thus\n";
        print "preserving any custom settings you might have in $share.\n";
        print
          "If you wish to do a full install, overwriting any customizations\n";
        print "you might have, then do this:\n\n";
        print "\tcd $src/mail/$package; make install\n";
    }
    else {
        $util->syscmd( "$make install", debug=>$debug );
        chmod oct('0755'), $share;
        chmod oct('0755'), "$datadir/sqwebmail";
        copy( "$share/ldapaddressbook.dist", "$share/ldapaddressbook" )
          or croak "copy failed: $!";
    }

    $util->syscmd( "$make install-configure", debug=>$debug, fatal => 0 );

    $self->sqwebmail_conf(  debug=>$debug );
}

sub sqwebmail_conf {

    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate(@_, {
            'debug' => {type=>SCALAR, optional=>1, default=>$debug },
        },
    );

    $debug = $p{'debug'};

    my $cachedir = "/var/run/sqwebmail";
    my $prefix   = $conf->{'toaster_prefix'} || "/usr/local";

    unless ( -e $cachedir ) {
        my $uid = getpwnam("bin");
        my $gid = getgrnam("bin");
        mkdir( $cachedir, oct('0755') );
        chown( $uid, $gid, $cachedir );
    }

    my $file = "/usr/local/etc/sqwebmail/sqwebmaild";
    return if ! -w $file;

    my @lines = $util->file_read( $file );
    foreach my $line (@lines) { #
        if ( $line =~ /^[#]{0,1}PIDFILE/ ) {
            $line = "PIDFILE=$cachedir/sqwebmaild.pid";
        };
    };
    $util->file_write( $file, lines=>\@lines );
}

sub sqwebmail_freebsd_port {
    my $self = shift;

    $self->gnupg_install();
    $self->courier_authlib();

    my $debug   = $self->set_debug();
    my $cgi     = $conf->{'toaster_cgi_bin'};
    my $datadir = $conf->{'toaster_http_docs'};
    my $cachedir = "/var/run/sqwebmail";

    if ( $cgi     =~ /\/usr\/local\/(.*)$/ ) { $cgi     = $1; }
    if ( $datadir =~ /\/usr\/local\/(.*)$/ ) { $datadir = $1; }

    my @args = "WITHOUT_AUTHDAEMON=yes";
    push @args, "CGIBINDIR=$cgi";
    push @args, "CGIBINSUBDIR=''";
    push @args, "WEBDATADIR=$datadir";
    push @args, "CACHEDIR=$cachedir";

    $freebsd->install_port( "sqwebmail",
        flags => join( ",", @args ),
        options => "# This file is generated by Mail::Toaster
# Options for sqwebmail-5.4.1
_OPTIONS_READ=sqwebmail-5.4.1
WITH_CACHEDIR=true
WITHOUT_FAM=true
WITHOUT_GDBM=true
WITH_GZIP=true
WITH_HTTPS=true
WITHOUT_HTTPS_LOGIN=true
WITH_ISPELL=true
WITH_MIMETYPES=true
WITHOUT_SENTRENAME=true
WITHOUT_CHARSET=true
WITHOUT_AUTH_LDAP=true
WITHOUT_AUTH_MYSQL=true
WITHOUT_AUTH_PGSQL=true
WITHOUT_AUTH_USERDB=true
WITH_AUTH_VCHKPW=true",
        );

    $freebsd->conf_check(
        check => "sqwebmaild_enable",
        line  => 'sqwebmaild_enable="YES"',
        debug => $debug,
    );

    $self->sqwebmail_conf();

    print "sqwebmail: starting sqwebmaild.\n";
    my $prefix = $conf->{'toaster_prefix'} || "/usr/local";
    my $start  = "$prefix/etc/rc.d/sqwebmail-sqwebmaild";

        -x $start      ? $util->syscmd( "$start start", debug=>$debug )
    : -x "$start.sh" ? $util->syscmd( "$start.sh start", debug=>$debug )
    : carp "could not find the startup file for sqwebmaild!\n";

    $freebsd->is_port_installed( "sqwebmail", debug=>$debug );
}

sub stunnel_freebsd {

    return if $freebsd->is_port_installed( "stunnel" );

    $freebsd->install_port( "stunnel", 
        options => "#
# This file was generated by mail-toaster\n
# Options for stunnel-4.15\n_OPTIONS_READ=stunnel-4.15\nWITH_PTHREAD=true\nWITHOUT_IPV6=true\n",
    );
};

sub supervise {
    my $self  = shift;
    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => $self->{debug} },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    return $p{test_ok} if defined $p{test_ok};

    my $supervise = $conf->{'qmail_supervise'} || "/var/qmail/supervise";
    my $prefix    = $conf->{'toaster_prefix'}  || "/usr/local";

    require Mail::Toaster::Qmail;
    $qmail ||= Mail::Toaster::Qmail->new();

    $toaster->service_dir_create();
    $toaster->supervise_dirs_create();

    $qmail->control_create();
    $qmail->install_qmail_control_files();
    $qmail->install_qmail_control_log_files();

    $self->startup_script();
    $toaster->service_symlinks();
    $qmail->config();

    my $start = "$prefix/sbin/services";
    $start = "$prefix/bin/services" if ! -x $start;
    print "\a";

    print "\n\nStarting up services (Ctrl-C to cancel). 

If there's any problems, you can stop all supervised services by running:\n
          $start stop\n
\n\nStarting in 5 seconds: ";
    foreach ( 1 .. 5 ) { print "."; sleep 1; };
    print "\n";

    system "$start start";
}

sub startup_script {
    my $self  = shift;
    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => $self->{debug} },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
    my $debug = $p{'debug'};

    my $dl_site = $conf->{'toaster_dl_site'} || "http://www.tnpi.net";
    my $dl_url = "$dl_site/internet/mail/toaster";

    # make sure the service dir is set up
    return $log->error( "the service directories don't appear to be set up. I refuse to start them until this is fixed.") unless $toaster->service_dir_test( debug => $debug );

    return $p{test_ok} if defined $p{test_ok};

    return $self->startup_script_freebsd() if $OSNAME eq "freebsd";
    return $self->startup_script_darwin()  if $OSNAME eq "darwin";

    $log->error( "There is no startup script support written for $OSNAME. If you know the proper method of doing so, please have a look at $dl_url/start/services.txt, adapt it to $OSNAME, and send it to matt\@tnpi.net." );
};

sub startup_script_darwin {
    my $self = shift;

    my $start = "/Library/LaunchDaemons/to.yp.cr.daemontools-svscan.plist";
    my $dl_site = $conf->{'toaster_dl_site'} || "http://www.tnpi.net";
    my $dl_url = "$dl_site/internet/mail/toaster";

    unless ( -e $start ) {
        $util->get_url( "$dl_url/start/to.yp.cr.daemontools-svscan.plist" );
        my $r = $util->install_if_changed(
            newfile  => "to.yp.cr.daemontools-svscan.plist",
            existing => $start,
            mode     => '0551',
            clean    => 1,
        ) or return;
        $r == 1 ? $r = "ok" : $r = "ok (current)";
        $log->audit( "startup_script: updating $start, $r" );
    }

    my $prefix = $conf->{'toaster_prefix'} || "/usr/local";
    $start = "$prefix/sbin/services";

    if ( -w $start ) {
        $util->get_url( "$dl_url/start/services-darwin.txt" );

        my $r = $util->install_if_changed(
            newfile  => "services-darwin.txt",
            existing => $start,
            mode     => '0551',
            clean    => 1,
        ) or return;

        $r == 1 ? $r = "ok" : $r = "ok (current)";

        $log->audit( "startup_script: updating $start, $r" );
    }
};

sub startup_script_freebsd { 
    my $self = shift;

    # The FreeBSD port for daemontools includes rc.d/svscan so we use it
    my $confdir = $conf->{'system_config_dir'} || "/usr/local/etc";
    my $start = "$confdir/rc.d/svscan";

    unless ( -f $start ) {
        print "WARNING: no svscan, is daemontools installed?\n";
        print "\n\nInstalling a generic startup file....";

        my $dl_site = $conf->{'toaster_dl_site'} || "http://www.tnpi.net";
        my $dl_url = "$dl_site/internet/mail/toaster";
        $util->get_url( "$dl_url/start/services.txt" );
        my $r = $util->install_if_changed(
            newfile  => "services.txt",
            existing => $start,
            mode     => '0751',
            clean    => 1,
        ) or return;

        $r == 1 ? $r = "ok" : $r = "ok (current)";

        $log->audit( "startup_script: updating $start, $r" );
    }

    $freebsd->conf_check(
        check => "svscan_enable",
        line  => 'svscan_enable="YES"',
    );

    # if the qmail start file is installed, nuke it
    unlink "$confdir/rc.d/qmail.sh" if -e "$confdir/rc.d/qmail";
    unlink "$confdir/rc.d/qmail.sh" if -e "$confdir/rc.d/qmail.sh";

    my $prefix = $conf->{'toaster_prefix'} || "/usr/local";
    my $sym = "$prefix/sbin/services";
    return 1 if ( -l $sym && -x $sym ); # already exists

    unlink $sym
        or return $log->error( "Please [re]move '$sym' and run again.",fatal=>0) if -e $sym;

    symlink( $start, $sym );
    $log->audit( "startup_script: added $sym as symlink to $start");
};

sub test {
    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => $debug },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
       $debug = $p{'debug'};

    print "testing...\n";

    $self->test_qmail(  debug=>$debug );
    sleep 1;
    $self->daemontools_test( $debug);
    sleep 1;
    $self->ucspi_test( $debug );
    sleep 1;

    require Mail::Toaster::Qmail;
    $qmail ||= Mail::Toaster::Qmail->new();

    $self->test_supervised_procs( $debug );
    sleep 1;
    $self->test_logging( debug=>$debug );
    sleep 1;
    $self->vpopmail_test( debug=>$debug );
    sleep 1;

    $toaster->check_processes( debug=>$debug );
    sleep 1;
    $self->test_network();
    sleep 1;
    $self->test_crons( debug=>$debug );
    sleep 1;

    $qmail->check_rcpthosts();
    sleep 1;

    if ( ! $util->yes_or_no( "skip the mail scanner tests?", timeout  => 10 ) ) {
        $self->filtering_test();
    };
    sleep 1;
    
    if ( ! $util->yes_or_no( "skip the authentication tests?", timeout  => 10) ) {
        $self->test_auth( debug=>$debug );
    };

    # there's plenty more room here for more tests.

    # test DNS!
    # make sure primary IP is not reserved IP space
    # test reverse address for this machines IP
    # test resulting hostname and make sure it matches
    # make sure server's domain name has NS records
    # test MX records for server name
    # test for SPF records for server name

    # test for low disk space on /, qmail, and vpopmail partitions

    print "\ntesting complete.\n";
}

sub test_auth {

    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            fatal => { type => BOOLEAN, optional => 1, default => 1 },
            debug => { type => BOOLEAN, optional => 1, default => $debug },
            test_ok => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{fatal};
       $debug = $p{debug};

    my $email = $conf->{'toaster_test_email'};
    my $pass  = $conf->{'toaster_test_email_pass'};

    my $domain = ( split( '@', $email ) )[1];
    print "test_auth: testing domain is: $domain.\n";

    my $qmail_dir = $conf->{'qmail_dir'};

    unless ( -e "$qmail_dir/users/assign" 
             && grep {/$domain/} `cat $qmail_dir/users/assign` 
            ) {
        print "domain $domain is not set up.\n";
        return if ! $util->yes_or_no( "shall I add it for you?", timeout  => 30 );

        my $vpdir = $conf->{'vpopmail_home_dir'};
        system "$vpdir/bin/vadddomain $domain $pass";
        system "$vpdir/bin/vadduser $email $pass";
    }

    return if ! open my $ASSIGN, '<', "$qmail_dir/users/assign";
    return if ! grep {/:$domain:/} <$ASSIGN>;
    close $ASSIGN;

    if ( $OSNAME eq "freebsd" ) {
        $freebsd->install_port( "p5-Mail-POP3Client" );
        $freebsd->install_port( "p5-Mail-IMAPClient" );
        $freebsd->install_port( "p5-Net-SMTP_auth"   );
        $freebsd->install_port( "p5-IO-Socket-SSL"   );
    }

    $self->imap_test_auth( );    # test imap auth
    $self->pop3_test_auth( );    # test pop3 auth
    $self->smtp_test_auth( );    # test smtp auth

    print
"\n\nNOTICE: It is normal for some of the tests to fail. This test suite is useful for any mail server, not just a Mail::Toaster. \n\n";

    # webmail auth
    # other ?
}

sub test_crons {

    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => $debug },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
       $debug = $p{'debug'};

    my $tw = $util->find_bin( 'toaster-watcher.pl', debug => 0);
    my $vpopdir = $conf->{'vpopmail_home_dir'} || "/usr/local/vpopmail";

    my @crons = ( "$vpopdir/bin/clearopensmtp", $tw,);

    my $sqcache = "/usr/local/share/sqwebmail/cleancache.pl";
    push @crons, $sqcache if ( $conf->{'install_sqwebmail'} && -x $sqcache);

    print "checking cron processes\n";

    foreach (@crons) {
        $log->test("  $_", system( "$_" ) ? 0 : 1 );
    }
}

sub test_dns {

    print <<'EODNS'
People forget to even have DNS setup on their Toaster, as Matt has said before. If someone forgot to configure DNS, chances are, little or nothing will work -- from port fetching to timely mail delivery.

How about adding a simple DNS check to the Toaster Setup test suite? And in the meantime, you could give some sort of crude benchmark, depending on the circumstances of the test data.  I am not looking for something too hefty, but something small and sturdy to make sure there is a good DNS server around answering queries reasonably fast.

Here is a sample of some DNS lookups you could perform.  What I would envision is that there were around 20 to 100 forward and reverse lookups, and that the lookups were timed.  I guess you could look them up in parallel, and wait a maximum of around 15 seconds for all of the replies.  The interesting thing about a lot of reverse lookups is that they often fail because no one has published them.

Iteration 1: lookup A records.
Iteration 2: lookup NS records.
Iteration 3: lookup MX records.
Iteration 4: lookup TXT records.
Iteration 5: Repeat step 1, observe the faster response time due to caching.

Here's a sample output!  Wow.

#toaster_setup.pl -s dnstest
Would you like to enter a local domain so I can test it in detail?
testmydomain-local.net
Would you like to test domains with underscores in them? (y/n)n
Testing /etc/rc.conf for a hostname= line...
This box is known as smtp.testmydomain-local.net
Verifying /etc/hosts exists ... Okay
Verifying /etc/host.conf exists ... Okay
Verifying /etc/nsswitch.conf exists ... Okay
Doing reverse lookups in in-addr.arpa using default name service....
Doing forward A lookups using default name service....
Doing forward NS lookups using default name service....
Doing forward MX lookups using default name service....
Doing forward TXT lookups using default name service....
Results:
[Any errors, like...]
Listing Reverses Not found:
10.120.187.45 (normal)
169.254.89.123 (normal)
Listing A Records Not found:
example.impossible.nonexistent.bogus.co.nl (normal)
Listing TXT Records Not found:
Attempting to lookup the same A records again....  Hmmm. much faster!
Your DNS Server (or its forwarder) seems to be caching responses. (Good)

Checking local domain known as testmydomain-local.net
Checking to see if I can query the testmydomain-local.net NS servers and retrieve the entire DNS record...
ns1.testmydomain-local.net....yes.
ns256.backup-dns.com....yes.
ns13.ns-ns-ns.net...no.
Do DNS records agree on all DNS servers?  Yes. identical.
Skipping SOA match.

I have discovered that testmydomain-local.net has no MX records.  Shame on you, this is a mail server!  Please fix this issue and try again.

I have discovered that testmydomain-local.net has no TXT records.  You may need to consider an SPF v1 TXT record.

Here is a dump of your domain records I dug up for you:
xoxoxoxox

Does hostname agree with DNS?  Yes. (good).

Is this machine a CNAME for something else in DNS?  No.

Does this machine have any A records in DNS?  Yes.
smtp.testmydomain-local.net is 192.168.41.19.  This is a private IP.

Round-Robin A Records in DNS pointing to another machine/interface?
No.

Does this machine have any CNAME records in DNS?  Yes. aka
box1.testmydomain-local.net
pop.testmydomain-local.net
webmail.testmydomain-local.net

***************DNS Test Output complete

Sample Forwards:
The first few may be cached, and the last one should fail.  Some will have no MX server, some will have many.  (The second to last entry has an interesting mail exchanger and priority.)  Many of these will (hopefully) not be found in even a good sized DNS cache.

I have purposely listed a few more obscure entries to try to get the DNS server to do a full lookup.
localhost
<vpopmail_default_domain if set>
www.google.com
yahoo.com
nasa.gov
sony.co.jp
ctr.columbia.edu
time.nrc.ca
distancelearning.org
www.vatican.va
klipsch.com
simerson.net
warhammer.mcc.virginia.edu
example.net
foo.com
example.impossible.nonexistent.bogus.co.nl

[need some obscure ones that are probably always around, plus some non-US sample domains.]

Sample Reverses:
Most of these should be pretty much static.  Border routers, nics and such.  I was looking for a good range of IP's from different continents and providers.  Help needed in some networks.  I didn't try to include many that don't have a published reverse name, but many examples exist in case you want to purposely have some.
127.0.0.1
224.0.0.1
198.32.200.50	(the big daddy?!)
209.197.64.1
4.2.49.2
38.117.144.45
64.8.194.3
72.9.240.9
128.143.3.7
192.228.79.201
192.43.244.18
193.0.0.193
194.85.119.131
195.250.64.90
198.32.187.73
198.41.3.54
198.32.200.157
198.41.0.4
198.32.187.58
198.32.200.148
200.23.179.1
202.11.16.169
202.12.27.33
204.70.25.234
207.132.116.7
212.26.18.3
10.120.187.45
169.254.89.123

[Looking to fill in some of the 12s, 50s and 209s better.  Remove some 198s]

Just a little project.  I'm not sure how I could code it, but it is a little snippet I have been thinking about.  I figure that if you write the code once, it would be quite a handy little feature to try on a server you are new to.

Billy

EODNS
      ;
}

sub test_logging {

    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => $debug },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
       $debug = $p{'debug'};

    print "do the logging directories exist?\n";
    my $q_log = $conf->{'qmail_log_base'};
    foreach ( '', "pop3", "send", "smtp", "submit" ) {
        $log->test("  $q_log/$_", -d "$q_log/$_" );
    }

    print "checking log files?\n";
    my @active_log_files = ( "clean.log", "maildrop.log", "watcher.log",
                    "send/current",  "smtp/current",  "submit/current" );

    push @active_log_files, "pop3/current" if $conf->{'pop3_daemon'} eq "qpop3d";

    foreach ( @active_log_files ) {
        $log->test("  $_", -f "$q_log/$_" );
    }
}

sub test_network {

    return if $util->yes_or_no( "skip the network listener tests?",
            timeout  => 10,
        );

    my $netstat = $util->find_bin( "netstat", fatal => 0, debug=>0 );
    return unless ($netstat && -x $netstat);

    if ( $OSNAME eq "freebsd" ) { $netstat .= " -alS " }
    if ( $OSNAME eq "darwin" )  { $netstat .= " -al " }
    if ( $OSNAME eq "linux" )   { $netstat .= " -a --numeric-hosts " }
    #if ( $OSNAME eq "linux" )   { $netstat .= " -an " }
    else { $netstat .= " -a " }
    ;    # should be pretty safe

    print "checking for listening tcp ports\n";
    foreach (qw( smtp http pop3 imap https submission pop3s imaps )) {
        $log->test("  $_", `$netstat | grep $_ | grep -i listen` );
    }

    print "checking for udp listeners\n";
    my @udps;
    push @udps, "snmp" if $conf->{'install_snmp'};

    foreach ( @udps ) {
        $log->test("  $_", `$netstat | grep $_` );
    }
}

sub test_qmail {
    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => $debug },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
       $debug = $p{'debug'};

    my $qdir = $conf->{'qmail_dir'};
    print "does qmail's home directory exist?\n";
    $log->test("  $qdir", -d $qdir );

    print "checking qmail directory contents\n";
    my @tests = qw(alias boot control man users bin doc queue);
    push @tests, "configure" if ( $OSNAME eq "freebsd" );    # added by the port
    foreach (@tests) {
        $log->test("  $qdir/$_", -d "$qdir/$_" );
    }

    print "is the qmail rc file executable?\n";
    $log->test(  "  $qdir/rc", -x "$qdir/rc" );

    print "do the qmail users exist?\n";
    foreach (
        $conf->{'qmail_user_alias'}  || 'alias',  
        $conf->{'qmail_user_daemon'} || 'qmaild',
        $conf->{'qmail_user_passwd'} || 'qmailp',
        $conf->{'qmail_user_queue'}  || 'qmailq',
        $conf->{'qmail_user_remote'} || 'qmailr',
        $conf->{'qmail_user_send'}   || 'qmails',
        $conf->{'qmail_log_user'}    || 'qmaill', 
      )
    {
        $log->test("  $_", $self->user_exists($_) );
    }

    print "do the qmail groups exist?\n";
    foreach ( $conf->{'qmail_group'}     || 'qmail', 
              $conf->{'qmail_log_group'} || 'qnofiles', 
        ) {
        $log->test("  $_", getgrnam($_) );
    }

    print "do the qmail alias files have contents?\n";
    my $q_alias = "$qdir/alias/.qmail";
    foreach ( qw/ postmaster root mailer-daemon / ) {
        $log->test( "  $q_alias-$_", -s "$q_alias-$_" );
    }
}

sub test_supervised_procs {
    my $self = shift;
    my $debug = shift;

    print "do supervise directories exist?\n";
    my $q_sup = $conf->{'qmail_supervise'} || "/var/qmail/supervise";
    $log->test("  $q_sup", -d $q_sup);

    # check supervised directories
    foreach (qw/smtp send pop3 submit/) {
        $log->test( "  $q_sup/$_",
            $toaster->supervised_dir_test( prot => $_, debug=>1 ) );
    }

    print "do service directories exist?\n";
    my $q_ser = $conf->{'qmail_service'};

    require Mail::Toaster::Qmail;
    $qmail ||= Mail::Toaster::Qmail->new();

    my @active_service_dirs;
    foreach ( qw/ smtp send / ) {
        push @active_service_dirs, $toaster->service_dir_get( prot => $_ );
    }

    push @active_service_dirs, $toaster->service_dir_get( prot => "pop3" )
        if $conf->{'pop3_daemon'} eq "qpop3d";

    push @active_service_dirs, $toaster->service_dir_get( prot => "submit" )
        if $conf->{'submit_enable'};

    foreach ( $q_ser, @active_service_dirs ) {
        $log->test( "  $_", -d $_ );
    }

    print "are the supervised services running?\n";
    my $svok = $util->find_bin( "svok", fatal => 0 );
    foreach ( @active_service_dirs ) {
        $log->test( "  $_", system("$svok $_") ? 0 : 1 );
    }
};

sub ucspi_tcp {

    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => $debug },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
       $debug = $p{'debug'};

    # pre-declarations. We configure these for each platform and use them
    # at the end to build ucspi_tcp from source.

    my $patches = [];
    my @targets = ( 'make', 'make setup check' );

    if ( $conf->{install_mysql} && $conf->{'vpopmail_mysql'} ) {
        $patches = ["ucspi-tcp-0.88-mysql+rss.patch"];
    }

    if ( $OSNAME eq "freebsd" ) {
        # we install it from ports first so that it is registered in the ports
        # database. Otherwise, installing other ports in the future may overwrite
        # our customized version.
        $self->ucspi_tcp_freebsd();
    }
    elsif ( $OSNAME eq "darwin" ) {
        $patches = ["ucspi-tcp-0.88-mysql+rss-darwin.patch"];
        @targets = $self->ucspi_tcp_darwin();
    }
    elsif ( $OSNAME eq "linux" ) {
        @targets = (
            "echo gcc -O2 -include /usr/include/errno.h > conf-cc",
            "make", "make setup check"
        );

#		Need to test MySQL patch on linux before enabling it.
#		$patches = ['ucspi-tcp-0.88-mysql+rss.patch', 'ucspi-tcp-0.88.errno.patch'];
#		$patch_args = "-p0";
    }

    # see if it is installed
    my $tcpserver = $util->find_bin( "tcpserver", fatal => 0, debug=>0 );
    if ( -x $tcpserver ) {
        if ( ! $conf->{install_mysql} || !$conf->{'vpopmail_mysql'} ) {
            $log->audit( "ucspi-tcp: install, ok (exists)" );
            return 2; # we don't need mysql
        }
        my $strings = $util->find_bin( "strings", debug=>0 );
        if ( grep( /sql/, `$strings $tcpserver` ) ) {    
            $log->audit( "ucspi-tcp: mysql support check, ok (exists)" );
            return 1;
        }
        $log->audit( "ucspi-tcp is installed but w/o mysql support, " .
            "compiling from sources.");
    }

    # save having to download it again
    if ( -e "/usr/ports/distfiles/ucspi-tcp-0.88.tar.gz" ) {
        copy(
            "/usr/ports/distfiles/ucspi-tcp-0.88.tar.gz",
            "/usr/local/src/ucspi-tcp-0.88.tar.gz"
        );
    }

    $util->install_from_source(
        package   => "ucspi-tcp-0.88",
        patches   => $patches,
        patch_url => "$conf->{'toaster_dl_site'}$conf->{'toaster_dl_url'}/patches",
        site      => 'http://cr.yp.to',
        url       => '/ucspi-tcp',
        targets   => \@targets,
        debug     => $debug,
    );

    print "should be all done!\n";
    return $util->find_bin( "tcpserver", fatal => 0, debug => 0 ) ? 1 : 0;
}

sub ucspi_tcp_darwin {
    my $self = shift;

    my @targets = "echo '/opt/local' > conf-home";

    if ( $conf->{'vpopmail_mysql'} ) {
        my $mysql_prefix = "/opt/local";
        if ( !-d "$mysql_prefix/include/mysql" ) {
            if ( -d "/usr/include/mysql" ) {
                $mysql_prefix = "/usr";
            }
        }
        push @targets,
"echo 'gcc -s -I$mysql_prefix/include/mysql -L$mysql_prefix/lib/mysql -lmysqlclient' > conf-ld";
        push @targets,
            "echo 'gcc -O2 -I$mysql_prefix/include/mysql' > conf-cc";
    }

    push @targets, "make";
    push @targets, "make setup";
    return @targets;
};

sub ucspi_tcp_freebsd {
    return if $freebsd->is_port_installed( "ucspi-tcp" );

    $freebsd->install_port( "ucspi-tcp",
        flags => "BATCH=yes WITH_RSS_DIFF=1",
        options => "#\n# This file is auto-generated by 'make config'.
# No user-servicable parts inside!
# Options for ucspi-tcp-0.88_2
_OPTIONS_READ=ucspi-tcp-0.88_2
WITHOUT_MAN=true
WITH_RSS_DIFF=true
WITHOUT_SSL=true
WITHOUT_RBL2SMTPD=true\n",
    );
};

sub ucspi_test {

    my $self  = shift;
    my $debug = $self->{'debug'};

    print "checking ucspi-tcp binaries...\n";
    foreach (qw( tcprules tcpserver rblsmtpd tcpclient recordio )) {
        $log->test("  $_", -x $util->find_bin( $_, fatal => 0, debug=>0 ) );
    }

    my $tcpserver = $util->find_bin( "tcpserver", fatal => 0, debug=>$debug );

    if ( $conf->{'vpopmail_mysql'} ) {
        $log->test( "  tcpserver mysql support",
            `strings $tcpserver | grep sql`
        );
    }

    return 1;
}

sub user_add {
    my ($self, $user, $uid, $gid, %opts) = @_;

    return if ! $user;
    return if $self->user_exists($user);
        
    my $homedir = $opts{homedir};
    my $shell = $opts{shell} || '/sbin/nologin';

    my $cmd;
    if ( $OSNAME eq 'linux' ) {
        $cmd = $util->find_bin( 'useradd' );
        $cmd .= " -s $shell";
        $cmd .= " -d $homedir" if $homedir;
        $cmd .= " -u $uid" if $uid;
        $cmd .= " -g $gid" if $gid;
        $cmd .= " -m $user";
    }
    elsif ( $OSNAME eq 'freebsd' ) {
        $cmd = $util->find_bin( 'pw' );
        $cmd .= " useradd -n $user -s $shell";
        $cmd .= " -d $homedir" if $homedir;
        $cmd .= " -u $uid " if $uid;
        $cmd .= " -g $gid " if $gid;
        $cmd .= " -m -h-";
    }
    elsif ( $OSNAME eq 'darwin' ) {
        $cmd = $util->find_bin( 'dscl', fatal => 0 );
        my $path = "/users/$user";
        if ( $cmd ) {
            $util->syscmd( "$cmd . -create $path" );
            $util->syscmd( "$cmd . -createprop $path uid $uid");
            $util->syscmd( "$cmd . -createprop $path gid $gid");
            $util->syscmd( "$cmd . -createprop $path shell $shell" );
            $util->syscmd( "$cmd . -createprop $path home $homedir" ) if $homedir;
            $util->syscmd( "$cmd . -createprop $path passwd '*'" );
        }   
        else {
            $cmd = $util->find_bin( 'niutil' );
            $util->syscmd( "$cmd -createprop . $path uid $uid");
            $util->syscmd( "$cmd -createprop . $path gid $gid");
            $util->syscmd( "$cmd -createprop . $path shell $shell");
            $util->syscmd( "$cmd -createprop . $path home $homedir" ) if $homedir;
            $util->syscmd( "$cmd -createprop . $path _shadow_passwd");
            $util->syscmd( "$cmd -createprop . $path passwd '*'");
        };
        return 1;
    }
    else {
        warn "cannot add user on OS $OSNAME\n";
        return;
    };
    return $util->syscmd( $cmd );
};

sub user_exists {
    my $self = shift;
    my $user = lc(shift) or die "missing user";
    my $uid = getpwnam($user);
    return ( $uid && $uid > 0 ) ? $uid : undef;
};

sub vpopmail {

    my $self  = shift;
    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1 },
            'debug' => { type => BOOLEAN, optional => 1 },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $debug = $self->set_debug( $p{debug} );
    my $fatal = $self->set_fatal( $p{fatal} );

    if ( !$conf->{'install_vpopmail'} ) {
        $log->audit( "vpopmail: installing, skipping (disabled)" ) if $debug;
        return;
    }

    my ( $ans, $ddom, $ddb, $cflags, $my_write, $conf_args );

    my $version = $conf->{'install_vpopmail'} || "5.4.13";

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    if ( $OSNAME eq "freebsd" ) {
        my $installed = $freebsd->is_port_installed( "vpopmail", debug=>$debug);
        if ( $installed) {
            $log->audit("install vpopmail ($version), ok ($installed)");
            return 1 if $version eq "port";
        };

        $self->vpopmail_install_freebsd_port();
        $installed = $freebsd->is_port_installed( "vpopmail", debug=>$debug);
        return 1 if $installed && $version eq "port";

        # automake 1.10 required for vpopmail v5.4.27, may be safe to remove later
        #$freebsd->install_port( 'automake110', check => 'automake-1.10' );
    };

    my $package = "vpopmail-$version";
    my $vpopdir = $conf->{'vpopmail_home_dir'} || "/usr/local/vpopmail";

    $self->vpopmail_create_user();   # add the vpopmail user/group
    my $uid = getpwnam( $conf->{'vpopmail_user'} || "vpopmail" );
    my $gid = getgrnam( $conf->{'vpopmail_group'} || "vchkpw"  );

    my $installed = $self->vpopmail_installed_version();

    if ( $installed eq $version ) {
        if ( ! $util->yes_or_no(
                "Do you want to reinstall vpopmail with the same version?",
            timeout => 60,
            )
        )
        {
            $self->vpopmail_post_install();
            return 1;
        };
    }

    foreach ( qw/ rebuild_tcpserver_file ip_alias_domains valias mysql_logging
        qmail_ext learn_passwords mysql / ) {
        my $mt_setting = 'vpopmail_' . $_;
        my $conf_arg = "--enable-$_";
        $conf_arg =~ s/_/-/g;
        my $r = $conf->{$mt_setting} ? 'yes' : 'no';
        $conf_args .= " $conf_arg=$r";
        print "$conf_arg=$r\n";
    };


    if ( ! $self->is_newer( min => "5.3.30", cur => $version ) ) {
        if ( defined $conf->{'vpopmail_default_quota'} ) {
            $conf_args .=
              " --enable-defaultquota=$conf->{'vpopmail_default_quota'}";
            print "default quota: $conf->{'vpopmail_default_quota'}\n";
        }
        else {
            $conf_args .= " --enable-defaultquota=100000000S,10000C";
            print "default quota: 100000000S,10000C\n";
        }
    }

    $conf_args .= $self->vpopmail_roaming_users();

    if ( $OSNAME eq "darwin" && !-d "/usr/local/mysql"
        && -d "/opt/local/include/mysql" )
    {
        $conf_args .= " --enable-incdir=/opt/local/include/mysql";
        $conf_args .= " --enable-libdir=/opt/local/lib/mysql";
    }

    my $tcprules = $util->find_bin( "tcprules", debug=>0 );
    $conf_args .= " --enable-tcprules-prog=$tcprules";

    my $src = $conf->{'toaster_src_dir'} || "/usr/local/src";

    $util->cwd_source_dir( "$src/mail", debug=>$debug );

    my $tarball = "$package.tar.gz";

    # save having to download it again
    if ( -e "/usr/ports/distfiles/vpopmail-$version.tar.gz" ) {
        copy(
            "/usr/ports/distfiles/vpopmail-$version.tar.gz",
            "/usr/local/src/mail/"
        );
    }

    $util->sources_get(
        'package' => $package,
        site      => "http://" . $conf->{'toaster_sf_mirror'},
        path      => "/vpopmail",
        debug     => $debug
    );

    if ( -d $package ) {
        if ( !$util->source_warning(
                package => $package,
                src     => "$src/mail",
            ) )
        {
            carp "vpopmail: OK then, skipping install.\n";
            return;
        }
    }

    croak "Couldn't expand $tarball!\n"
        if !$util->extract_archive( $tarball );

    if ( $conf->{vpopmail_mysql} ) {
        $conf_args .= $self->vpopmail_mysql_options();
    };
    $conf_args .= $self->vpopmail_logging();
    $conf_args .= $self->vpopmail_default_domain($version);
    $conf_args .= $self->vpopmail_etc_passwd();

    # in case someone updates their toaster and not their config file
    if ( defined $conf->{'vpopmail_qmail_ext'} ) {
        if ( $conf->{'vpopmail_qmail_ext'} ) {
            $conf_args .= " --enable-qmail-ext=y";
            print "qmail extensions: yes\n";
        }
    }

    chdir($package);


#    chdir($package);
    print "running configure with $conf_args\n\n";

    $util->syscmd( "./configure $conf_args", debug => 0 );
    $util->syscmd( "make",                   debug => 0 );
    $util->syscmd( "make install-strip",     debug => 0 );

    if ( -e "vlimits.h" ) {
        # this was needed due to a bug in vpopmail 5.4.?(1-2) installer
        $util->syscmd( "cp vlimits.h $vpopdir/include/",
            debug   => 0
        );
    }

    $self->vpopmail_post_install();
    return 1;
}

sub vpopmail_default_domain {
    my $self = shift;
    my $version = shift;

    my $default_domain;

    if ( defined $conf->{'vpopmail_default_domain'} ) 
    {
        $default_domain = $conf->{'vpopmail_default_domain'};
    } 
    else {
        if ( ! $util->yes_or_no( "Do you want to use a default domain? ", ) ) {
            print "default domain: NONE SELECTED.\n";
            return q{};
        };

        $default_domain = $util->ask("your default domain");
    };

    if ( ! $default_domain ) 
    {
        print "default domain: NONE SELECTED.\n";
        return q{};
    };

    if ( $self->is_newer( min => "5.3.22", cur => $version ) ) {
        my $vpopdir = $conf->{'vpopmail_home_dir'} || "/usr/local/vpopmail";
        $util->file_write( "$vpopdir/etc/defaultdomain",
            lines => [ $default_domain ],
            debug => 0,
        );

        $util->chown( "$vpopdir/etc/defaultdomain",
            uid  => $conf->{'vpopmail_user'}  || "vpopmail",
            gid  => $conf->{'vpopmail_group'} || "vchkpw",
        );

        return q{};
    }

    print "default domain: $default_domain\n";
    return " --enable-default-domain=$default_domain";
};

sub vpopmail_etc {

    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => $debug },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
       $debug = $p{'debug'};

    my @lines;

    my $vpopdir = $conf->{'vpopmail_home_dir'} || "/usr/local/vpopmail";
    my $vetc    = "$vpopdir/etc";
    my $qdir    = $conf->{'qmail_dir'};

    mkdir( $vpopdir, oct('0775') ) unless ( -d $vpopdir );

    if ( -d $vetc ) { print "$vetc already exists.\n"; }
    else {
        print "creating $vetc\n";
        mkdir( $vetc, oct('0775') ) or carp "failed to create $vetc: $!\n";
    }

    $self->vpopmail_install_default_tcp_smtp( etc_dir => $vetc );

    my $qmail_control = "$qdir/bin/qmailctl";
    if ( -x $qmail_control ) {
        print " vpopmail_etc: rebuilding tcp.smtp.cdb\n";
        $util->syscmd( "$qmail_control cdb", debug => 0 );
    }
}

sub vpopmail_etc_passwd {
    my $self = shift;

    unless ( defined $conf->{'vpopmail_etc_passwd'} ) {
        print "\t\t CAUTION!!  CAUTION!!

    The system user account feature is NOT compatible with qmail-smtpd-chkusr.
    If you selected that option in the qmail build, you should not answer
    yes here. If you are unsure, select (n).\n";

        if ( $util->yes_or_no( "Do system users (/etc/passwd) get mail? (n) ")) {
            print "system password accounts: yes\n";
            return " --enable-passwd";
        }
    }

    if ( $conf->{'vpopmail_etc_passwd'} ) {
        print "system password accounts: yes\n";
        return " --enable-passwd";
    }

    print "system password accounts: no\n";
};

sub vpopmail_install_freebsd_port {

    my $self = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => $debug },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    # we install the port version regardless of whether it is selected.
    # This is because later apps (like courier) that we want to install
    # from ports require it to be registered in the ports db

    my $fatal = $p{'fatal'};
       $debug = $p{'debug'};

    my $version = $conf->{'install_vpopmail'};

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    my @defs = "WITH_CLEAR_PASSWD=yes";
    push @defs, "WITH_LEARN_PASSWORDS=yes" if $conf->{vpopmail_learn_passwords};
    push @defs, "WITH_IP_ALIAS=yes" if $conf->{vpopmail_ip_alias_domains};
    push @defs, "WITH_QMAIL_EXT=yes" if $conf->{vpopmail_qmail_ext};
    push @defs, "WITH_SINGLE_DOMAIN=yes" if $conf->{vpopmail_disable_many_domains};
    push @defs, 'LOGLEVEL="p"';

    if ( $conf->{'vpopmail_mysql'} ) {
        $log->error( "vpopmail_mysql is enabled by install_mysql is not. Please correct your settings" ) if ! $conf->{install_mysql};
        push @defs, "WITH_MYSQL=yes";
        push @defs, "WITH_MYSQL_REPLICATION=yes" if $conf->{vpopmail_mysql_replication};
        push @defs, "WITH_MYSQL_LIMITS=yes" if $conf->{vpopmail_mysql_limits};
        push @defs, 'WITH_VALIAS=yes' if $conf->{vpopmail_valias};
    };

    return if ! $freebsd->install_port( "vpopmail", flags => join( ",", @defs ),);

    # add a symlink so docs are web browsable 
    my $vpopdir = $conf->{'vpopmail_home_dir'};
    my $docroot = $conf->{'toaster_http_docs'};

    if ( ! -e "$docroot/vpopmail" ) {
        if ( -d "$vpopdir/doc/man_html" && -d $docroot ) {
            symlink "$vpopdir/doc/man_html", "$docroot/vpopmail";
        }
    }

    $freebsd->install_port( "p5-vpopmail", fatal => 0 ); 
    $self->vpopmail_post_install() if $version eq "port";
}

sub vpopmail_install_default_tcp_smtp {

    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'etc_dir' => { type => SCALAR },
        },
    );

    my $etc_dir = $p{'etc_dir'};

    # test for an existing one
    if ( -f "$etc_dir/tcp.smtp" ) {
        my $count = $util->file_read( "$etc_dir/tcp.smtp" );
        return if $count != 1;
        # back it up
        $util->archive_file( "$etc_dir/tcp.smtp" );
    }

    my $qdir = $conf->{'qmail_dir'};

    my @lines = <<"EO_TCP_SMTP";
# RELAYCLIENT="" means IP can relay
# RBLSMTPD=""    means DNSBLs are ignored for this IP
# QMAILQUEUE=""  is the qmail queue process, defaults to $qdir/bin/qmail-queue
#
#    common QMAILQUEUE settings:
# QMAILQUEUE="$qdir/bin/qmail-queue"
# QMAILQUEUE="$qdir/bin/simscan"
# 
#      handy test settings
# 127.:allow,RELAYCLIENT="",RBLSMTPD="",QMAILQUEUE="$qdir/bin/simscan"
# 127.:allow,RELAYCLIENT="",RBLSMTPD="",QMAILQUEUE="$qdir/bin/qscanq/bin/qscanq"
127.0.0.1:allow,RELAYCLIENT="",RBLSMTPD=""

EO_TCP_SMTP
    my $block = 1;

    if ( $conf->{'vpopmail_enable_netblocks'} ) {

        if (
            $util->yes_or_no(
                  "Do you need to enable relay access for any netblocks? :

NOTE: If you are an ISP and have dialup pools, this is where you want
to enter those netblocks. If you have systems that should be able to 
relay through this host, enter their IP/netblocks here as well.\n\n"
            )
          )
        {
            do {
                $block = $util->ask( "the netblock to add (empty to finish)" );
                push @lines, "$block:allow" if $block;
            } until ( !$block );
        }
    }

    #no Smart::Comments;
    push @lines, <<"EO_QMAIL_SCANNER";
#
# Allow anyone with reverse DNS set up
#=:allow
#    soft block on no reverse DNS
#:allow,RBLSMTPD="Blocked - Reverse DNS queries for your IP fail. Fix your DNS!"
#    hard block on no reverse DNS
#:allow,RBLSMTPD="-Blocked - Reverse DNS queries for your IP fail. You cannot send me mail."
#    default allow
#:allow,QMAILQUEUE="$qdir/bin/simscan"
:allow
EO_QMAIL_SCANNER

    $util->file_write( "$etc_dir/tcp.smtp", lines => \@lines );
}

sub vpopmail_installed_version {
    my $self = shift;

    my $vpopdir = $self->{conf}{vpopmail_home_dir} || '/usr/local/vpopmail';
    return if ! -x "$vpopdir/bin/vpasswd";

    my $installed = `$vpopdir/bin/vpasswd -v | head -1 | cut -f2 -d" "`;
    chop $installed;
    print "vpopmail version $installed currently installed.\n";
    return $installed;
}

sub vpopmail_logging {

    my $self = shift;

    if ( defined $conf->{'vpopmail_logging'} ) 
    {
        if ( $conf->{'vpopmail_logging'} ) 
        {
            if ( $conf->{'vpopmail_logging_verbose'} ) 
            {
                print "logging: verbose with failed passwords\n";
                return " --enable-logging=v";
            }

            print "logging: everything\n";
            return " --enable-logging=y";
        }
    }

    if ( ! $util->yes_or_no( "Do you want logging enabled? (y) ")) {
        return " --enable-logging=p";
    };

    if ( $util->yes_or_no( "Do you want verbose logging? (y) ")) {
        print "logging: verbose\n";
        return " --enable-logging=v";
    }

    print "logging: verbose with failed passwords\n";
    return " --enable-logging=p";
};

sub vpopmail_post_install {
    my $self = shift;
    $self->vpopmail_etc();
    $self->vpopmail_mysql_privs();
    $util->install_module( "vpopmail" ) if $self->{conf}{install_ezmlm_cgi};
    print "vpopmail: complete.\n";
    return 1;
};

sub vpopmail_roaming_users {
    my $self = shift;

    my $roaming = $conf->{'vpopmail_roaming_users'};

    if ( defined $roaming && !$roaming ) {
        print "roaming users: no\n";
        return " --enable-roaming-users=n";
    }

    # default to enabled
    if ( !defined $conf->{'vpopmail_roaming_users'} ) {
        print "roaming users: value not set?!\n";
    }

    print "roaming users: yes\n";

    my $min = $conf->{'vpopmail_relay_clear_minutes'};
    if ( $min && $min ne 180 ) {
        print "roaming user minutes: $min\n";
        return " --enable-roaming-users=y" .
            " --enable-relay-clear-minutes=$min";
    };
    return " --enable-roaming-users=y";
};

sub vpopmail_test {
    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => $debug },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
       $debug = $p{'debug'};

    return $p{test_ok} if defined $p{test_ok};

    print "do vpopmail directories exist...\n";
    my $vpdir = $conf->{'vpopmail_home_dir'};
    foreach ( "", "bin", "domains", "etc/", "include", "lib" ) {
        $log->test("  $vpdir/$_", -d "$vpdir/$_" );
    }

    print "checking vpopmail binaries...\n";
    foreach (
        qw/
        clearopensmtp   vaddaliasdomain     vadddomain
        valias          vadduser            vchkpw
        vchangepw       vconvert            vdeldomain
        vdelivermail    vdeloldusers        vdeluser
        vdominfo        vipmap              vkill
        vmkpasswd       vmoddomlimits       vmoduser
        vpasswd         vpopbull            vqmaillocal
        vsetuserquota   vuserinfo   /
      )
    {
        $log->test("  $_", -x "$vpdir/bin/$_" );
    }

    print "do vpopmail libs exist...\n";
    foreach ("$vpdir/lib/libvpopmail.a") {
        $log->test("  $_", -e $_ );
    }

    print "do vpopmail includes exist...\n";
    foreach (qw/ config.h vauth.h vlimits.h vpopmail.h vpopmail_config.h /) {
        $log->test("  include/$_", -e "$vpdir/include/$_" );
    }

    print "checking vpopmail etc files...\n";
    my @vpetc = qw/ inc_deps lib_deps tcp.smtp tcp.smtp.cdb vlimits.default /;
    push @vpetc, 'vpopmail.mysql' if $conf->{'vpopmail_mysql'};

    foreach ( @vpetc ) {
        $log->test("  $_", (-e "$vpdir/etc/$_" && -s "$vpdir/etc/$_" ));
    }
}

sub vpopmail_create_user {

    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => $debug },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
       $debug = $p{'debug'};

    my $vpopdir = $conf->{'vpopmail_home_dir'} || "/usr/local/vpopmail";
    my $vpuser  = $conf->{'vpopmail_user'}     || "vpopmail";
    my $vpgroup = $conf->{'vpopmail_group'}    || "vchkpw";

    my $uid = getpwnam($vpuser);
    my $gid = getgrnam($vpgroup);

    if ( !$uid || !$gid ) {
        $self->group_add( $vpgroup, "89" );
        $self->user_add( $vpuser, 89, 89, homedir => $vpopdir );
    }

    $uid = getpwnam($vpuser);
    $gid = getgrnam($vpgroup);

    if ( !$uid || !$gid ) {
        print "failed to add vpopmail user or group!\n";
        croak if $fatal;
        return 0;
    }

    return 1;
}

sub vpopmail_mysql_options {

    my $self = shift;
    my $mysql_repl    = $conf->{vpopmail_mysql_replication};
    my $my_write      = $conf->{vpopmail_mysql_repl_master} || 'localhost';
    my $db         = $conf->{vpopmail_mysql_database} || 'vpopmail';

    my $opts;
    if ( $conf->{'vpopmail_mysql_limits'} ) {
        print "mysql qmailadmin limits: yes\n";
        $opts .= " --enable-mysql-limits=y";
    }

    if ( $mysql_repl ) {
        $opts .= " --enable-mysql-replication=y";
        print "mysql replication: yes\n";
        print "      replication master: $my_write\n";
    }

    if ( $conf->{'vpopmail_disable_many_domains'} ) {
        $opts .= " --disable-many-domains";
    }

    return $opts;
}

sub vpopmail_mysql_privs {

    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            fatal   => { type => BOOLEAN, optional => 1 },
            debug   => { type => BOOLEAN, optional => 1 },
            test_ok => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
       $debug = $p{'debug'};

    if ( !$conf->{'vpopmail_mysql'} ) {
        print "vpopmail_mysql_privs: mysql support not selected!\n";
        return;
    }

    my $mysql_repl    = $conf->{vpopmail_mysql_replication};
    my $my_write      = $conf->{vpopmail_mysql_repl_master} || 'localhost';
    my $my_write_port = $conf->{vpopmail_mysql_repl_master_port} || 3306;
    my $my_read       = $conf->{vpopmail_mysql_repl_slave}  || 'localhost';
    my $my_read_port  = $conf->{vpopmail_mysql_repl_slave_port} || 3306;
    my $db            = $conf->{vpopmail_mysql_database} || 'vpopmail';

    my $user = $conf->{'vpopmail_mysql_user'} || $conf->{vpopmail_mysql_repl_user};
    my $pass = $conf->{'vpopmail_mysql_pass'} || $conf->{vpopmail_mysql_repl_pass};

    my $vpopdir = $conf->{'vpopmail_home_dir'} || "/usr/local/vpopmail";

    my @lines = "$my_read|0|$user|$pass|$db";
    if ($mysql_repl) {
        push @lines, "$my_write|$my_write_port|$user|$pass|$db";
    }
    else {
        push @lines, "$my_read|$my_read_port|$user|$pass|$db";
    }

    $util->file_write( "$vpopdir/etc/vpopmail.mysql",
        lines => \@lines, 
        debug => 1,
    );

    require Mail::Toaster::Mysql;
    my $mysql = Mail::Toaster::Mysql->new( toaster => $toaster );

    my $dot = $mysql->parse_dot_file( ".my.cnf", "[mysql]", 0 )
        || { user => $user, pass => $pass, host => $my_write, db => $db };

    my ( $dbh, $dsn, $drh ) = $mysql->connect( $dot, 1 );
    if ( !$dbh ) {
        $dot = { user => 'root', pass => '', host => $my_write };
        ( $dbh, $dsn, $drh ) = $mysql->connect( $dot, 1 );
    };

    if ( !$dbh ) {
        print <<"EOMYSQLGRANT";

        WARNING: I couldn't connect to your database server!  If this is a new install, 
        you will need to connect to your database server and run this command manually:

        mysql -u root -h $my_write -p
        CREATE DATABASE $db;
        GRANT ALL PRIVILEGES ON $db.* TO $user\@'$my_write' IDENTIFIED BY '$pass';
        use $db;
        CREATE TABLE relay ( ip_addr char(18) NOT NULL default '',
          timestamp char(12) default NULL, name char(64) default NULL,
          PRIMARY KEY (ip_addr)) TYPE=ISAM PACK_KEYS=1;
        quit;

        If this is an upgrade and you already use MySQL authentication, 
        then you can safely ignore this warning.

EOMYSQLGRANT
        return;
    }

    my $query = "use $db";
    my $sth = $mysql->query( $dbh, $query, 1 );
    if ( !$sth->errstr ) {
        $log->audit( "vpopmail: database setup, ok (exists)" );
        $sth->finish;
        return 1;
    }

    print "vpopmail: no vpopmail database, creating it now...\n";
    $query = "CREATE DATABASE $db";
    $sth   = $mysql->query( $dbh, $query );

    print "vpopmail: granting privileges to $user\n";
    $query =
      "GRANT ALL PRIVILEGES ON $db.* TO $user\@'$my_write' IDENTIFIED BY '$pass'";
    $sth = $mysql->query( $dbh, $query );

    print "vpopmail: creating the relay table.\n";
    $query =
"CREATE TABLE $db.relay ( ip_addr char(18) NOT NULL default '', timestamp char(12) default NULL, name char(64) default NULL, PRIMARY KEY (ip_addr)) TYPE=ISAM PACK_KEYS=1";
    $sth = $mysql->query( $dbh, $query );

    $log->audit( "vpopmail: databases created, ok" );
    $sth->finish;

    return 1;
}

sub vqadmin {

    my $self  = shift;
    my $debug = $self->{'debug'};

    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => $debug },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
       $debug = $p{'debug'};

    unless ( $conf->{'install_vqadmin'} ) {
        $log->audit( "vqadmin: installing, skipping (disabled)" )
          if $debug;
        return 0;
    }

    my $cgi  = $conf->{'toaster_cgi_bin'}   || "/usr/local/www/cgi-bin";
    my $data = $conf->{'toaster_http_docs'} || "/usr/local/www/data";

    my @defs = 'CGIBINDIR="' . $cgi . '"';
    push @defs, 'WEBDATADIR="' . $data . '"';

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    if ( $OSNAME eq "freebsd" ) {
        return 1
          if $freebsd->install_port( "vqadmin", flags => join( ",", @defs ),);
    }

    my $make  = $util->find_bin("gmake", fatal=>0, debug=>0);
    $make   ||= $util->find_bin("make", fatal=>0, debug=>0);

    print "trying to build vqadmin from sources\n";

    $util->install_from_source(
        package        => "vqadmin",
        site           => "http://vpopmail.sf.net",
        url            => "/downloads",
        targets        => [ "./configure ", $make, "$make install-strip" ],
        source_sub_dir => 'mail',
        debug => $debug,
    );
}

sub webmail {
    my $self  = shift;
    my $debug = $self->{'debug'};
    my %p = validate( @_, {
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => $debug },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
       $debug = $p{'debug'};

    # if the cgi_files dir is not available, we can't do much.
    if ( ! -d "cgi_files" ) {
        carp "You need to run this target while in the Mail::Toaster directory!\n" 
            . "Try this instead:

   cd /usr/local/src/Mail-Toaster-x.xx
   bin/toaster_setup.pl -s webmail

You are currently in " . Cwd::cwd;
        croak "error is fatal" if $fatal;
        return;
    };

    # set the hostname in mt-script.js
    my $hostname = $conf->{'toaster_hostname'};

    my @lines = $util->file_read("cgi_files/mt-script.js");
    foreach my $line ( @lines ) {
        if ( $line =~ /\Avar mailhost / ) {
            $line = qq{var mailhost = 'https://$hostname'};
        };
    }
    $util->file_write( "cgi_files/mt-script.js", lines => \@lines );

    my $htdocs = $conf->{'toaster_http_docs'} || '/usr/local/www/toaster';
    my $rsync = $self->rsync() or return;

    my $cmd = "$rsync -av ./cgi_files/ $htdocs/";
    print "about to run cmd: $cmd\n";

    print "\a";
    return if ! $util->yes_or_no( 
            "\n\n\t CAUTION! DANGER! CAUTION!

    This action will install the Mail::Toaster webmail interface. Doing
    so may overwrite existing files in $htdocs. Is is safe to proceed?\n\n",
            timeout  => 60,
          );

    $util->syscmd($cmd, debug=>$debug);

    require Mail::Toaster::Apache;
    my $apache = Mail::Toaster::Apache->new;
    $apache->restart();

    return 1;
};

1;
__END__;


=head1 NAME

Mail::Toaster::Setup -  methods to configure and build all the components of a modern email server.

=head1 DESCRIPTION

The meat and potatoes of toaster_setup.pl. This is where the majority of the work gets done. Big chunks of the code and logic for getting all the various applications and scripts installed and configured resides in here. 


=head1 METHODS

All documented methods in this package (shown below) accept two optional arguments, debug and fatal. Setting debug to zero will supress nearly all informational and debugging output. If you want more output, simply pass along debug=>1 and status messages will print out. Fatal allows you to override the default behaviour of these methods, which is to die upon error. Each sub returns 0 if the action failed and 1 for success.

 arguments required:
   varies (most require conf)
 
 arguments optional:
   debug - print status messages
   fatal - die on errors (default)

 result:
   0 - failure
   1 - success

 Examples:

   1. $setup->apache( debug=>0, fatal=>0 );
   Try to build apache, do not print status messages and do not die on error(s). 

   2. $setup->apache( debug=>1 );
   Try to build apache, print status messages, die on error(s). 

   3. if ( $setup->apache( ) { print "yay!\n" };
   Test to see if apache installed correctly.

=over

=item new

To use any methods in Mail::Toaster::Setup, you must create a setup object: 

  use Mail::Toaster::Setup;
  my $setup = Mail::Toaster::Setup->new;

From there you can run any of the following methods via $setup->method as documented below.

Many of the methods require $conf, which is a hashref containing the contents of toaster-watcher.conf. 


=item apache

Calls $apache->install[1|2] which then builds and installs Apache for you based on how it was called. See Mail::Toaster::Apache for more details.

  $setup->apache( ver=>22 );

There are many popular Apache compile time options supported. To see what options are available, see toaster-watcher.conf.

 required arguments:
   conf

 optional arguments:
   ver - the version number of Apache to install
   debug
   fatal


=item autorespond

Install autorespond. Fetches sources from Inter7 web site and installs. Automatically patches the sources to compile correctly on Darwin. 

  $setup->autorespond( );

 required arguments:
   conf

 optional arguments:
   debug
   fatal


=item clamav

Install ClamAV, configure the startup and config files, download the latest virus definitions, and start up the daemons.

  $setup->clamav( );

 required arguments:
   conf

 optional arguments:
   debug
   fatal


=item config - personalize your toaster-watcher.conf settings

There are a subset of the settings in toaster-watcher.conf which must be personalized for your server. Things like the hostname, where you store your configuration files, html documents, passwords, etc. This function checks to make sure these settings have been changed and prompts for any necessary changes.

 required arguments:
   conf

 optional arguments:
   debug
   fatal


=item config_tweaks

Makes changes to the config file, dynamically based on detected circumstances such as a jailed hostname, or OS platform. Platforms like FreeBSD, Darwin, and Debian have package management capabilities. Rather than installing software via sources, we prefer to try using the package manager first. The toaster-watcher.conf file typically includes the latest stable version of each application to install. This subroutine will replace those version numbers with with 'port', 'package', or other platform specific tweaks.


=item courier

  $setup->courier( );

Installs courier imap based on your settings in toaster-watcher.conf.

 required arguments:
   conf

 optional arguments:
   debug
   fatal

 result:
   1 - success
   0 - failure


=item courier_startup

  $setup->courier_startup( );

Does the post-install configuration of Courier IMAP.


=item cpan

  $setup->cpan( );

Installs only the perl modules that are required for 'make test' to succeed. Useful for CPAN testers.

 Date::Parse
 HTML::Template
 Compress::Zlib
 Crypt::PasswdMD5
 Net::DNS
 Quota
 TimeDate


=item cronolog

Installs cronolog. If running on FreeBSD or Darwin, it will install from ports. If the port install fails for any reason, or you are on another platform, it will install from sources. 

required arguments:
  conf

optional arguments:
  debug
  fatal

result:
  1 - success
  0 - failure


=item daemontools

Fetches sources from DJB's web site and installs daemontools, per his instructions.

 Usage:
  $setup->daemontools( conf->$conf );

 required arguments:
   conf

 optional arguments:
   debug
   fatal

 result:
   1 - success
   0 - failure


=item dependencies

  $setup->dependencies( );

Installs a bunch of dependency programs that are needed by other programs we will install later during the build of a Mail::Toaster. You can install these yourself if you would like, this does not do anything special beyond installing them:

ispell, gdbm, setquota, expect, maildrop, autorespond, qmail, qmailanalog, daemontools, openldap-client, Crypt::OpenSSL-RSA, DBI, DBD::mysql.

required arguments:
  conf

optional arguments:
  debug
  fatal

result:
  1 - success
  0 - failure


=item djbdns

Fetches djbdns, compiles and installs it.

  $setup->djbdns( );

 required arguments:
   conf

 optional arguments:
   debug
   fatal

 result:
   1 - success
   0 - failure


=item expect

Expect is a component used by courier-imap and sqwebmail to enable password changing via those tools. Since those do not really work with a Mail::Toaster, we could live just fine without it, but since a number of FreeBSD ports want it installed, we install it without all the extra X11 dependencies.


=item ezmlm

Installs Ezmlm-idx. This also tweaks the port Makefile so that it will build against MySQL 4.0 libraries if you don't have MySQL 3 installed. It also copies the sample config files into place so that you have some default settings.

  $setup->ezmlm( );

 required arguments:
   conf

 optional arguments:
   debug
   fatal

 result:
   1 - success
   0 - failure


=item filtering

Installs SpamAssassin, ClamAV, simscan, QmailScanner, maildrop, procmail, and programs that support the aforementioned ones. See toaster-watcher.conf for options that allow you to customize which programs are installed and any options available.

  $setup->filtering();



=item is_newer

Checks a three place version string like 5.3.24 to see if the current version is newer than some value. Useful when you have various version of a program like vpopmail or mysql and the syntax you need to use for building it is different for differing version of the software.


=item isoqlog

Installs isoqlog.

  $setup->isoqlog();


=item maildrop

Installs a maildrop filter in $prefix/etc/mail/mailfilter, a script for use with Courier-IMAP in $prefix/sbin/subscribeIMAP.sh, and sets up a filter debugging file in /var/log/mail/maildrop.log.

  $setup->maildrop( );


=item maildrop_filter

Creates and installs the maildrop mailfilter file.

  $setup->maildrop_filter();


=item maillogs

Installs the maillogs script, creates the logging directories (toaster_log_dir/), creates the qmail supervise dirs, installs maillogs as a log post-processor and then builds the corresponding service/log/run file to use with each post-processor.

  $setup->maillogs();



=item mattbundle

Downloads and installs the latest version of MATT::Bundle.

  $setup->mattbundle(debug=>1);

Don't do it. Matt::Bundle has been deprecated for years now.


=item mysql

Installs mysql server for you, based on your settings in toaster-watcher.conf. The actual code that does the work is in Mail::Toaster::Mysql so read the man page for Mail::Toaster::Mysql for more info.

  $setup->mysql( );


=item phpmyadmin

Installs PhpMyAdmin for you, based on your settings in toaster-watcher.conf. The actual code that does the work is in Mail::Toaster::Mysql (part of Mail::Toaster::Bundle) so read the man page for Mail::Toaster::Mysql for more info.

  $setup->phpmyadmin($conf);


=item ports

Install the ports tree on FreeBSD or Darwin and update it with cvsup. 

On FreeBSD, it optionally uses cvsup_fastest to choose the fastest cvsup server to mirror from. Configure toaster-watch.conf to adjust it's behaviour. It can also install the portupgrade port to use for updating your legacy installed ports. Portupgrade is very useful, but be very careful about using portupgrade -a. I always use portupgrade -ai and skip the toaster related ports such as qmail since we have customized version(s) of them installed.

  $setup->ports();


=item qmailadmin

Install qmailadmin based on your settings in toaster-watcher.conf.

  $setup->qmailadmin();



=item razor

Install Vipul's Razor2

  $setup->razor( );


=item ripmime

Installs ripmime

  $setup->ripmime();


=item simscan

Install simscan from Inter7.

  $setup->simscan();

See toaster-watcher.conf to see how these settings affect the build and operations of simscan.


=item simscan_conf

Build the simcontrol and ssattach config files based on toaster-watcher.conf settings.


=item simscan_test

Send some test messages to the mail admin using simscan as a message scanner.

    $setup->simscan_test();


=item socklog

	$setup->socklog( ip=>$ip );

If you need to use socklog, then you'll appreciate how nicely this configures it. :)  $ip is the IP address of the socklog master server.


=item socklog_qmail_control

	socklog_qmail_control($service, $ip, $user, $supervisedir);

Builds a service/log/run file for use with socklog.


=item squirrelmail

	$setup->squirrelmail

Installs Squirrelmail using FreeBSD ports. Adjusts the FreeBSD port by passing along WITH_APACHE2 if you have Apache2 selected in your toaster-watcher.conf.


=item sqwebmail

	$setup->sqwebmail();

install sqwebmail based on your settings in toaster-watcher.conf.


=item supervise

	$setup->supervise();

One stop shopping: calls the following subs:

  $qmail->control_create        ();
  $setup->service_dir_create    ();
  $toaster->supervise_dirs_create ();
  $qmail->install_qmail_control_files ();
  $qmail->install_qmail_control_log_files();
  $toaster->service_symlinks    (debug=>$debug);


=item startup_script

Sets up the supervised mail services for Mail::Toaster

	$setup->startup_script( );

If they don't already exist, this sub will create:

	daemontools service directory (default /var/service) 
	symlink to the services script

The services script allows you to run "services stop" or "services start" on your system to control the supervised daemons (qmail-smtpd, qmail-pop3, qmail-send, qmail-submit). It affects the following files:

  $prefix/etc/rc.d/[svscan|services].sh
  $prefix/sbin/services


=item test

Run a variety of tests to verify that your Mail::Toaster installation is working correctly.


=item ucspi_tcp

Installs ucspi-tcp with my (Matt Simerson) MySQL patch.

	$setup->ucspi_tcp( );


=item vpopmail

Vpopmail is great, but it has lots of options and remembering which option you used months or years ago to build a mail server is not always easy. So, store all the settings in toaster-watcher.conf and this sub will install vpopmail for you, honoring all your settings and passing the appropriate configure flags to vpopmail's configure.

	$setup->vpopmail( );

If you do not have toaster-watcher.conf installed, it will ask you a series of questions and then install based on your answers.


=item vpopmail_etc


Builds the ~vpopmail/etc/tcp.smtp file with a mess of sample entries and user specified settings.

	$setup->vpopmail_etc( );


=item vpopmail_mysql_privs

Connects to MySQL server, creates the vpopmail table if it doesn't exist, and sets up a vpopmail user and password as set in $conf. 

    $setup->vpopmail_mysql_privs($conf);


=item vqadmin

	$setup->vqadmin($conf, $debug);

Installs vqadmin from ports on FreeBSD and from sources on other platforms. It honors your cgi-bin and your htdocs directory as configured in toaster-watcher.conf.

=back


=head1 DEPENDENCIES

    IO::Socket::SSL


=head1 AUTHOR

Matt Simerson - matt@tnpi.net


=head1 BUGS

None known. Report to author. Patches welcome (diff -u preferred)


=head1 TODO

Better documentation. It is almost reasonable now.


=head1 SEE ALSO

The following are all man/perldoc pages: 

 Mail::Toaster 
 Mail::Toaster::Conf
 toaster.conf
 toaster-watcher.conf

 http://mail-toaster.org/


=head1 COPYRIGHT AND LICENSE

Copyright (c) 2004-2010, The Network People, Inc.  All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

Neither the name of the The Network People, Inc. nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


=cut
