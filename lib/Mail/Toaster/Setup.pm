package Mail::Toaster::Setup;

use strict;
use warnings;

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
use parent 'Mail::Toaster::Base';

sub apache {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts, } );

    return $p{test_ok} if defined $p{test_ok};

    my $ver   = $self->conf->{install_apache} or do {
        $self->audit( "apache: installing, skipping (disabled)" );
        return;
    };

    require Cwd;
    my $old_directory = Cwd::cwd();

    if ( lc($ver) eq "apache1" or $ver == 1 ) {
        my $src = $self->conf->{'toaster_src_dir'} || "/usr/local/src";
        $self->apache->install_apache1( $src );
    }
    elsif ( lc($ver) eq "ssl" ) {
        $self->apache->install_ssl_certs( type=>'rsa' );
    }
    else {
        $self->apache->install_2;
    }

    chdir $old_directory if $old_directory;
    $self->apache->startup;
    return 1;
}

sub apache_conf_fixup {
# makes changes necessary for Apache to start while running in a jail

    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok};

    my $httpdconf = $self->apache->conf_get_dir;

    unless ( -e $httpdconf ) {
        print "Could not find your httpd.conf file!  FAILED!\n";
        return 0;
    }

    return if hostname !~ /^jail/;    # we're running in a jail

    my @lines = $self->util->file_read( $httpdconf );
    foreach my $line (@lines) {
        if ( $line =~ /^Listen 80/ ) { # this is only tested on FreeBSD
            my @ips = $self->util->get_my_ips(only=>"first", verbose=>0);
            $line = "Listen $ips[0]:80";
        }
    }

    $self->util->file_write( "/var/tmp/httpd.conf", lines => \@lines );

    return unless $self->util->install_if_changed(
        newfile  => "/var/tmp/httpd.conf",
        existing => $httpdconf,
        clean    => 1,
        notify   => 1,
    );

    return 1;
}

sub autorespond {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing

    my $ver = $self->conf->{'install_autorespond'} or do {
        $self->audit( "autorespond install skipped (disabled)" );
        return;
    };

    if ( $OSNAME eq "freebsd" && $ver eq "port" ) {
        $self->freebsd->install_port( "autorespond" );
    }

    my $autorespond = $self->util->find_bin( "autorespond", fatal => 0, verbose => 0 );

    # return success if it is installed.
    if ( $autorespond &&  -x $autorespond ) {
        $self->audit( "autorespond: installed ok (exists)" );
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
        my $sed = $self->util->find_bin( "sed", verbose => 0 );
        my $prefix = $self->conf->{'toaster_prefix'} || "/usr/local";
        $prefix =~ s/\//\\\//g;
        @targets = (
            "$sed -i '' 's/strcasestr/strcasestr2/g' autorespond.c",
            "$sed -i '' 's/PREFIX=\$(DESTDIR)\\/usr/PREFIX=\$(DESTDIR)$prefix/g' Makefile",
            'make', 'make install'
        );
    }

    $self->util->install_from_source(
        package        => "autorespond-$ver",
        site           => 'http://www.inter7.com',
        url            => '/devel',
        targets        => \@targets,
        bintest        => 'autorespond',
        source_sub_dir => 'mail',
    );

    if ( $self->util->find_bin( "autorespond", fatal => 0, verbose => 0, ) ) {
        $self->audit( "autorespond: installed ok" );
        return 1;
    }

    return 0;
}

sub clamav {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing

    my $prefix   = $self->conf->{'toaster_prefix'}      || "/usr/local";
    my $confdir  = $self->conf->{'system_config_dir'}   || "/usr/local/etc";
    my $share    = "$prefix/share/clamav";
    my $clamuser = $self->conf->{'install_clamav_user'} || "clamav";
    my $ver      = $self->conf->{'install_clamav'} or do {
        $self->audit( "clamav: installing, skipping (disabled)" );
        return;
    };

    my $installed;

    # install via ports if selected
    if ( $OSNAME eq "freebsd" && $ver eq "port" ) {
        $self->freebsd->install_port( "clamav", flags => "BATCH=yes WITHOUT_LDAP=1");
        return $self->clamav_post_install;
    }

    # add the clamav user and group
    unless ( getpwuid($clamuser) ) {
        $self->group_add( 'clamav', '90' );
        $self->user_add( $clamuser, 90, 90 );
    }

    unless ( getpwnam($clamuser) ) {
        print "User clamav user installation FAILED, I cannot continue!\n";
        return 0;
    }

    # install via ports if selected
    if ( $OSNAME eq "darwin" && $ver eq "port" ) {
        $self->darwin->install_port( "clamav" ) or return;
        return $self->clamav_post_install;
    }

    # port installs didn't work out, time to build from sources

    # set a default version of ClamAV if not provided
    if ( $ver eq "1" ) { $ver = "0.97.8"; }; # latest as of 6/2013

    # download the sources, build, and install ClamAV
    $self->util->install_from_source(
        package        => 'clamav-' . $ver,
        site           => 'http://' . $self->conf->{'toaster_sf_mirror'},
        url            => '/clamav',
        targets        => [ './configure', 'make', 'make install' ],
        bintest        => 'clamdscan',
        source_sub_dir => 'mail',
    );

    $self->util->find_bin( "clamdscan", fatal => 0 ) or
        return $self->error( "clamav: install FAILED" );

    $self->audit( "clamav: installed ok" );

    return $self->clamav_post_install;
}

sub clamav_post_install {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    $self->clamav_update or return;
    $self->clamav_perms  or return;
    $self->clamav_start  or return;
    return 1;
}

sub clamav_perms {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    my $prefix  = $self->conf->{'toaster_prefix'}      || "/usr/local";
    my $confdir = $self->conf->{'system_config_dir'}   || "/usr/local/etc";
    my $clamuid = $self->conf->{'install_clamav_user'} || "clamav";
    my $share   = "$prefix/share/clamav";

    foreach my $file ( $share, "$share/daily.cvd", "$share/main.cvd",
        "$share/viruses.db", "$share/viruses.db2", "/var/log/clamav/freshclam.log", ) {

        if ( -e $file ) {
            print "setting the ownership of $file to $clamuid.\n";
            $self->util->chown( $file, uid => $clamuid, gid => 'clamav' );
        };
    }

    $self->util->syscmd( "pw user mod clamav -G qmail" )
        or return $self->error( "failed to add clamav to the qmail group" );

    return 1;
}

sub clamav_start {
    # get ClamAV running
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    if ( $self->util->is_process_running('clamd') ) {
        $self->audit( "clamav: starting up, ok (already running)" );
    }

    print "Starting up ClamAV...\n";

    if ( $OSNAME ne "freebsd" ) {
        $self->util->_incomplete_feature( {
                mess   => "start up ClamAV on $OSNAME",
                action =>
'You will need to start up ClamAV yourself and make sure it is configured to launch at boot time.',
            }
        );
        return;
    };

    $self->freebsd->conf_check(
        check => "clamav_clamd_enable",
        line  => 'clamav_clamd_enable="YES"',
    );

    $self->freebsd->conf_check(
        check => "clamav_freshclam_enable",
        line  => 'clamav_freshclam_enable="YES"',
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

    if ( $self->util->is_process_running('clamd', verbose=>0) ) {
        $self->audit( "clamav: starting up, ok" );
    }

    # These are no longer required as the FreeBSD ports now installs
    # startup files of its own.
    foreach ( qw/ clamav.sh freshclam.sh / ) {
        unlink "/usr/local/etc/rc.d/$_" if -e "/usr/local/etc/rc.d/$_";
    };

    return 1;
}

sub clamav_update {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    # set up freshclam (keeps virus databases updated)
    my $logfile = "/var/log/clamav/freshclam.log";
    unless ( -e $logfile ) {
        $self->util->syscmd( "touch $logfile", verbose=>0 );
        $self->util->chmod( file => $logfile, mode => '0644', verbose=>0 );
        $self->clamav_perms(  verbose=>0 );
    }

    my $freshclam = $self->util->find_bin( "freshclam", verbose=>0 )
        or return $self->error( "couldn't find freshclam!", fatal=>0);

    $self->audit("updating ClamAV database with freshclam");
    $self->util->syscmd( "$freshclam", verbose => 0, fatal => 0 );
    return 1;
}

sub config {
    require Mail::Toaster::Setup::Config;
    return Mail::Toaster::Setup::Config->new;
};

sub courier_imap {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok};

    my $ver = $self->conf->{'install_courier_imap'} or do {
        $self->audit( "courier: installing, skipping (disabled)" );
        $self->courier_startup_freebsd() if $OSNAME eq 'freebsd'; # enable startup
        return;
    };

    $self->audit("courier $ver is selected" );

    if ( $OSNAME eq "freebsd" && $ver eq "port" ) {
        $self->audit("using courier from FreeBSD ports" );
        $self->courier_authlib;
        $self->courier_imap_freebsd;
        $self->courier_startup;
        return 1 if $self->freebsd->is_port_installed( "courier-imap", verbose=>0);
    }
    elsif ( $OSNAME eq "darwin" ) {
        return $self->darwin->install_port( "courier-imap", );
    }

    # if a specific version has been requested, install it from sources
    # but first, a default for users who didn't edit toaster-watcher.conf
    $ver = "4.8.0" if ( $ver eq "port" );

    my $site    = "http://" . $self->conf->{'toaster_sf_mirror'};
    my $confdir = $self->conf->{'system_config_dir'} || "/usr/local/etc";
    my $prefix  = $self->conf->{'toaster_prefix'} || "/usr/local";

    $ENV{"HAVE_OPEN_SMTP_RELAY"} = 1;    # circumvent bug in courier

    my $conf_args = "--prefix=$prefix --exec-prefix=$prefix --without-authldap --without-authshadow --with-authvchkpw --sysconfdir=/usr/local/etc/courier-imap --datadir=$prefix/share/courier-imap --libexecdir=$prefix/libexec/courier-imap --enable-workarounds-for-imap-client-bugs --disable-root-check --without-authdaemon";

    print "./configure $conf_args\n";
    my $make = $self->util->find_bin( "gmake", verbose=>0, fatal=>0 ) ||
        $self->util->find_bin( "make", verbose=>0);
    my @targets = ( "./configure " . $conf_args, $make, "$make install" );

    $self->util->install_from_source(
        package        => "courier-imap-$ver",
        site           => $site,
        url            => "/courier",
        targets        => \@targets,
        bintest        => "imapd",
        source_sub_dir => 'mail',
    );

    $self->courier_startup();
}

sub courier_imap_freebsd {
    my $self = shift;

#   my @defs = "WITH_VPOPMAIL=1";
#   push @defs, "WITHOUT_AUTHDAEMON=1";
#   push @defs, "WITH_CRAM=1";
#   push @defs, "AUTHMOD=authvchkpw";

    $self->freebsd->install_port( "courier-imap",
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
    my %p = validate( @_, { $self->get_std_opts } );

    my $prefix  = $self->conf->{'toaster_prefix'}    || "/usr/local";
    my $confdir = $self->conf->{'system_config_dir'} || "/usr/local/etc";

    if ( $OSNAME ne "freebsd" ) {
        print "courier-authlib build support is not available for $OSNAME yet.\n";
        return 0;
    };

    if ( ! $self->freebsd->is_port_installed( "courier-authlib" ) ) {

        $self->freebsd->install_port( "courier-authlib",
            options => "# Options for courier-authlib-0.65.0
_OPTIONS_READ=courier-authlib-0.65.0
_FILE_COMPLETE_OPTIONS_LIST=AUTH_LDAP AUTH_MYSQL AUTH_PGSQL AUTH_USERDB AUTH_VCHKPW GDBM
OPTIONS_FILE_UNSET+=AUTH_LDAP
OPTIONS_FILE_UNSET+=AUTH_MYSQL
OPTIONS_FILE_UNSET+=AUTH_PGSQL
OPTIONS_FILE_UNSET+=AUTH_USERDB
OPTIONS_FILE_SET+=AUTH_VCHKPW
OPTIONS_FILE_UNSET+=GDBM
",
            );
    }

    $self->freebsd->install_port( "courier-authlib-vchkpw",
        flags => "AUTHMOD=authvchkpw",
    );

    # install a default authdaemonrc
    my $authrc = "$confdir/authlib/authdaemonrc";

    if ( ! -e $authrc ) {
        if ( -e "$authrc.dist" ) {
            print "installing default authdaemonrc.\n";
            copy("$authrc.dist", $authrc);
        }
    };

    if ( `grep 'authmodulelist=' $authrc | grep ldap` ) {
        $self->config->apply_tweaks(
            file => $authrc,
            changes => [
                {   search  => q{authmodulelist="authuserdb authvchkpw authpam authldap authmysql authpgsql"},
                    replace => q{authmodulelist="authvchkpw"},
                },
            ],
        );
        $self->audit( "courier_authlib: fixed up $authrc" );
    }

    $self->freebsd->conf_check(
        check => "courier_authdaemond_enable",
        line  => "courier_authdaemond_enable=\"YES\"",
    );

    if ( ! -e "/var/run/authdaemond/pid" ) {
        my $start = "$prefix/etc/rc.d/courier-authdaemond";
        foreach ( $start, "$start.sh" ) {
            $self->util->syscmd( "$_ start", verbose=>0) if -x $_;
        };
    };
    return 1;
}

sub courier_ssl {
    my $self = shift;

    my $confdir = $self->conf->{'system_config_dir'} || "/usr/local/etc";
    my $prefix  = $self->conf->{'toaster_prefix'} || "/usr/local";
    my $share   = "$prefix/share/courier-imap";

    # apply ssl_ values from t-w.conf to courier's .cnf files
    if ( ! -e "$share/pop3d.pem" || ! -e "$share/imapd.pem" ) {
        my $pop3d_ssl_conf = "$confdir/courier-imap/pop3d.cnf";
        my $imapd_ssl_conf = "$confdir/courier-imap/imapd.cnf";

        my $common_name = $self->conf->{'ssl_common_name'} || $self->conf->{'toaster_hostname'};
        my $org      = $self->conf->{'ssl_organization'};
        my $locality = $self->conf->{'ssl_locality'};
        my $state    = $self->conf->{'ssl_state'};
        my $country  = $self->conf->{'ssl_country'};

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
        $self->util->syscmd( "./mkpop3dcert", verbose => 0 );
    }

    if ( !-e "$share/imapd.pem" ) {
        chdir $share;
        $self->util->syscmd( "./mkimapdcert", verbose => 0 );
    }
};

sub courier_startup {

    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    my $prefix  = $self->conf->{'toaster_prefix'} || "/usr/local";
    my $ver     = $self->conf->{'install_courier_imap'};
    my $confdir = $self->conf->{'system_config_dir'} || "/usr/local/etc";

    chdir("$confdir/courier-imap") or
        return $self->error( "could not chdir $confdir/courier-imap.");

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
        $self->util->syscmd( "$prefix/sbin/imapssl start", verbose=>0 )
          if -x "$prefix/sbin/imapssl";
    }

    unless ( -e "/var/run/imapd.pid" ) {
        $self->util->syscmd( "$prefix/sbin/imap start", verbose=>0 )
          if -x "$prefix/sbin/imapssl";
    }

    unless ( -e "/var/run/pop3d-ssl.pid" ) {
        $self->util->syscmd( "$prefix/sbin/pop3ssl start", verbose=>0 )
          if -x "$prefix/sbin/pop3ssl";
    }

    if ( $self->conf->{'pop3_daemon'} eq "courier" ) {
        if ( !-e "/var/run/pop3d.pid" ) {
            $self->util->syscmd( "$prefix/sbin/pop3 start", verbose=>0 )
              if -x "$prefix/sbin/pop3";
        }
    }
}

sub courier_startup_freebsd {
    my $self = shift;

    my $prefix  = $self->conf->{'toaster_prefix'} || "/usr/local";
    my $confdir = $self->conf->{'system_config_dir'} || "/usr/local/etc";

    # cleanup stale links, created long ago when rc.d files had .sh endings
    foreach ( qw/ imap imapssl pop3 pop3ssl / ) {
        if ( -e "$prefix/sbin/$_" ) {
            readlink "$prefix/sbin/$_" or unlink "$prefix/sbin/$_";
        };
    };

    if ( ! -e "$prefix/sbin/imap" ) {
        $self->audit( "setting up startup file shortcuts for daemons");
        symlink( "$confdir/rc.d/courier-imap-imapd", "$prefix/sbin/imap" );
        symlink( "$confdir/rc.d/courier-imap-pop3d", "$prefix/sbin/pop3" );
        symlink( "$confdir/rc.d/courier-imap-imapd-ssl", "$prefix/sbin/imapssl" );
        symlink( "$confdir/rc.d/courier-imap-pop3d-ssl", "$prefix/sbin/pop3ssl" );
    }

    my $start = $self->conf->{install_courier_imap} ? 'YES' : 'NO';

    $self->freebsd->conf_check(
        check => "courier_imap_imapd_enable",
        line  => "courier_imap_imapd_enable=\"$start\"",
    );

    $self->freebsd->conf_check(
        check => "courier_imap_imapdssl_enable",
        line  => "courier_imap_imapdssl_enable=\"$start\"",
    );

    $self->freebsd->conf_check(
        check => "courier_imap_imapd_ssl_enable",
        line  => "courier_imap_imapd_ssl_enable=\"$start\"",
    );

    $self->freebsd->conf_check(
        check => "courier_imap_pop3dssl_enable",
        line  => "courier_imap_pop3dssl_enable=\"$start\"",
    );

    $self->freebsd->conf_check(
        check => "courier_imap_pop3d_ssl_enable",
        line  => "courier_imap_pop3d_ssl_enable=\"$start\"",
    );

    if ( $self->conf->{'pop3_daemon'} eq "courier" ) {
        $self->freebsd->conf_check(
            check => "courier_imap_pop3d_enable",
            line  => "courier_imap_pop3d_enable=\"$start\"",
        );
    }
};

sub cronolog {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing

    my $ver = $self->conf->{'install_cronolog'} or do {
        $self->audit( "cronolog: skipping install (disabled)");
        return;
    };

    if ( $OSNAME eq "freebsd" && $ver eq "port" ) {
        return $self->cronolog_freebsd();
    }

    if ( $self->util->find_bin( "cronolog", fatal => 0 ) ) {
        $self->audit( "cronolog: install cronolog, ok (exists)",verbose=>1 );
        return 2;
    }

    $self->audit( "attempting cronolog install from source");

    if ( $ver eq "port" ) { $ver = "1.6.2" };  # a fallback version

    $self->util->install_from_source(
        package => "cronolog-$ver",
        site    => 'http://www.cronolog.org',
        url     => '/download',
        targets => [ './configure', 'make', 'make install' ],
        bintest => 'cronolog',
    );

    $self->util->find_bin( "cronolog" ) or return;

    $self->audit( "cronolog: install cronolog, ok" );
    return 1;
}

sub cronolog_freebsd {
    my $self = shift;
    return $self->freebsd->install_port( "cronolog",
        fatal => 0,
        options => "# This file generated by mail-toaster
# Options for cronolog-1.6.2_4
_OPTIONS_READ=cronolog-1.6.2_4
_FILE_COMPLETE_OPTIONS_LIST=SETUID_PATCH
OPTIONS_FILE_UNSET+=SETUID_PATCH\n",
    );
};

sub daemontools {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok};

    my $ver = $self->conf->{'install_daemontools'} or do {
        $self->audit( "daemontools: installing, (disabled)" );
        return;
    };

    $self->daemontools_freebsd() if $OSNAME eq "freebsd";

    if ( $OSNAME eq "darwin" && $ver eq "port" ) {
        $self->darwin->install_port( "daemontools" );

        print
"\a\n\nWARNING: there is a bug in the OS 10.4 kernel that requires daemontools to be built with a special tweak. This must be done once. You will be prompted to install daemontools now. If you haven't already allowed this script to build daemontools from source, please do so now!\n\n";
        sleep 2;
    }

    # see if the svscan binary is already installed
    $self->util->find_bin( "svscan", fatal => 0, verbose => 0 ) and do {
        $self->audit( "daemontools: installing, ok (exists)" );
        return 1;
    };

    $self->daemontools_src();
};

sub daemontools_src {
    my $self = shift;

    my $ver = $self->conf->{'install_daemontools'};
    $ver = "0.76" if $ver eq "port";

    my $package = "daemontools-$ver";
    my $prefix  = $self->conf->{'toaster_prefix'} || "/usr/local";

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
            'echo "' . $self->conf->{'toaster_prefix'} . '" > src/home',
            "cd src", "make",
        );
    }

    $self->util->install_from_source(
        package    => $package,
        site       => 'http://cr.yp.to',
        url        => '/daemontools',
        targets    => \@targets,
        patches    => \@patches,
        patch_args => $patch_args,
        patch_url  => "$self->conf->{'toaster_dl_site'}$self->conf->{'toaster_dl_url'}/patches",
        bintest    => 'svscan',
    );

    if ( $OSNAME =~ /darwin|freebsd/i ) {

        # manually install the daemontools binaries in $prefix/local/bin
        chdir "$self->conf->{'toaster_src_dir'}/admin/$package";

        foreach ( $self->util->file_read( "package/commands" ) ) {
            my $install = $self->util->find_bin( 'install' );
            $self->util->syscmd( "$install src/$_ $prefix/bin", verbose=>0 );
        }
    }

    return 1;
}

sub daemontools_freebsd {
    my $self = shift;
    return $self->freebsd->install_port( "daemontools",
        options => '# This file is generated by Mail Toaster
# Options for daemontools-0.76_16
_OPTIONS_READ=daemontools-0.76_16
_FILE_COMPLETE_OPTIONS_LIST=MAN SIGQ12 TESTS S_EARLY S_NORMAL
OPTIONS_FILE_SET+=MAN
OPTIONS_FILE_UNSET+=SIGQ12
OPTIONS_FILE_SET+=TESTS
OPTIONS_FILE_UNSET+=S_EARLY
OPTIONS_FILE_SET+=S_NORMAL
',
        fatal => 0,
    );
};

sub daemontools_test {
    my $self = shift;

    print "checking daemontools binaries...\n";
    my @bins = qw{ multilog softlimit setuidgid supervise svok svscan tai64nlocal };
    foreach my $test ( @bins ) {
        my $bin = $self->util->find_bin( $test, fatal => 0, verbose=>0);
        $self->toaster->test("  $test", -x $bin );
    };

    return 1;
}

sub dependencies {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing

    my $qmaildir = $self->conf->{'qmail_dir'} || "/var/qmail";

    if ( $OSNAME eq "freebsd" ) {
        $self->dependencies_freebsd();
        $self->freebsd->install_port( "p5-Net-DNS",
            options => "#\n# This file was generated by mail-toaster
# Options for p5-Net-DNS-0.58\n_OPTIONS_READ=p5-Net-DNS-0.58\nWITHOUT_IPV6=true",
        );
    }
    elsif ( $OSNAME eq "darwin" ) {
        my @dports =
          qw/ cronolog gdbm gmake ucspi-tcp daemontools DarwinPortsStartup /;

        push @dports, qw/aspell aspell-dict-en/ if $self->conf->{'install_aspell'};
        push @dports, "ispell"   if $self->conf->{'install_ispell'};
        push @dports, "maildrop" if $self->conf->{'install_maildrop'};
        push @dports, "openldap" if $self->conf->{'install_openldap_client'};
        push @dports, "gnupg"    if $self->conf->{'install_gnupg'};

        foreach (@dports) { $self->darwin->install_port( $_ ) }
    }
    else {
        $self->dependencies_other();
    };

    $self->util->install_module( "Params::Validate" );
    $self->util->install_module( "IO::Compress" );
    $self->util->install_module( "Compress::Raw::Zlib" );
    $self->util->install_module( "Crypt::PasswdMD5" );
    $self->util->install_module( "Net::DNS" );
    $self->util->install_module( "Quota", fatal => 0 ) if $self->conf->{'install_quota_tools'};
    $self->util->install_module( "Date::Format", port => "p5-TimeDate");
    $self->util->install_module( "Date::Parse" );
    $self->util->install_module( "Mail::Send",  port => "p5-Mail-Tools");

    if ( ! -x "$qmaildir/bin/qmail-queue" ) {
        $self->conf->{'qmail_chk_usr_patch'} = 0;
        $self->qmail->netqmail_virgin();
    }

    $self->daemontools();
    $self->autorespond();
}

sub dependencies_freebsd {
    my $self = shift;
    my $package = $self->conf->{'package_install_method'} || "packages";

    $self->periodic_conf();    # create /etc/periodic.conf
    $self->gmake_freebsd();
    $self->openssl_install();
    $self->stunnel() if $self->conf->{'pop3_ssl_daemon'} eq "qpop3d";
    $self->ucspi_tcp_freebsd();
    $self->cronolog_freebsd();

    my @to_install = { port => "p5-Params-Validate"  };

    push @to_install, { port => "setquota" }  if $self->conf->{'install_quota_tools'};
    push @to_install, { port => "portaudit" } if $self->conf->{'install_portaudit'};
    push @to_install, { port => "ispell", category => 'textproc' }
        if $self->conf->{'install_ispell'};
    push @to_install, {
        port    => 'gdbm',
        options => "# This file generated by Mail::Toaster
# Options for gdbm-1.10
_OPTIONS_READ=gdbm-1.10
_FILE_COMPLETE_OPTIONS_LIST=COMPAT NLS
OPTIONS_FILE_UNSET+=COMPAT
OPTIONS_FILE_UNSET+=NLS\n",
    };
    push @to_install, { port  => 'openldap23-client',
        check    => "openldap-client",
        category => 'net',
        } if $self->conf->{'install_openldap_client'};
    push @to_install, { port  => "qmail",
        flags   => "BATCH=yes",
        options => "#\n# Installed by Mail::Toaster
# Options for qmail-1.03_7\n_OPTIONS_READ=qmail-1.03_7",
    };
    push @to_install, { port => "qmailanalog", fatal => 0 };
    push @to_install, { port => "qmail-notify", fatal => 0 }
        if $self->conf->{'install_qmail_notify'};

    # if package method is selected, try it
    if ( $package eq "packages" ) {
        foreach ( @to_install ) {
            my $port = $_->{port} || $_->{name};
            $self->freebsd->install_package( $port, fatal => 0 );
        };
    }

    foreach my $port (@to_install) {
        $self->freebsd->install_port( $port->{'port'},
            defined $port->{flags}   ? (flags   => $port->{flags}   ) : (),
            defined $port->{options} ? (options => $port->{options} ) : (),
            defined $port->{check}   ? (check   => $port->{check}   ) : (),
            defined $port->{fatal}   ? (fatal   => $port->{fatal}   ) : (),
            defined $port->{category}? (category=> $port->{category}) : (),
        );
    }
};

sub dependencies_other {
    my $self = shift;
    print "no ports for $OSNAME, installing from sources.\n";

    if ( $OSNAME eq "linux" ) {
        my $vpopdir = $self->conf->{'vpopmail_home_dir'} || "/usr/local/vpopmail";
        $self->qmail->install_qmail_groups_users();

        $self->util->syscmd( "groupadd -g 89 vchkpw" );
        $self->util->syscmd( "useradd -g vchkpw -d $vpopdir vpopmail" );
        $self->util->syscmd( "groupadd clamav" );
        $self->util->syscmd( "useradd -g clamav clamav" );
    }

    my @progs = qw(gmake expect cronolog autorespond );
    push @progs, "setquota" if $self->conf->{'install_quota_tools'};
    push @progs, "ispell" if $self->conf->{'install_ispell'};
    push @progs, "gnupg" if $self->conf->{'install_gnupg'};

    foreach (@progs) {
        if ( $self->util->find_bin( $_, verbose=>0,fatal=>0 ) ) {
            $self->audit( "checking for $_, ok" );
        }
        else {
            print "$_ not installed. FAILED, please install manually.\n";
        }
    }
}

sub djbdns {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing

    if ( ! $self->conf->{'install_djbdns'} ) {
        $self->audit( "djbdns: installing, skipping (disabled)" );
        return;
    };

    $self->daemontools();
    $self->ucspi_tcp();

    return $self->audit( "djbdns: installing djbdns, ok (already installed)" )
        if $self->util->find_bin( 'tinydns', fatal => 0 );

    if ( $OSNAME eq "freebsd" ) {
        $self->djbdns_freebsd();

        return $self->audit( "djbdns: installing djbdns, ok" )
            if $self->util->find_bin( 'tinydns', fatal => 0 );
    }

    return $self->djbdns_src();
};

sub djbdns_src {
    my $self = shift;

    my @targets = ( 'make', 'make setup check' );

    if ( $OSNAME eq "linux" ) {
        unshift @targets,
          'echo gcc -O2 -include /usr/include/errno.h > conf-cc';
    }

    $self->util->install_from_source(
        package => "djbdns-1.05",
        site    => 'http://cr.yp.to',
        url     => '/djbdns',
        targets => \@targets,
        bintest => 'tinydns',
    );
}

sub djbdns_freebsd {
    my $self = shift;
    $self->freebsd->install_port( "djbdns",
        options => "#\n
# Options for djbdns-1.05_13
_OPTIONS_READ=djbdns-1.05_13
WITHOUT_DUMPCACHE=true
WITHOUT_IPV6=true
WITHOUT_IGNOREIP=true
WITHOUT_JUMBO=true
WITH_MAN=true
WITHOUT_PERSISTENT_MMAP=true
WITHOUT_SRV=true\n",
    );
};

sub docs {
    my $self = shift;

    my $cmd;

    if ( !-f "README" && !-f "lib/toaster.conf.pod" ) {
        print <<"EO_NOT_IN_DIST_ERR";

   ERROR: This setup target can only be run in the Mail::Toaster distibution directory!

    Try switching into there and trying again.
EO_NOT_IN_DIST_ERR

        return;
    };

    # convert pod to text files
    my $pod2text = $self->util->find_bin( "pod2text", verbose=>0);

    $self->util->syscmd("$pod2text bin/toaster_setup.pl       > README", verbose=>0);
    $self->util->syscmd("$pod2text lib/toaster.conf.pod          > doc/toaster.conf", verbose=>0);
    $self->util->syscmd("$pod2text lib/toaster-watcher.conf.pod  > doc/toaster-watcher.conf", verbose=>0);


    # convert pod docs to HTML pages for the web site

    my $pod2html = $self->util->find_bin("pod2html", verbose=>0);

    $self->util->syscmd( "$pod2html --title='toaster.conf' lib/toaster.conf.pod > doc/toaster.conf.html",
        verbose=>0, );
    $self->util->syscmd( "$pod2html --title='watcher.conf' lib/toaster-watcher.conf.pod  > doc/toaster-watcher.conf.html",
        verbose=>0, );
    $self->util->syscmd( "$pod2html --title='mailadmin' bin/mailadmin > doc/mailadmin.html",
        verbose=>0, );

    my @modules = qw/ Toaster   Apache  CGI     Darwin   DNS
            Ezmlm     FreeBSD   Logs    Mysql   Perl
            Qmail     Setup   Utility /;

    MODULE:
    foreach my $module (@modules ) {
        if ( $module =~ m/\AToaster\z/ ) {
            $cmd = "$pod2html --title='Mail::Toaster' lib/Mail/$module.pm > doc/modules/$module.html";
            print "$cmd\n";
            next MODULE;
            $self->util->syscmd( $cmd, verbose=>0 );
        };

        $cmd = "$pod2html --title='Mail::Toaster::$module' lib/Mail/Toaster/$module.pm > doc/modules/$module.html";
        warn "$cmd\n";
        $self->util->syscmd( $cmd, verbose=>0 );
    };

    unlink <pod2htm*>;
    #$self->util->syscmd( "rm pod2html*");
};

sub domainkeys {

    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    if ( !$self->conf->{'qmail_domainkeys'} ) {
        $self->audit( "domainkeys: installing, skipping (disabled)" );
        return 0;
    }

    # test to see if it is installed.
    if ( -f "/usr/local/include/domainkeys.h" ) {
        $self->audit( "domainkeys: installing domainkeys, ok (already installed)" );
        return 1;
    }

    if ( $OSNAME eq "freebsd" ) {
        $self->freebsd->install_port( "libdomainkeys" );

        # test to see if it installed.
        if ( -f "/usr/local/include/domainkeys.h" ) {
            $self->audit( "domainkeys: installing domainkeys, ok (already installed)" );
            return 1;
        }
    }

    my @targets = ( 'make', 'make setup check' );

    if ( $OSNAME eq "linux" ) {
        unshift @targets,
          'echo gcc -O2 -include /usr/include/errno.h > conf-cc';
    }

    $self->util->install_from_source(
        package => "libdomainkeys-0.68",
        site    => 'http://superb-east.dl.sourceforge.net',
        url     => '/sourceforge/domainkeys',
        targets => \@targets,
    );
}

sub dovecot {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing

    my $ver = $self->conf->{'install_dovecot'} or do {
        $self->audit( "dovecot install not selected.");
        return;
    };

    if ( $ver eq "port" || $ver eq "1" ) {

        if ( $self->util->find_bin( "dovecot", fatal => 0 ) ) {
            print "dovecot: is already installed...done.\n\n";
            return $self->dovecot_start();
        }

        print "dovecot: installing...\n";

        if ( $OSNAME eq "freebsd" ) {
            $self->dovecot_install_freebsd() or return;
            return $self->dovecot_start();
        }
        elsif ( $OSNAME eq "darwin" ) {
            return 1 if $self->darwin->install_port( "dovecot" );
        }

        if ( $self->util->find_bin( "dovecot", fatal => 0 ) ) {
            print "dovecot: install successful.\n";
            return $self->dovecot_start();
        }

        $ver = "1.0.7";
    }

    my $dovecot = $self->util->find_bin( "dovecot", fatal => 0 );
    if ( -x $dovecot ) {
        my $installed = `$dovecot --version`;

        if ( $ver eq $installed ) {
            print
              "dovecot: the selected version ($ver) is already installed!\n";
            $self->dovecot_start();
            return 1;
        }
    }

    $self->util->install_from_source(
        package        => "dovecot-$ver",
        site           => 'http://www.dovecot.org',
        url            => '/releases',
        targets        => [ './configure', 'make', 'make install' ],
        bintest        => 'dovecot',
        verbose          => 1,
        source_sub_dir => 'mail',
    );

    $self->dovecot_start();
}

sub dovecot_1_conf {
    my $self = shift;

    my $dconf = '/usr/local/etc/dovecot.conf';
    if ( ! -f $dconf ) {
        foreach ( qw{ /opt/local/etc /etc } ) {
            $dconf = "$_/dovecot.conf";
            last if -e $dconf;
        };
        if ( ! -f $dconf ) {
            return $self->error( "could not locate dovecot.conf. Toaster modifications not applied.");
        };
    };

    my $updated = `grep 'Mail Toaster' $dconf`;
    if ( $updated ) {
        $self->audit( "Toaster modifications detected, skipping config" );
        return 1;
    };

    $self->config->apply_tweaks(
        file => $dconf,
        changes => [
            {   search  => "protocols = imap pop3 imaps pop3s managesieve",
                replace => "protocols = imap pop3 imaps pop3s",
                nowarn  => 1,
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
                nowarn  => 1,   # manageseive is optional build
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
                nowarn  => 1,
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
    return 1;
};

sub dovecot_2_conf {
    my $self = shift;

    my $dconf = '/usr/local/etc/dovecot';
    return if ! -d $dconf;

    if ( ! -f "$dconf/dovecot.conf" ) {
        my $ex = '/usr/local/share/doc/dovecot/example-config';

        foreach ( qw/ dovecot.conf / ) {
            if ( -f "$ex/$_" ) {
                copy("$ex/$_", $dconf);
            };
        };
        system "cp $ex/conf.d /usr/local/etc/dovecot";
    };

    my $updated = `grep 'Mail Toaster' $dconf/dovecot.conf`;
    if ( $updated ) {
        $self->audit( "Toaster modifications detected, skipping config" );
        return 1;
    };

    $self->config->apply_tweaks(
        file => "$dconf/dovecot.conf",
        changes => [
            {   search  => "#login_greeting = Dovecot ready.",
                replace => "#login_greeting = Dovecot ready.
login_greeting = Mail Toaster (Dovecot) ready.",
            },
            {   search  => "#listen = *, ::",
                replace => "#listen = *, ::\nlisten = *",
            },
        ],
    );

    $self->config->apply_tweaks(
        file => "$dconf/conf.d/10-auth.conf",
        changes => [
            {   search  => "#auth_username_format =",
                replace => "#auth_username_format =\nauth_username_format = %Lu",
                nowarn  => 1,
            },
            {   search  => "auth_mechanisms = plain",
                replace => "auth_mechanisms = plain login digest-md5 cram-md5",
            },
            {   search  => "!include auth-system.conf.ext",
                replace => "#!include auth-system.conf.ext",
                nowarn  => 1,
            },
            {   search  => "#!include auth-vpopmail.conf.ext",
                replace => "!include auth-vpopmail.conf.ext",
                nowarn  => 1,
            },
        ],
    );

    $self->config->apply_tweaks(
        file => "$dconf/conf.d/10-ssl.conf",
        changes => [
            {   search  => "ssl_cert = </etc/ssl/certs/dovecot.pem",
                replace => "#ssl_cert = </etc/ssl/certs/dovecot.pem
ssl_cert = </var/qmail/control/servercert.pem",
            },
            {   search  => "ssl_key = </etc/ssl/private/dovecot.pem",
                replace => "#ssl_key = </etc/ssl/private/dovecot.pem
ssl_key = </var/qmail/control/servercert.pem",
            },
        ],
    );

    $self->config->apply_tweaks(
        file => "$dconf/conf.d/10-mail.conf",
        changes => [
            {
                search  => "#mail_location = ",
                replace => "#mail_location =
mail_location = maildir:~/Maildir",
            },
            {   search  => "#first_valid_uid = 500",
                replace => "#first_valid_uid = 500\nfirst_valid_uid = 89",
            },
            {   search  => "#last_valid_uid = 0",
                replace => "#last_valid_uid = 0\nlast_valid_uid = 89",
            },
            {   search  => "first_valid_gid = 1",
                replace => "#first_valid_gid = 1\nfirst_valid_gid = 89",
            },
            {   search  => "#last_valid_gid = 0",
                replace => "#last_valid_gid = 0\nlast_valid_gid = 89",
            },
            {   search  => "#mail_plugins =",
                replace => "#mail_plugins =\nmail_plugins = quota",
            },
        ],
    );

    $self->config->apply_tweaks(
        file => "$dconf/conf.d/20-pop3.conf",
        changes => [
            {   search => "  #pop3_client_workarounds = ",
                replace => "  #pop3_client_workarounds = \n  pop3_client_workarounds = outlook-no-nuls oe-ns-eo",
            },
        ],
    );

    $self->config->apply_tweaks(
        file => "$dconf/conf.d/15-lda.conf",
        changes => [
            {   search  => "#sendmail_path = /usr/sbin/sendmail",
                replace => "#sendmail_path = /usr/sbin/sendmail\nsendmail_path = /var/qmail/bin/sendmail",
            },
        ],
    );

    $self->config->apply_tweaks(
        file => "$dconf/conf.d/90-quota.conf",
        changes => [
            {   search  => "  #quota = maildir:User quota",
                replace => "  quota = maildir:User quota",
            },
        ],
    );

    $self->config->apply_tweaks(
        file => "$dconf/conf.d/20-imap.conf",
        changes => [
            {   search  => "  #mail_plugins = ",
                replace => "  #mail_plugins = \n  mail_plugins = \$mail_plugins imap_quota",
            },
        ],
    );
};

sub dovecot_install_freebsd {
    my $self = shift;

    return 1 if $self->freebsd->is_port_installed('dovecot');

    $self->audit( "starting port install of dovecot" );

    $self->freebsd->install_port( "dovecot",
        options => "# This file is generated by Mail Toaster.
# Options for dovecot-1.2.17
_OPTIONS_READ=dovecot-1.2.17
_FILE_COMPLETE_OPTIONS_LIST=BDB GSSAPI KQUEUE LDAP MANAGESIEVE MYSQL PGSQL SQLITE SSL VPOPMAIL
OPTIONS_FILE_UNSET+=BDB
OPTIONS_FILE_UNSET+=GSSAPI
OPTIONS_FILE_SET+=KQUEUE
OPTIONS_FILE_UNSET+=LDAP
OPTIONS_FILE_UNSET+=MANAGESIEVE
OPTIONS_FILE_UNSET+=MYSQL
OPTIONS_FILE_UNSET+=PGSQL
OPTIONS_FILE_UNSET+=SQLITE
OPTIONS_FILE_SET+=SSL
OPTIONS_FILE_SET+=VPOPMAIL
",
    ) or return;

    return if ! $self->freebsd->is_port_installed('dovecot');

    my $config = "/usr/local/etc/dovecot.conf";
    if ( ! -e $config ) {
        if ( -e "/usr/local/etc/dovecot-example.conf" ) {
            copy("/usr/local/etc/dovecot-example.conf", $config);
        }
        else {
            $self->error("unable to find dovecot.conf sample", fatal => 0);
            sleep 3;
            return;
        };
    };

    return 1;
}

sub dovecot_start {

    my $self = shift;

    unless ( $OSNAME eq "freebsd" ) {
        $self->error( "sorry, no dovecot startup support on $OSNAME", fatal => 0);
        return;
    };

    $self->dovecot_1_conf();
    $self->dovecot_2_conf();

    # append dovecot_enable to /etc/rc.conf
    $self->freebsd->conf_check(
        check => "dovecot_enable",
        line  => 'dovecot_enable="YES"',
    );

    # start dovecot
    if ( -x "/usr/local/etc/rc.d/dovecot" ) {
        $self->util->syscmd("/usr/local/etc/rc.d/dovecot restart", verbose=>0);
    };
}

sub enable_all_spam {
    my $self  = shift;

    my $qmail_dir = $self->conf->{'qmail_dir'} || "/var/qmail";
    my $spam_cmd  = $self->conf->{'qmailadmin_spam_command'} ||
        '| /usr/local/bin/maildrop /usr/local/etc/mail/mailfilter';

    my @domains = $self->qmail->get_domains_from_assign(
            assign => "$qmail_dir/users/assign",
        );

    my $number_of_domains = @domains;
    $self->audit( "enable_all_spam: found $number_of_domains domains.");

    for (my $i = 0; $i < $number_of_domains; $i++) {

        my $domain = $domains[$i]{'dom'};
        $self->audit( "Enabling spam processing for $domain mailboxes");

        my @paths = `~vpopmail/bin/vuserinfo -d -D $domain`;

        PATH:
        foreach my $path (@paths) {
            chomp($path);
            if ( ! $path || ! -d $path) {
                $self->audit( "  $path does not exist!");
                next PATH;
            };

            my $qpath = "$path/.qmail";
            if (-f $qpath) {
                $self->audit( "  .qmail already exists in $path.");
                next PATH;
            };

            $self->audit( "  .qmail created in $path.");
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
    my %p = validate( @_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    if ( !$self->conf->{'install_expat'} ) {
        $self->audit( "expat: installing, skipping (disabled)" );
        return;
    }

    if ( $OSNAME eq "freebsd" ) {
        if ( -d "/usr/ports/textproc/expat" ) {
            return $self->freebsd->install_port( "expat" );
        }
        else {
            return $self->freebsd->install_port( "expat", dir => 'expat2');
        }
    }
    elsif ( $OSNAME eq "darwin" ) {
        $self->darwin->install_port( "expat" );
    }
    else {
        print "Sorry, build support for expat on $OSNAME is incomplete.\n";
    }
}

sub expect {

    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing

    if ( $OSNAME eq "freebsd" ) {
        return $self->freebsd->install_port( "expect",
            flags => "WITHOUT_X11=yes",
            fatal => $p{fatal},
        );
    }
    return;
}

sub ezmlm {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing

    my $ver     = $self->conf->{'install_ezmlm'};
    my $confdir = $self->conf->{'system_config_dir'} || "/usr/local/etc";

    if ( !$ver ) {
        $self->audit( "installing Ezmlm-Idx, (disabled)", verbose=>1 );
        return;
    }

    my $ezmlm = $self->util->find_bin( 'ezmlm-sub',
        dir   => '/usr/local/bin/ezmlm',
        fatal => 0,
    );

    if ( $ezmlm && -x $ezmlm ) {
        $self->audit( "installing Ezmlm-Idx, ok (installed)",verbose=>1 );
        return $self->ezmlm_cgi();
    }

    $self->ezmlm_freebsd_port() and return 1;
    $self->ezmlm_src();
};

sub ezmlm_src {
    my $self = shift;
    print "ezmlm: attemping to install ezmlm from sources.\n";

    my $ezmlm_dist = "ezmlm-0.53";
    my $ver     = $self->conf->{'install_ezmlm'};
    my $idx     = "ezmlm-idx-$ver";
    my $site    = "http://untroubled.org/ezmlm";
    my $src     = $self->conf->{'toaster_src_dir'} || "/usr/local/src/mail";
    my $httpdir = $self->conf->{'toaster_http_base'} || "/usr/local/www";
    my $cgi     = $self->toaster->get_toaster_cgibin() or die "unable to determine cgi-bin dir\n";

    $self->util->cwd_source_dir( "$src/mail" );

    if ( -d $ezmlm_dist ) {
        unless (
            $self->util->source_warning( package => $ezmlm_dist, src => "$src/mail" ) )
        {
            carp "\nezmlm: OK then, skipping install.\n";
            return;
        }
        else {
            print "ezmlm: removing any previous build sources.\n";
            $self->util->syscmd( "rm -rf $ezmlm_dist" );
        }
    }

    $self->util->get_url( "$site/archive/$ezmlm_dist.tar.gz" )
        if ! -e "$ezmlm_dist.tar.gz";

    $self->util->get_url( "$site/archive/$ver/$idx.tar.gz" )
        if ! -e "$idx.tar.gz";

    $self->util->extract_archive( "$ezmlm_dist.tar.gz" )
      or croak "Couldn't expand $ezmlm_dist.tar.gz: $!\n";

    $self->util->extract_archive( "$idx.tar.gz" )
      or croak "Couldn't expand $idx.tar.gz: $!\n";

    $self->util->syscmd( "mv $idx/* $ezmlm_dist/", );
    $self->util->syscmd( "rm -rf $idx", );

    chdir($ezmlm_dist);

    $self->util->syscmd( "patch < idx.patch", );
    $self->ezmlm_conf_fixups();

    $self->util->syscmd( "make" );
    $self->util->syscmd( "chmod 775 makelang" );

#$self->util->syscmd( "make mysql" );  # haven't figured this out yet (compile problems)
    $self->util->syscmd( "make man" );
    $self->util->syscmd( "make setup");

    $self->ezmlm_cgi();
    return 1;
}

sub ezmlm_conf_fixups {
    my $self = shift;

    if ( $OSNAME eq "darwin" ) {
        my $local_include = "/usr/local/mysql/include";
        my $local_lib     = "/usr/local/mysql/lib";

        if ( !-d $local_include ) {
            $local_include = "/opt/local/include/mysql";
            $local_lib     = "/opt/local/lib/mysql";
        }

        $self->util->file_write( "sub_mysql/conf-sqlcc",
            lines => ["-I$local_include"],
        );

        $self->util->file_write( "sub_mysql/conf-sqlld",
            lines => ["-L$local_lib -lmysqlclient -lm"],
        );
    }
    elsif ( $OSNAME eq "freebsd" ) {
        $self->util->file_write( "sub_mysql/conf-sqlcc",
            lines => ["-I/usr/local/include/mysql"],
        );

        $self->util->file_write( "sub_mysql/conf-sqlld",
            lines => ["-L/usr/local/lib/mysql -lmysqlclient -lnsl -lm"],
        );
    }

    $self->util->file_write( "conf-bin", lines => ["/usr/local/bin"] );
    $self->util->file_write( "conf-man", lines => ["/usr/local/man"] );
    $self->util->file_write( "conf-etc", lines => ["/usr/local/etc"] );
};

sub ezmlm_cgi {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing

    return 1 if ! $self->conf->{'install_ezmlm_cgi'};

    if ( $OSNAME eq "freebsd" ) {
        $self->freebsd->install_port( "p5-Archive-Tar",
            options=>"#
# This file was generated by Mail::Toaster
# No user-servicable parts inside!
# Options for p5-Archive-Tar-1.30
_OPTIONS_READ=p5-Archive-Tar-1.30
WITHOUT_TEXT_DIFF=true",
        );
    }

    $self->util->install_module( "Email::Valid" );
    $self->util->install_module( "Mail::Ezmlm" );

    return 1;
}

sub ezmlm_freebsd_port {
    my $self = shift;

    return if $OSNAME ne "freebsd";
    return if $self->conf->{'install_ezmlm'} ne "port";
    return 1 if $self->freebsd->is_port_installed( "ezmlm", fatal=>0 );

    my $defs = '';
    my $myopt = $self->conf->{'install_ezmlm_mysql'} ? 'SET' : 'UNSET';

    $self->freebsd->install_port( "ezmlm-idx",
        options => "# This file was generated by mail-toaster
# Options for ezmlm-idx-7.1.1_1
_OPTIONS_READ=ezmlm-idx-7.1.1_1
_FILE_COMPLETE_OPTIONS_LIST=DB DOCS MYSQL PGSQL SQLITE
OPTIONS_FILE_$myopt+=DB
OPTIONS_FILE_SET+=DOCS
OPTIONS_FILE_$myopt+=MYSQL
OPTIONS_FILE_UNSET+=PGSQL
OPTIONS_FILE_UNSET+=SQLITE
",
    )
    or return $self->error( "ezmlm-idx install failed" );

    my $confdir = $self->conf->{'system_config_dir'} || "/usr/local/etc";
    chdir("$confdir/ezmlm");
    copy( "ezmlmglrc.sample", "ezmlmglrc" )
        or $self->util->error( "copy ezmlmglrc failed: $!");

    copy( "ezmlmrc.sample", "ezmlmrc" )
        or $self->util->error( "copy ezmlmrc failed: $!");

    copy( "ezmlmsubrc.sample", "ezmlmsubrc" )
        or $self->util->error( "copy ezmlmsubrc failed: $!");

    return $self->ezmlm_cgi();
};

sub filtering {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    return $p{test_ok} if defined $p{test_ok}; # for testing

    if ( $OSNAME eq "freebsd" ) {

        $self->maildrop->install;

        $self->freebsd->install_port( "p5-Archive-Tar",
			options=> "# This file was generated by mail-toaster
# No user-servicable parts inside!
# Options for p5-Archive-Tar-1.30
_OPTIONS_READ=p5-Archive-Tar-1.30
WITHOUT_TEXT_DIFF=true",
        );

        $self->freebsd->install_port( "p5-Mail-Audit" );
        $self->freebsd->install_port( "unzip" );

        $self->razor();

        $self->freebsd->install_port( "pyzor" ) if $self->conf->{'install_pyzor'};
        $self->freebsd->install_port( "bogofilter" ) if $self->conf->{'install_bogofilter'};
        $self->freebsd->install_port( "dcc-dccd",
            flags => "WITHOUT_SENDMAIL=yes",
            options => "# This file generated by mail-toaster
# Options for dcc-dccd-1.3.116
_OPTIONS_READ=dcc-dccd-1.3.116
WITH_DCCIFD=true
WITHOUT_DCCM=true
WITH_DCCD=true
WITH_DCCGREY=true
WITH_IPV6=true
WITHOUT_ALT_HOME=true
WITHOUT_PORTS_SENDMAIL=true\n",
            ) if $self->conf->{'install_dcc'};

        $self->freebsd->install_port( "procmail" ) if $self->conf->{'install_procmail'};
        $self->freebsd->install_port( "p5-Email-Valid" );
    }

    $self->spamassassin;
    $self->razor;
    $self->clamav;
    $self->simscan->install;
}

sub gmake_freebsd {
    my $self = shift;

# iconv to suppress a prompt, and because gettext requires it
    $self->freebsd->install_port( 'libiconv',
        options => "#\n# This file was generated by mail-toaster
# Options for libiconv-1.13.1_1
_OPTIONS_READ=libiconv-1.13.1_1
WITH_EXTRA_ENCODINGS=true
WITHOUT_EXTRA_PATCHES=true\n",
    );

# required by gmake
    $self->freebsd->install_port( "gettext",
        options => "#\n# This file was generated by mail-toaster
# Options for gettext-0.14.5_2
_OPTIONS_READ=gettext-0.14.5_2\n",
    );

    $self->freebsd->install_port( 'gmake' );
};

sub gnupg_install {
    my $self = shift;
    return if ! $self->conf->{'install_gnupg'};

    if ( $self->conf->{package_install_method} eq 'packages' ) {
        $self->freebsd->install_package( "gnupg", verbose=>0, fatal => 0 );
        return 1 if $self->freebsd->is_port_installed('gnupg');
    };

    $self->freebsd->install_port( "gnupg",
        verbose   => 0,
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
        $cmd = $self->util->find_bin('groupadd');
        $cmd .= " -g $gid" if $gid;
        $cmd .= " $group";
    }
    elsif ( $OSNAME eq 'freebsd' ) {
        $cmd = $self->util->find_bin( 'pw' );
        $cmd .= " groupadd -n $group";
        $cmd .= " -g $gid" if $gid;
    }
    elsif ( $OSNAME eq 'darwin' ) {
        $cmd = $self->util->find_bin( "dscl", fatal => 0 );
        my $path = "/groups/$group";
        if ($cmd) {    # use dscl 10.5+
            $self->util->syscmd( "$cmd . -create $path" );
            $self->util->syscmd( "$cmd . -createprop $path gid $gid") if $gid;
            $self->util->syscmd( "$cmd . -createprop $path passwd '*'" );
        }
        else {
            $cmd = $self->util->find_bin( "niutil", fatal => 0 );
            $self->util->syscmd( "$cmd -create . $path" );
            $self->util->syscmd( "$cmd -createprop . $path gid $gid") if $gid;
            $self->util->syscmd( "$cmd -createprop . $path passwd '*'" );
        }
        return 1;
    }
    else {
        warn "unable to create users on OS $OSNAME\n";
        return;
    };
    return $self->util->syscmd( $cmd );
};

sub group_exists {
    my $self = shift;
    my $group = lc(shift) or die "missing group";
    my $gid = getgrnam($group);
    return ( $gid && $gid > 0 ) ? $gid : undef;
};

sub has_module {
    my $self = shift;
    my ($name, $ver) = @_;

## no critic ( ProhibitStringyEval )
    eval "use $name" . ($ver ? " $ver;" : ";");
## use critic

    !$EVAL_ERROR;
};

sub is_newer {
    my $self  = shift;
    my %p = validate( @_, { 'min' => SCALAR, 'cur' => SCALAR, $self->get_std_opts } );

    my ( $min, $cur ) = ( $p{'min'}, $p{'cur'} );

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
    my %p = validate( @_, { $self->get_std_opts },);

    my $ver = $self->conf->{'install_isoqlog'}
        or return $self->audit( "install_isoqlog is disabled",verbose=>1 );

    my $return = 0;

    if ( $ver eq "port" ) {
        if ( $OSNAME eq "freebsd" ) {
            $self->freebsd->install_port( "isoqlog" );
            $self->isoqlog_conf();
            return 1 if $self->freebsd->is_port_installed( "isoqlog", %p );
        }
        else {
            return $self->error(
                "isoqlog: install_isoqlog = port is not valid for $OSNAME" );
        }
    }
    else {
        if ( $self->util->find_bin( "isoqlog", fatal => 0 ) ) {
            $self->isoqlog_conf();
            $self->audit( "isoqlog: install, ok (exists)" );
            return 2;
        }
    }

    return $return if $self->util->find_bin( "isoqlog", fatal => 0 );

    $self->audit( "isoqlog not found. Attempting source install ($ver) on $OSNAME!");

    $ver = 2.2 if ( $ver eq "port" || $ver == 1 );

    my $configure = "./configure ";

    if ( $self->conf->{'toaster_prefix'} ) {
        $configure .= "--prefix=" . $self->conf->{'toaster_prefix'} . " ";
        $configure .= "--exec-prefix=" . $self->conf->{'toaster_prefix'} . " ";
    }

    if ( $self->conf->{'system_config_dir'} ) {
        $configure .= "--sysconfdir=" . $self->conf->{'system_config_dir'} . " ";
    }

    $self->audit( "isoqlog: building with $configure" );

    $self->util->install_from_source(
        package => "isoqlog-$ver",
        site    => 'http://www.enderunix.org',
        url     => '/isoqlog',
        targets => [ $configure, 'make', 'make install', 'make clean' ],
        bintest => 'isoqlog',
        source_sub_dir => 'mail',
        %p
    );

    if ( $self->conf->{'toaster_prefix'} ne "/usr/local" ) {
        symlink( "/usr/local/share/isoqlog",
            $self->conf->{'toaster_prefix'} . "/share/isoqlog" );
    }

    if ( $self->util->find_bin( "isoqlog", fatal => 0 ) ) {
        return $self->isoqlog_conf();
    };

    return;
}

sub isoqlog_conf {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    # isoqlog doesn't honor --sysconfdir yet
    #my $etc = $self->conf->{'system_config_dir'} || "/usr/local/etc";
    my $etc  = "/usr/local/etc";
    my $file = "$etc/isoqlog.conf";

    if ( -e $file ) {
        $self->audit( "isoqlog_conf: creating $file, ok (exists)" );
        return 2;
    }

    my @lines;

    my $htdocs = $self->conf->{'toaster_http_docs'} || "/usr/local/www/data";
    my $hostn  = $self->conf->{'toaster_hostname'}  || hostname;
    my $logdir = $self->conf->{'qmail_log_base'}    || "/var/log/mail";
    my $qmaild = $self->conf->{'qmail_dir'}         || "/var/qmail";
    my $prefix = $self->conf->{'toaster_prefix'}    || "/usr/local";

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

    $self->util->file_write( $file, lines => \@lines )
        or $self->error( "couldn't write $file: $!");
    $self->audit( "isoqlog_conf: created $file, ok" );

    $self->util->syscmd( "isoqlog", fatal => 0 );

    # if missing, create the isoqlog web directory
    if ( ! -e "$htdocs/isoqlog" ) {
        mkdir oct('0755'), "$htdocs/isoqlog";
    };

    # to fix the missing images problem, add a web server alias like:
    # Alias /isoqlog/images/ "/usr/local/share/isoqlog/htmltemp/images/"
}

sub lighttpd {
    my $self = shift;
    my %p = validate( @_, { $self->get_std_opts } );
    return $p{test_ok} if defined $p{test_ok}; # for testing

    if ( ! $self->conf->{install_lighttpd} ) {
        $self->audit("skipping lighttpd install (disabled)");
        return;
    };

    if ( $OSNAME eq 'freebsd' ) {
        $self->lighttpd_freebsd();
    }
    else {
        $self->util->find_bin( 'lighttpd', fatal=>0)
            or return $self->error("no support for install lighttpd on $OSNAME. Report this error to support\@tnpi.net");
    };

    $self->lighttpd_config();
    $self->lighttpd_vhost();
    $self->php();
    $self->lighttpd_start();
    return 1;
};

sub lighttpd_freebsd {
    my $self = shift;

    $self->freebsd->install_port( 'm4',
        options => "# this file installed by mail-toaster
# Options for m4-1.4.16_1,1
_OPTIONS_READ=m4-1.4.16_1,1
_FILE_COMPLETE_OPTIONS_LIST=LIBSIGSEGV
OPTIONS_FILE_UNSET+=LIBSIGSEGV
",
    );
    $self->freebsd->install_port( 'help2man',
        options => "# this file installed by mail-toaster
# Options for help2man-1.43.2
_OPTIONS_READ=help2man-1.43.2
_FILE_COMPLETE_OPTIONS_LIST=NLS
OPTIONS_FILE_UNSET+=NLS
",
    );
    $self->freebsd->install_port( 'lighttpd',
        options => "#\n# This file was generated by mail-toaster
# Options for lighttpd-1.4.32_1
_OPTIONS_READ=lighttpd-1.4.32_1
_FILE_COMPLETE_OPTIONS_LIST=BZIP2 FAM GDBM IPV6 LDAP LIBEV LUA MEMCACHE MYSQL MYSQLAUTH NODELAY OPENSSL REMOTEUSER SPAWNFCGI VALGRIND WEBDAV
OPTIONS_FILE_SET+=BZIP2
OPTIONS_FILE_UNSET+=FAM
OPTIONS_FILE_UNSET+=GDBM
OPTIONS_FILE_UNSET+=IPV6
OPTIONS_FILE_UNSET+=LDAP
OPTIONS_FILE_UNSET+=LIBEV
OPTIONS_FILE_UNSET+=LUA
OPTIONS_FILE_UNSET+=MEMCACHE
OPTIONS_FILE_UNSET+=MYSQL
OPTIONS_FILE_UNSET+=MYSQLAUTH
OPTIONS_FILE_UNSET+=NODELAY
OPTIONS_FILE_SET+=OPENSSL
OPTIONS_FILE_UNSET+=REMOTEUSER
OPTIONS_FILE_SET+=SPAWNFCGI
OPTIONS_FILE_UNSET+=VALGRIND
OPTIONS_FILE_UNSET+=WEBDAV
",
    );

    $self->freebsd->conf_check(
        check => "lighttpd_enable",
        line  => 'lighttpd_enable="YES"',
    );

    my @logs = qw/ lighttpd.error.log lighttpd.access.log /;
    foreach ( @logs ) {
        $self->util->file_write( "/var/log/$_", lines => [' '] )
            if ! -e "/var/log/$_";
        $self->util->chown("/var/log/$_", uid => 'www', gid => 'www');
    };
};

sub lighttpd_config {
    my $self = shift;

    my $letc = '/usr/local/etc';
    $letc = "$letc/lighttpd" if -d "$letc/lighttpd";

    my $lconf = "$letc/lighttpd.conf";

    `grep toaster $letc/lighttpd.conf`
        and return $self->audit("lighttpd configuration already done");

    my $cgi_bin = $self->conf->{toaster_cgi_bin} || '/usr/local/www/cgi-bin.toaster/';
    my $htdocs = $self->conf->{toaster_http_docs} || '/usr/local/www/toaster';

    $self->config->apply_tweaks(
        file    => "$letc/lighttpd.conf",
        changes => [
            {   search  => q{#                               "mod_redirect",},
                replace => q{                                "mod_redirect",},
            },
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
                replace => qq{server.document-root        = "$htdocs/"},
            },
            {   search  => q{server.document-root = "/usr/local/www/data/"},
                replace => qq{server.document-root = "$htdocs/"},
            },
            {   search  => q{var.server_root = "/usr/local/www/data"},
                replace => qq{var.server_root = "$htdocs"},
            },
            {   search  => q{#include_shell "cat /usr/local/etc/lighttpd/vhosts.d/*.conf"},
                replace => q{include_shell "cat /usr/local/etc/lighttpd/vhosts.d/*.conf"},
            },
            {   search  => q'$SERVER["socket"] == "0.0.0.0:80" { }',
                replace => q'#$SERVER["socket"] == "0.0.0.0:80" { }',
            },
        ],
    );

    $self->config->apply_tweaks(
        file    => "$letc/modules.conf",
        changes => [
            {   search  => q{#  "mod_alias",},
                replace => q{  "mod_alias",},
            },
            {   search  => q{#  "mod_auth",},
                replace => q{  "mod_auth",},
            },
            {   search  => q{#  "mod_redirect",},
                replace => q{  "mod_redirect",},
            },
            {   search  => q{#  "mod_setenv",},
                replace => q{  "mod_setenv",},
            },
            {   search  => q{#include "conf.d/cgi.conf"},
                replace => q{include "conf.d/cgi.conf"},
            },
            {   search  => q{#include "conf.d/fastcgi.conf"},
                replace => q{include "conf.d/fastcgi.conf"},
            },
        ],
    );

    return 1;
};

sub lighttpd_start {
    my $self = shift;

    if ( $OSNAME eq 'freebsd' ) {
        system "/usr/local/etc/rc.d/lighttpd restart";
        return 1;
    }
    elsif ( $OSNAME eq 'linux' ) {
        system "service lighttpd start";
        return 1;
    };
    print "not sure how to start lighttpd on $OSNAME\n";
    return;
};

sub lighttpd_vhost {
    my $self = shift;

    my $letc = '/usr/local/etc';
    $letc = "$letc/lighttpd" if -d "$letc/lighttpd";

    my $www   = '/usr/local/www';
    my $cgi_bin = $self->conf->{toaster_cgi_bin} || "$www/cgi-bin.toaster/";
    my $htdocs = $self->conf->{toaster_http_docs} || "$www/toaster";

    my $vhost = '
alias.url = (  "/cgi-bin/"       => "' . $cgi_bin . '/",
               "/sqwebmail/"     => "' . $htdocs . '/sqwebmail/",
               "/qmailadmin/"    => "' . $htdocs . '/qmailadmin/",
               "/squirrelmail/"  => "' . $www . '/squirrelmail/",
               "/roundcube/"     => "' . $www . '/roundcube/",
               "/v-webmail/"     => "' . $www . '/v-webmail/htdocs/",
               "/horde/"         => "' . $www . '/horde/",
               "/awstatsclasses" => "' . $www . '/awstats/classes/",
               "/awstatscss"     => "' . $www . '/awstats/css/",
               "/awstatsicons"   => "' . $www . '/awstats/icons/",
               "/awstats/"       => "' . $www . '/awstats/cgi-bin/",
               "/munin/"         => "' . $www . '/munin/",
               "/rrdutil/"       => "/usr/local/rrdutil/html/",
               "/isoqlog/images/"=> "/usr/local/share/isoqlog/htmltemp/images/",
               "/phpMyAdmin/"    => "' . $www . '/phpMyAdmin/",
            )

$HTTP["url"] =~ "^/awstats/" {
    cgi.assign = ( "" => "/usr/bin/perl" )
}
$HTTP["url"] =~ "^/cgi-bin" {
    cgi.assign = ( "" => "" )
}
$HTTP["url"] =~ "^/ezmlm.cgi" {
    cgi.assign = ( "" => "/usr/bin/perl" )
}

# redirect users to a secure connection
$SERVER["socket"] == ":80" {
   $HTTP["host"] =~ "(.*)" {
      url.redirect = ( "^/(.*)" => "https://%1/$1" )
   }
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
auth.backend.htdigest.userfile = "/usr/local/etc/WebUsers"

auth.require   = (   "/isoqlog" =>
                     (
                         "method"  => "digest",
                         "realm"   => "Admins Only",
                         "require" => "valid-user"
                      ),
                     "/cgi-bin/vqadmin" =>
                     (
                         "method"  => "digest",
                         "realm"   => "Admins Only",
                         "require" => "valid-user"
                      ),
                     "/ezmlm.cgi" =>
                     (
                         "method"  => "digest",
                         "realm"   => "Admins Only",
                         "require" => "valid-user"
                      )
#                     "/munin" =>
#                     (
#                         "method"  => "digest",
#                         "realm"   => "Admins Only",
#                         "require" => "valid-user"
#                      )
                  )
';

    $self->util->file_write("$letc/vhosts.d/mail-toaster.conf", lines => [ $vhost ],);
    return 1;
};

sub logmonster {
    my $self = shift;
    my $verbose = $self->verbose;

    my %p = validate( @_, {
            fatal   => { type => BOOLEAN, optional => 1, default => 1 },
            verbose => { type => BOOLEAN, optional => 1, default => $verbose },
            test_ok => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{fatal};
       $verbose = $p{verbose};

    my $perlbin = $self->util->find_bin( "perl", verbose => $verbose );

    my @targets = ( "$perlbin Makefile.PL", "make", "make install" );
    push @targets, "make test" if $verbose;

    $self->util->install_module_from_src( 'Apache-Logmonster',
        site    => 'http://www.tnpi.net',
        archive => 'Apache-Logmonster',
        url     => '/internet/www/logmonster',
        targets => \@targets,
        verbose => $verbose,
    );
}

sub maildrop {
    require Mail::Toaster::Setup::Maildrop;
    return Mail::Toaster::Setup::Maildrop->new;
};

sub maillogs {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );
    my %args = $self->get_std_args( %p );

    return $p{test_ok} if defined $p{test_ok}; # for testing

    my $user  = $self->conf->{'qmail_log_user'}  || "qmaill";
    my $group = $self->conf->{'qmail_log_group'} || "qnofiles";
    my $logdir = $self->conf->{'qmail_log_base'} || "/var/log/mail";

    my $uid = getpwnam($user);
    my $gid = getgrnam($group);

    return $self->error( "The user $user or group $group does not exist." )
        unless ( defined $uid && defined $gid );

    $self->toaster->supervise_dirs_create( verbose=>1 );
    $self->maillogs_create_dirs();

    $self->cronolog();
    $self->isoqlog();

    $self->logs->verify_settings();
}

sub maillogs_create_dirs {
    my $self = shift;

    my $user  = $self->conf->{'qmail_log_user'}  || "qmaill";
    my $group = $self->conf->{'qmail_log_group'} || "qnofiles";
    my $uid = getpwnam($user);
    my $gid = getgrnam($group);

    # if it exists, make sure it's owned by qmail:qnofiles
    my $logdir = $self->conf->{'qmail_log_base'} || "/var/log/mail";
    if ( -w $logdir ) {
        chown( $uid, $gid, $logdir )
            or $self->error( "Couldn't chown $logdir to $uid: $!");
        $self->audit( "maillogs: set ownership of $logdir to $user",verbose=>1 );
    }

    if ( ! -d $logdir ) {
        mkdir( $logdir, oct('0755') )
            or $self->error( "maillogs: couldn't create $logdir: $!" );
        chown( $uid, $gid, $logdir )
            or $self->error( "maillogs: couldn't chown $logdir: $!");
        $self->audit( "maillogs: created $logdir", verbose=>1 );
    }

    foreach my $prot (qw/ send smtp pop3 submit /) {
        my $dir = "$logdir/$prot";
        if ( -d $dir ) {
            $self->audit( "maillogs: create $dir, (exists)", verbose=>1 );
        }
        else {
            mkdir( $dir, oct('0755') )
              or $self->error( "maillogs: couldn't create $dir: $!" );
            $self->audit( "maillogs: created $dir", verbose=>1);
        }
        chown( $uid, $gid, $dir )
          or $self->error( "maillogs: chown $dir failed: $!");
    }
};

sub mrm {

    my $self  = shift;
    my $verbose = $self->{'verbose'};

    my %p = validate( @_, {
            'fatal'   => { type => BOOLEAN, optional => 1, default => 1 },
            'verbose'   => { type => BOOLEAN, optional => 1, default => $verbose },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $fatal = $p{'fatal'};
       $verbose = $p{'verbose'};

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    my $perlbin = $self->util->find_bin( "perl" );

    my @targets = ( "$perlbin Makefile.PL", "make", "make install" );
    push @targets, "make test" if $verbose;

    $self->util->install_module_from_src(
        'Mysql-Replication',
        archive => 'Mysql-Replication.tar.gz',
        url     => '/internet/sql/mrm',
        targets => \@targets,
    );
}

sub munin {
    my $self = shift;
    my %p = validate( @_, { $self->get_std_opts } );
    return $p{test_ok} if defined $p{test_ok}; # for testing

    if ( ! $self->conf->{install_munin} ) {
        $self->audit("skipping munin install (disabled)");
        return;
    };

    $self->rrdtool();

    return $self->audit("no munin install support for $OSNAME")
        if $OSNAME ne 'freebsd';

    $self->freebsd->install_port('p5-Date-Manip');
    $self->munin_node();
    $self->freebsd->install_port('munin-master');

    return 1;
};

sub munin_node {
    my $self = shift;

    $self->freebsd->install_port('munin-node');
    $self->freebsd->conf_check(
        check => "munin_node_enable",
        line  => 'munin_node_enable="YES"',
    );

    my $locals = '';
    foreach ( @{ $self->util->get_my_ips( exclude_internals => 0 ) } ) {
        my ($a,$b,$c,$d) = split( /\./, $_ );
        $locals .= "allow ^$a\\.$b\\.$c\\.$d" . '$';
    };

    my $munin_etc = '/usr/local/etc/munin';
    $self->config->apply_tweaks(
        file => "$munin_etc/munin-node.conf",
        changes => [
            {   search => q{allow ^127\.0\.0\.1$},
                replace => q{allow ^127\.0\.0\.1$} . qq{\n$locals\n},
            }
        ],
    );

    $self->util->file_write( "$munin_etc/plugin-conf.d/plugins.conf",
        append => 1,
        lines => [ "\n[qmailqstat]\nuser qmails\nenv.qmailstat /var/qmail/bin/qmail-qstat"],
    ) if ! `grep qmailqstat "$munin_etc/plugin-conf.d/plugins.conf"`;

    my @setup_links = `/usr/local/sbin/munin-node-configure --suggest --shell`;
       @setup_links = grep {/^ln/} @setup_links;
       @setup_links = grep {!/sendmail_/} @setup_links;
       @setup_links = grep {!/ntp_/} @setup_links;

    foreach ( @setup_links ) { system $_; };

    my $t_ver = $Mail::Toaster::VERSION;
    my $dist = "/usr/local/src/Mail-Toaster-$t_ver";
    if ( -d $dist ) {
        my @plugins = qw/ qmail_rbl spamassassin /;
        foreach ( @plugins ) {
            copy("$dist/contrib/munin/$_", "$munin_etc/plugins" );
            chmod oct('0755'), "$munin_etc/plugins/$_";
        };
        copy ("$dist/contrib/logtail", "/usr/local/bin/logtail");
        chmod oct('0755'), "/usr/local/bin/logtail";
    };

    system "/usr/local/etc/rc.d/munin-node", "restart";
};

sub nictool {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts, },);

    return $p{test_ok} if defined $p{test_ok}; # for testing

    $self->conf->{'install_expat'} = 1;    # this must be set for expat to install

    $self->expat();
    $self->rsync();
    $self->djbdns();
    $self->mysql->install();

    # make sure these perl modules are installed
    $self->util->install_module( "LWP::UserAgent", port => 'p5-libwww' );
    $self->util->install_module( "SOAP::Lite");
    $self->util->install_module( "RPC::XML" );
    $self->util->install_module( "DBI" );
    $self->util->install_module( "DBD::mysql" );

    if ( $OSNAME eq "freebsd" ) {
        if ( $self->conf->{'install_apache'} == 2 ) {
            $self->freebsd->install_port( "p5-Apache-DBI", flags => "WITH_MODPERL2=yes",);
        }
    }

    $self->util->install_module( "Apache::DBI" );
    $self->util->install_module( "Apache2::SOAP" );

    # install NicTool Server
    my $perlbin   = $self->util->find_bin( "perl", fatal => 0 );
    my $version   = "NicToolServer-2.06";
    my $http_base = $self->conf->{'toaster_http_base'};

    my @targets = ( "$perlbin Makefile.PL", "make", "make install" );

    push @targets, "make test";

    push @targets, "mv ../$version $http_base"
      unless ( -d "$http_base/$version" );

    push @targets, "ln -s $http_base/$version $http_base/NicToolServer"
      unless ( -l "$http_base/NicToolServer" );

    $self->util->install_module_from_src( $version,
        archive => "$version.tar.gz",
        site    => 'http://www.nictool.com',
        url     => '/download/',
        targets => \@targets,
    );

    # install NicTool Client
    $version = "NicToolClient-2.06";
    @targets = ( "$perlbin Makefile.PL", "make", "make install" );
    push @targets, "make test";

    push @targets, "mv ../$version $http_base" if ( !-d "$http_base/$version" );
    push @targets, "ln -s $http_base/$version $http_base/NicToolClient"
      if ( !-l "$http_base/NicToolClient" );

    $self->util->install_module_from_src( $version,
        archive => "$version.tar.gz",
        site    => 'http://www.nictool.com',
        url     => '/download/',
        targets => \@targets,
    );
}

sub openssl_cert {
    my $self = shift;

    my $dir = "/usr/local/openssl/certs";
    my $csr = "$dir/server.csr";
    my $crt = "$dir/server.crt";
    my $key = "$dir/server.key";
    my $pem = "$dir/server.pem";

    $self->util->mkdir_system(dir=>$dir, verbose=>0) if ! -d $dir;

    my $openssl = $self->util->find_bin('openssl', verbose=>0);
    system "$openssl genrsa 1024 > $key" if ! -e $key;
    $self->error( "ssl cert key generation failed!") if ! -e $key;

    system "$openssl req -new -key $key -out $csr" if ! -e $csr;
    $self->error( "cert sign request ($csr) generation failed!") if ! -e $csr;

    system "$openssl req -x509 -days 999 -key $key -in $csr -out $crt" if ! -e $crt;
    $self->error( "cert generation ($crt) failed!") if ! -e $crt;

    system "cat $key $crt > $pem" if ! -e $pem;
    $self->error( "pem generation ($pem) failed!") if ! -e $pem;

    return 1;
};

sub openssl_conf {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts, },);
    return $p{test_ok} if defined $p{test_ok};

    if ( !$self->conf->{'install_openssl'} ) {
        $self->audit( "openssl: configuring, skipping (disabled)" );
        return;
    }

    return if ( defined $self->conf->{'install_openssl_conf'}
                    && !$self->conf->{'install_openssl_conf'} );

    # make sure openssl libraries are available
    $self->openssl_install();

    my $sslconf = $self->openssl_conf_find_config();

    # get/set the settings to alter
    my $country  = $self->conf->{'ssl_country'}      || "US";
    my $state    = $self->conf->{'ssl_state'}        || "Texas";
    my $org      = $self->conf->{'ssl_organization'} || "DisOrganism, Inc.";
    my $locality = $self->conf->{'ssl_locality'}     || "Dallas";
    my $name     = $self->conf->{'ssl_common_name'}  || $self->conf->{'toaster_hostname'}
      || "mail.example.com";
    my $email = $self->conf->{'ssl_email_address'}   || $self->conf->{'toaster_admin_email'}
      || "postmaster\@example.com";

    # update openssl.cnf with our settings
    my $inside;
    my $discard;
    my @lines = $self->util->file_read( $sslconf, verbose=>0 );
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
        $self->audit( "openssl: updating $sslconf, ok (no change)" );
        return 2;
    }

    my $tmpfile = "/tmp/openssl.cnf";
    $self->util->file_write( $tmpfile, lines => \@lines, verbose => 0 );
    $self->util->install_if_changed(
        newfile  => $tmpfile,
        existing => $sslconf,
        verbose    => 0,
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

    $self->error( "openssl: could not find your openssl.cnf file!") if ! -e $sslconf;
    $self->error( "openssl: no write permission to $sslconf!" ) if ! -w $sslconf;

    $self->audit( "openssl: found $sslconf, ok" );
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
    my $openssl = $self->util->find_bin( 'openssl', verbose=>0 );

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

    return if ! $self->conf->{'install_openssl'};

    if ( $OSNAME eq 'freebsd' ) {
        if (!$self->freebsd->is_port_installed( 'openssl' ) ) {
            $self->openssl_install_freebsd();
        };
    }
    else {
        my $bin = $self->util->find_bin('openssl',verbose=>0,fatal=>0);
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

    return $self->freebsd->install_port( 'openssl',
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

sub php {
    my $self = shift;

    if ( $OSNAME eq 'freebsd' ) {
        return $self->php_freebsd();
    };

    my $php = $self->util->find_bin('php',fatal=>0);
    $self->error( "no php install support for $OSNAME yet, and php is not installed. Please install and try again." );
    return;
};

sub php_freebsd {
    my $self = shift;

    my $apache = $self->conf->{install_apache} ? 'SET' : 'UNSET';

    $self->freebsd->install_port( "php5",
        category=> 'lang',
        options => "# This file generated by mail-toaster
# Options for php5-5.4.16
_OPTIONS_READ=php5-5.4.16
_FILE_COMPLETE_OPTIONS_LIST=CLI CGI FPM APACHE AP2FILTER EMBED DEBUG DTRACE IPV6 MAILHEAD LINKTHR
OPTIONS_FILE_SET+=CLI
OPTIONS_FILE_SET+=CGI
OPTIONS_FILE_UNSET+=FPM
OPTIONS_FILE_$apache+=APACHE
OPTIONS_FILE_UNSET+=AP2FILTER
OPTIONS_FILE_UNSET+=EMBED
OPTIONS_FILE_UNSET+=DEBUG
OPTIONS_FILE_UNSET+=DTRACE
OPTIONS_FILE_SET+=IPV6
OPTIONS_FILE_UNSET+=MAILHEAD
OPTIONS_FILE_UNSET+=LINKTHR
",
    ) or return;

    my $config = "/usr/local/etc/php.ini";
    if ( ! -e $config ) {
        copy("$config-production", $config) if -e "$config-production";
        chmod oct('0644'), $config;

        $self->config->apply_tweaks(
            file => "/usr/local/etc/php.ini",
            changes => [
                {   search  => q{;include_path = ".:/php/includes"},
                    replace => q{include_path = ".:/usr/local/share/pear"},
                },
                {   search  => q{;date.timezone =},
                    replace => q{date.timezone = America/Denver},
                },
            ],
        );
    };

    return 1 if -f $config;
    return;
};

sub phpmyadmin {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    unless ( $self->conf->{'install_phpmyadmin'} ) {
        print "phpMyAdmin install disabled. Set install_phpmyadmin in "
            . "toaster-watcher.conf if you want to install it.\n";
        return 0;
    }

    # prevent t1lib from installing X11
    if ( $OSNAME eq "freebsd" ) {
        $self->php();
        $self->freebsd->install_port( "t1lib", flags => "WITHOUT_X11=yes" );
        $self->freebsd->install_port( "php5-gd" );
    }

    $self->mysql->phpmyadmin_install;
}

sub portmaster {
    my $self = shift;

    if ( ! $self->conf->{install_portmaster} ) {
        $self->audit("install portmaster skipped, not selected", verbose=>1);
        return;
    };

    $self->freebsd->install_port( "portmaster" );
};

sub ports {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    return $self->freebsd->update_ports() if $OSNAME eq "freebsd";
    return $self->darwin->update_ports()  if $OSNAME eq "darwin";

    print "Sorry, no ports support for $OSNAME yet.\n";
    return;
}

sub qmailadmin {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok};

    my $ver = $self->conf->{'install_qmailadmin'} or do {
        $self->audit( "skipping qmailadmin install, it's not selected!");
        return;
    };

    my $package = "qmailadmin-$ver";
    my $site    = "http://" . $self->conf->{'toaster_sf_mirror'};
    my $url     = "/qmailadmin/qmailadmin-stable/$ver";

    my $toaster = "$self->conf->{'toaster_dl_site'}$self->conf->{'toaster_dl_url'}";
    $toaster ||= "http://mail-toaster.org";

    my $cgi     = $self->conf->{'qmailadmin_cgi-bin_dir'};

    unless ( $cgi && -e $cgi ) {
        $cgi = $self->conf->{'toaster_cgi_bin'};
        mkpath $cgi if ! -e $cgi;

        unless ( $cgi && -e $cgi ) {
            my $httpdir = $self->conf->{'toaster_http_base'} || "/usr/local/www";
            $cgi = "$httpdir/cgi-bin";
            $cgi = "$httpdir/cgi-bin.mail" if -d "$httpdir/cgi-bin.mail";
        }
    }

    my $docroot = $self->conf->{'qmailadmin_http_docroot'};
    unless ( $docroot && -e $docroot ) {
        $docroot = $self->conf->{'toaster_http_docs'};
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
    $help++ if $self->conf->{'qmailadmin_help_links'};

    if ( $ver eq "port" ) {
        if ( $OSNAME ne "freebsd" ) {
            print
              "FAILURE: Sorry, no port install of qmailadmin (yet). Please edit
toaster-watcher.conf and select a version of qmailadmin to install.\n";
            return 0;
        }

        $self->qmailadmin_freebsd_port();
        $self->qmailadmin_help() if $help;
        return 1;
    }

    my $conf_args;

    if ( -x "$cgi/qmailadmin" ) {
        return 0
          unless $self->util->yes_or_no(
            "qmailadmin is installed, do you want to reinstall?",
            timeout  => 60,
          );
    }

    if ( $self->conf->{'qmailadmin_domain_autofill'} ) {
        $conf_args = " --enable-domain-autofill=Y";
        print "domain autofill: yes\n";
    }

    if ( $self->util->yes_or_no( "\nDo you want spam options? " ) ) {
        $conf_args .=
            " --enable-modify-spam=Y"
            . " --enable-spam-command=\""
            . $self->conf->{'qmailadmin_spam_command'} . "\"";
    }

    if ( $self->conf->{'qmailadmin_modify_quotas'} ) {
        $conf_args .= " --enable-modify-quota=y";
        print "modify quotas: yes\n";
    }

    if ( $self->conf->{'qmailadmin_install_as_root'} ) {
        $conf_args .= " --enable-vpopuser=root";
        print "install as root: yes\n";
    }

    $conf_args .= " --enable-htmldir=" . $docroot . "/qmailadmin";
    $conf_args .= " --enable-imagedir=" . $docroot . "/qmailadmin/images";
    $conf_args .= " --enable-imageurl=/qmailadmin/images";
    $conf_args .= " --enable-cgibindir=" . $cgi;
    $conf_args .= " --enable-autoresponder-path=".$self->conf->{'toaster_prefix'}."/bin";

    if ( defined $self->conf->{'qmailadmin_catchall'} ) {
        $conf_args .= " --disable-catchall" if ! $self->conf->{'qmailadmin_catchall'};
    };

    if ( $self->conf->{'qmailadmin_help_links'} ) {
        $conf_args .= " --enable-help=y";
        $help = 1;
    }

    if ( $OSNAME eq "darwin" ) {
        my $vpopdir = $self->conf->{'vpopmail_home_dir'} || "/usr/local/vpopmail";
        $self->util->syscmd( "ranlib $vpopdir/lib/libvpopmail.a", verbose => 0 );
    }

    my $make = $self->util->find_bin( "gmake", fatal=>0, verbose=>0) ||
        $self->util->find_bin( "make", verbose=>0 );

    $self->util->install_from_source(
        package   => $package,
        site      => $site,
        url       => $url,
        targets   =>
          [ "./configure " . $conf_args, "$make", "$make install-strip" ],
        source_sub_dir => 'mail',
    );

    $self->qmailadmin_help() if $help;

    return 1;
}

sub qmailadmin_help {
    my $self = shift;

    my $ver     = $self->conf->{'qmailadmin_help_links'} or return;
    my $cgi     = $self->conf->{'qmailadmin_cgi-bin_dir'};
    my $docroot = $self->conf->{qmailadmin_http_docroot} || $self->conf->{toaster_http_docs};
    my $helpdir = $docroot . "/qmailadmin/images/help";

    if ( -d $helpdir ) {
        $self->audit( "qmailadmin: installing help files, ok (exists)" );
        return 1;
    }

    my $src  = $self->conf->{'toaster_src_dir'} || "/usr/local/src";
       $src .= "/mail";

    print "qmailadmin: Installing help files in $helpdir\n";
    $self->util->cwd_source_dir( $src );

    my $helpfile = "qmailadmin-help-$ver";
    unless ( -e "$helpfile.tar.gz" ) {
        $self->util->get_url(
            "http://".$self->conf->{toaster_sf_mirror}."/qmailadmin/qmailadmin-help/$ver/$helpfile.tar.gz"
        );
    }

    if ( !-e "$helpfile.tar.gz" ) {
        carp "qmailadmin: FAILED: help files couldn't be downloaded!\n";
        return;
    }

    $self->util->extract_archive( "$helpfile.tar.gz" );

    move( $helpfile, $helpdir ) or
        $self->error( "Could not move $helpfile to $helpdir");

    $self->audit( "qmailadmin: installed help files, ok" );
}

sub qmailadmin_freebsd_port {
    my $self = shift;
    my $conf = $self->conf;
    my $cgi = $conf->{qmailadmin_cgi_bin_dir} || $conf->{toaster_cgi_bin};
    my $docroot = $conf->{qmailadmin_http_docroot} || $conf->{toaster_http_docs};

    my ( $cgi_sub, $docroot_sub );

    my $help = $conf->{qmailadmin_help_links} ? 'SET' : 'UNSET';
    my $catchall = $conf->{qmailadmin_catchall} ? 'SET' : 'UNSET';
    my $quotam   = $conf->{qmailadmin_modify_quotas} ? 'SET' : 'UNSET';
    my $domauto  = $conf->{qmailadmin_domain_autofill} ? 'SET' : 'UNSET';
    my $spam     = $conf->{'qmailadmin_spam_option'} ? 'SET' : 'UNSET';

    my @args = 'CGIBINSUBDIR=""';

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
    push @args, 'QMAIL_DIR="'.$conf->{'qmail_dir'}.'"'
        if $conf->{'qmail_dir'} ne '/var/qmail';

    if ( $spam eq 'SET' && $conf->{'qmailadmin_spam_command'} ) {
        push @args, 'SPAM_COMMAND="'.$conf->{'qmailadmin_spam_command'}.'"';
    }

    $self->freebsd->install_port( "qmailadmin",
            flags => join( ',', @args ),
            options => "# This file installed by mail::toaster
# Options for qmailadmin-1.2.15_5,2
_OPTIONS_READ=qmailadmin-1.2.15_5,2
_FILE_COMPLETE_OPTIONS_LIST=CATCHALL DOMAIN_AUTOFILL HELP IDX IDX_SQL IPAUTH MODIFY_QUOTA NOCACHE SPAM_DETECTION SPAM_NEEDS_EMAIL TRIVIAL_PASSWORD USER_INDEX
OPTIONS_FILE_$catchall+=CATCHALL
OPTIONS_FILE_SET+=DOMAIN_AUTOFILL
OPTIONS_FILE_$help+=HELP
OPTIONS_FILE_SET+=IDX
OPTIONS_FILE_UNSET+=IDX_SQL
OPTIONS_FILE_SET+=IPAUTH
OPTIONS_FILE_$quotam+=MODIFY_QUOTA
OPTIONS_FILE_UNSET+=NOCACHE
OPTIONS_FILE_$spam+=SPAM_DETECTION
OPTIONS_FILE_UNSET+=SPAM_NEEDS_EMAIL
OPTIONS_FILE_SET+=TRIVIAL_PASSWORD
OPTIONS_FILE_SET+=USER_INDEX
",
            );

    if ( $conf->{'qmailadmin_install_as_root'} ) {
        my $gid = getgrnam("vchkpw");
        chown( 0, $gid, "/usr/local/$cgi_sub/qmailadmin" );
    }
}

sub qpsmtpd {
    my $self = shift;

# install Qmail::Deliverable
# install vpopmaild service

# install qpsmtpd
print '
- git clone https://github.com/qpsmtpd-dev/qpsmtpd-dev
- cp -r config.sample config
- chown smtpd:smtpd qpsmtpd
- chmod +s qpsmtpd
';

# install qpsmtpd service
print '
- services stop
- rm /var/service/smtp
- stop toaster-watcher and do previous step again
- ln -s /usr/local/src/qpsmtpd-dev/  /var/serivces/qpsmtpd
- cp /var/qmail/supervise/smtp/log/run log/run
';

# install qpsmtpd SSL certs
print '
- add clamav user to smtpd user group
- echo 0770 > config/spool_perms   # Hmmmm... quite open.. how did we do
this with current toaster? clamav needs to read vpopmail files
- echo /var/spool/clamd > spool_dir
- edits in config/plugins
  - disable: ident/geoip
  - disable: quit_fortune
  - enable: auth/auth_checkpassword
checkpw /usr/local/vpopmail/bin/vchkpw true /usr/bin/true
  - disable: auth/auth_flat_file
  - disable: dspam learn_from_sa 7 reject 1
  - enable: virus/clamdscan deny_viruses yes
clamd_socket /var/run/clamav/clamd.sock max_size 3072
  - enable: queue/qmail-queue
  - enable: sender_permitted_from
  - install Qmail::Deliverable
  - enable: qmail_deliverable
  - install clamav::client
- edit run file QPUSER=vpopmail
- services start
- clamdscan plugin modification:

# cat qmail-deliverable/run
#!/bin/sh
MAXRAM=50000000
BIN=/usr/local/bin
PATH=/usr/local/vpopmail/bin
exec $BIN/softlimit -m $MAXRAM $BIN/qmail-deliverabled -f 2>&1

# cat vpopmaild/run
#!/bin/sh
BIN=/usr/local/bin
VPOPDIR=/usr/local/vpopmail
exec 2>&1
exec $BIN/tcpserver -vHRD 127.0.0.1 89 $VPOPDIR/bin/vpopmaild
';

};

sub razor {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    my $ver = $self->conf->{'install_razor'} or do {
        $self->audit( "razor: installing, skipping (disabled)" );
        return;
    };

    return $p{test_ok} if defined $p{test_ok}; # for testing

    $self->util->install_module( "Digest::Nilsimsa" );
    $self->util->install_module( "Digest::SHA1" );

    if ( $ver eq "port" ) {
        if ( $OSNAME eq "freebsd" ) {
            $self->freebsd->install_port( "razor-agents" );
        }
        elsif ( $OSNAME eq "darwin" ) {
            # old ports tree, deprecated
            $self->darwin->install_port( "razor" );
            # this one should work
            $self->darwin->install_port( "p5-razor-agents" );
        }
    }

    if ( $self->util->find_bin( "razor-client", fatal => 0 ) ) {
        print "It appears you have razor installed, skipping manual build.\n";
        $self->razor_config();
        return 1;
    }

    $ver = "2.80" if ( $ver == 1 || $ver eq "port" );

    $self->util->install_module_from_src( 'razor-agents-' . $ver,
        archive => 'razor-agents-' . $ver . '.tar.gz',
        site    => 'http://umn.dl.sourceforge.net/sourceforge',
        url     => '/razor',
    );

    $self->razor_config();
    return 1;
}

sub razor_config {
    my $self  = shift;

    print "razor: beginning configuration.\n";

    if ( -d "/etc/razor" ) {
        print "razor_config: it appears you have razor configured, skipping.\n";
        return 1;
    }

    my $client = $self->util->find_bin( "razor-client", fatal => 0 );
    my $admin  = $self->util->find_bin( "razor-admin",  fatal => 0 );

    # for old versions of razor
    if ( -x $client && !-x $admin ) {
        $self->util->syscmd( $client, verbose=>0 );
    }

    unless ( -x $admin ) {
        print "FAILED: couldn't find $admin!\n";
        return 0;
    }

    $self->util->syscmd( "$admin -home=/etc/razor -create -d", verbose=>0 );
    $self->util->syscmd( "$admin -home=/etc/razor -register -d", verbose=>0 );

    my $file = "/etc/razor/razor-agent.conf";
    if ( -e $file ) {
        my @lines = $self->util->file_read( $file );
        foreach my $line (@lines) {
            if ( $line =~ /^logfile/ ) {
                $line = 'logfile                = /var/log/razor-agent.log';
            }
        }
        $self->util->file_write( $file, lines => \@lines, verbose=>0 );
    }

    $file = "/etc/newsyslog.conf";
    if ( -e $file ) {
        if ( !`grep razor-agent $file` ) {
            $self->util->file_write( $file,
                lines  => ["/var/log/razor-agent.log	600	5	1000 *	Z"],
                append => 1,
                verbose  => 0,
            );
        }
    }

    print "razor: configuration completed.\n";
    return 1;
}

sub refresh_config {
    my ($self, $file_path) = @_;

    if ( ! -f $file_path ) {
        $self->audit( "config: $file_path is missing!, FAILED" );
        return;
    };

    warn "found: $file_path \n" if $self->{verbose};

    # refresh our $conf
    my $conf = $self->util->parse_config( $file_path,
        verbose => $self->{verbose},
        fatal => $self->{fatal},
    );

    $self->set_config($conf);

    warn "refreshed \$conf from: $file_path \n" if $self->{verbose};
    return $conf;
};

sub ripmime {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    return $p{test_ok} if defined $p{test_ok}; # for testing

    my $ver = $self->conf->{'install_ripmime'};
    if ( !$ver ) {
        print "ripmime install not selected.\n";
        return 0;
    }

    print "rimime: installing...\n";

    if ( $ver eq "port" || $ver eq "1" ) {

        if ( $self->util->find_bin( "ripmime", fatal => 0 ) ) {
            print "ripmime: already installed...done.\n\n";
            return 1;
        }

        if ( $OSNAME eq "freebsd" ) {
            $self->freebsd->install_port( "ripmime" ) and return 1;
        }
        elsif ( $OSNAME eq "darwin" ) {
            $self->darwin->install_port( "ripmime" ) and return 1;
        }

        if ( $self->util->find_bin( "ripmime", fatal => 0 ) ) {
            print "ripmime: ripmime has been installed successfully.\n";
            return 1;
        }

        $ver = "1.4.0.6";
    }

    my $ripmime = $self->util->find_bin( "ripmime", fatal => 0 );
    if ( -x $ripmime ) {
        my $installed = `$ripmime -V`;
        ($installed) = $installed =~ /v(.*) - /;

        if ( $ver eq $installed ) {
            print "ripmime: version ($ver) is already installed!\n";
            return 1;
        }
    }

    $self->util->install_from_source(
        package        => "ripmime-$ver",
        site           => 'http://www.pldaniels.com',
        url            => '/ripmime',
        targets        => [ 'make', 'make install' ],
        bintest        => 'ripmime',
        verbose        => 1,
        source_sub_dir => 'mail',
    );
}

sub rrdtool {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);
    return $p{test_ok} if defined $p{test_ok}; # for testing

    unless ( $self->conf->{'install_rrdutil'} ) {
        print "install_rrdutil is not set in toaster-watcher.conf! Skipping.\n";
        return;
    }

    if ( $OSNAME eq "freebsd" ) {

# the newer (default) version of rrdtool requires an obscene amount
# of x11 software be installed. Install the older one instead.
        $self->freebsd->install_port('rrdtool',
            dir     => 'rrdtool12',
            options => "#\n# Options for rrdtool-1.2.30_1
    _OPTIONS_READ=rrdtool-1.2.30_1
    WITHOUT_PYTHON_MODULE=true
    WITHOUT_RUBY_MODULE=true
    WITH_PERL_MODULE=true\n",
        );
    }
    elsif ( $OSNAME eq "darwin" ) {
        $self->darwin->port_install( port_name => "rrdtool" );
    }

    return 1 if -x $self->util->find_bin( 'rrdtool', fatal => 0 );

    $self->util->install_from_source(
        package => "rrdtool-1.2.23",
        site    => 'http://people.ee.ethz.ch',
        url     => '/~oetiker/webtools/rrdtool/pub',
        targets => [ './configure', 'make', 'make install' ],
        patches => [ ],
        bintest => 'rrdtool',
        verbose   => 1,
    );
}

sub roundcube {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    return $p{test_ok} if defined $p{test_ok}; # for testing

    if ( ! $self->conf->{'install_roundcube'} ) {
        $self->audit( "not installing roundcube, not selected!" );
        return;
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

    $self->sqlite_freebsd();

    $self->freebsd->install_port( "roundcube",
        category=> 'mail',
        options => "# Options for roundcube-0.9.2,1
_OPTIONS_READ=roundcube-0.9.2,1
_FILE_COMPLETE_OPTIONS_LIST=GD LDAP NSC PSPELL SSL MYSQL PGSQL SQLITE
OPTIONS_FILE_UNSET+=GD
OPTIONS_FILE_UNSET+=LDAP
OPTIONS_FILE_UNSET+=NSC
OPTIONS_FILE_UNSET+=PSPELL
OPTIONS_FILE_SET+=SSL
OPTIONS_FILE_UNSET+=MYSQL
OPTIONS_FILE_UNSET+=PGSQL
OPTIONS_FILE_SET+=SQLITE
",
    ) or return;

    $self->roundcube_config();
};

sub roundcube_config {
    my $self = shift;
    my $rcdir = "/usr/local/www/roundcube";
    my $config = "$rcdir/config";

    foreach my $c ( qw/ db.inc.php main.inc.php / ) {
        copy( "$config/$c.dist", "$config/$c" ) if ! -e "$config/$c";
    };

    if ( ! -f "$config/db.inc.php" ) {
        warn "unable to find roundcube/config/db.inc.php. Edit it with appropriate DSN settings\n";
        return;
    };

    $self->config->apply_tweaks(
        file => "$config/main.inc.php",
        changes => [
            {   search  => q{$rcmail_config['default_host'] = '';},
                replace => q{$rcmail_config['default_host'] = 'localhost';},
            },
            {   search  => q{$rcmail_config['session_lifetime'] = 10;},
                replace => q{$rcmail_config['session_lifetime'] = 30;},
            },
            {   search  => q{$rcmail_config['imap_auth_type'] = null;},
                replace => q{$rcmail_config['imap_auth_type'] = plain;},
            },
        ],
    );

    return $self->roundcube_config_sqlite();
};

sub roundcube_config_sqlite {
    my $self = shift;

    my $rcdir = "/usr/local/www/roundcube";
    my $config = "$rcdir/config/db.inc.php";

    my $spool = '/var/spool/roundcubemail';
    mkpath $spool;
    my (undef,undef,$uid,$gid) = getpwnam('www');
    chown $uid, $gid, $spool;

    # configure roundcube to use sqlite for DB
    $self->config->apply_tweaks(
        file => $config,
        changes => [
            {   search  => q{$rcmail_config['db_dsnw'] = 'mysql://roundcube:pass@localhost/roundcubemail';},
                replace => q{$rcmail_config['db_dsnw'] = 'sqlite:////var/spool/roundcubemail/sqlite.db?mode=0646';},
            },
        ],
    );
};

sub rsync {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    return $p{test_ok} if defined $p{test_ok}; # for testing

    if ( $OSNAME eq "freebsd" ) {
        $self->freebsd->install_port( "rsync",
            options => "#\n
# This file was generated by mail-toaster
# Options for rsync-3.0.9_3
_OPTIONS_READ=rsync-3.0.9_3
_FILE_COMPLETE_OPTIONS_LIST=ACL ATIMES DOCS FLAGS ICONV POPT_PORT RENAMED SSH TIMELIMIT
OPTIONS_FILE_UNSET+=ACL
OPTIONS_FILE_UNSET+=ATIMES
OPTIONS_FILE_SET+=DOCS
OPTIONS_FILE_UNSET+=FLAGS
OPTIONS_FILE_UNSET+=ICONV
OPTIONS_FILE_UNSET+=POPT_PORT
OPTIONS_FILE_UNSET+=RENAMED
OPTIONS_FILE_SET+=SSH
OPTIONS_FILE_UNSET+=TIMELIMIT\n",
        );
    }
    elsif ( $OSNAME eq "darwin" ) {
        $self->darwin->install_port( "rsync" );
    }
    else {
        die
"please install rsync manually. Support for $OSNAME is not available yet.\n";
    }

    return $self->util->find_bin('rsync',verbose=>0);
}

sub set_config {
    my $self = shift;
    my $newconf = shift;
    return $self->conf if ! $newconf;
    $self->conf( $newconf );
    return $newconf;
};

sub simscan {
    require Mail::Toaster::Setup::Simscan;
    return Mail::Toaster::Setup::Simscan->new;
}

sub socklog {
    my $self  = shift;
    my %p = validate( @_, { 'ip' => SCALAR, $self->get_std_opts, },);

    my $ip    = $p{'ip'};

    my $user  = $self->conf->{'qmail_log_user'}  || "qmaill";
    my $group = $self->conf->{'qmail_log_group'} || "qnofiles";

    my $uid = getpwnam($user);
    my $gid = getgrnam($group);

    my $logdir = $self->conf->{'qmail_log_base'};
    unless ( -d $logdir ) { $logdir = "/var/log/mail" }

    if ( $OSNAME eq "freebsd" ) {
        $self->freebsd->install_port( "socklog" );
    }
    else {
        print "\n\nNOTICE: Be sure to install socklog!!\n\n";
    }
    $self->socklog_qmail_control( "send", $ip, $user, undef, $logdir );
    $self->socklog_qmail_control( "smtp", $ip, $user, undef, $logdir );
    $self->socklog_qmail_control( "pop3", $ip, $user, undef, $logdir );

    unless ( -d $logdir ) {
        mkdir( $logdir, oct('0755') ) or croak "socklog: couldn't create $logdir: $!";
        chown( $uid, $gid, $logdir ) or croak "socklog: couldn't chown  $logdir: $!";
    }

    foreach my $prot (qw/ send smtp pop3 /) {
        unless ( -d "$logdir/$prot" ) {
            mkdir( "$logdir/$prot", oct('0755') )
              or croak "socklog: couldn't create $logdir/$prot: $!";
        }
        chown( $uid, $gid, "$logdir/$prot" )
          or croak "socklog: couldn't chown $logdir/$prot: $!";
    }
}

sub socklog_qmail_control {
    my ( $self, $serv, $ip, $user, $supervise, $log ) = @_;

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
    $self->util->file_write( $run_f, lines => \@socklog_run_file );

#	open(my $RUN, ">", $run_f) or croak "socklog_qmail_control: couldn't open for write: $!";
#	close $RUN;
    chmod oct('0755'), $run_f or croak "socklog: couldn't chmod $run_f: $!";
    print "done.\n";
}

sub spamassassin {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    return $p{test_ok} if defined $p{test_ok};

    if ( !$self->conf->{'install_spamassassin'} ) {
        $self->audit( "spamassassin: installing, skipping (disabled)" );
        return;
    }

    if ( $OSNAME eq "freebsd" ) {
        $self->spamassassin_freebsd();
    }
    elsif ( $OSNAME eq "darwin" ) {
        $self->darwin->install_port( "procmail" )
            if $self->conf->{'install_procmail'};
        $self->darwin->install_port( "unzip" );
        $self->darwin->install_port( "p5-mail-audit" );
        $self->darwin->install_port( "p5-mail-spamassassin" );
        $self->darwin->install_port( "bogofilter" ) if $self->conf->{'install_bogofilter'};
    }

    $self->util->install_module( "Time::HiRes" );
    $self->util->install_module( "Mail::Audit" );
    $self->util->install_module( "HTML::Parser" );
    $self->util->install_module( "Archive::Tar" );
    $self->util->install_module( "NetAddr::IP" );
    $self->util->install_module( "LWP::UserAgent" );  # used by sa-update
    $self->util->install_module( "Mail::SpamAssassin" );
    $self->maildrop->install;

    $self->spamassassin_sql();
}

sub spamassassin_freebsd {
    my $self = shift;

    my $mysql = "WITHOUT_MYSQL=true";
    if ( $self->conf->{install_spamassassin_sql} ) {
        $mysql = "WITH_MYSQL=true";
    };

    $self->freebsd->install_port( "p5-Mail-SPF",
        options => "# Options for p5-Mail-SPF-2.007_3
_OPTIONS_READ=p5-Mail-SPF-2.007_3
_FILE_COMPLETE_OPTIONS_LIST=DOCS
OPTIONS_FILE_UNSET+=DOCS
",
    );
    $self->freebsd->install_port( "p5-Mail-SpamAssassin",
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
WITH_GNUPG=true
$mysql
WITHOUT_PGSQL=true
WITH_RAZOR=true
WITH_SPF_QUERY=true
WITH_RELAY_COUNTRY=true",
        verbose => 0,
    );

    # the old port didn't install the spamd.sh file
    # new versions install sa-spamd.sh and require the rc.conf flag
    my $start = -f "/usr/local/etc/rc.d/spamd.sh" ? "/usr/local/etc/rc.d/spamd.sh"
                : -f "/usr/local/etc/rc.d/spamd"    ? "/usr/local/etc/rc.d/spamd"
                : "/usr/local/etc/rc.d/sa-spamd";   # current location, 9/23/06

    my $flags = $self->conf->{'install_spamassassin_flags'};

    $self->freebsd->conf_check(
        check => "spamd_enable",
        line  => 'spamd_enable="YES"',
        verbose => 0,
    );

    $self->freebsd->conf_check(
        check => "spamd_flags",
        line  => qq{spamd_flags="$flags"},
        verbose => 0,
    );

    $self->gnupg_install();
    $self->spamassassin_update();

    unless ( $self->util->is_process_running("spamd") ) {
        if ( -x $start ) {
            print "Starting SpamAssassin...";
            $self->util->syscmd( "$start restart", verbose=>0 );
            print "done.\n";
        }
        else { print "WARN: couldn't start SpamAssassin's spamd.\n"; }
    }
};

sub spamassassin_sql {

    # set up the mysql database for use with SpamAssassin
    # http://svn.apache.org/repos/asf/spamassassin/branches/3.0/sql/README

    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    return $p{test_ok} if defined $p{test_ok}; # for testing

    if ( ! $self->conf->{'install_mysql'} || ! $self->conf->{'install_spamassassin_sql'} ) {
        print "SpamAssasin MySQL integration not selected. skipping.\n";
        return 0;
    }

    if ( $OSNAME eq "freebsd" ) {
        $self->spamassassin_sql_freebsd();
    }
    else {
        $self->spamassassin_sql_manual();
    };
};

sub spamassassin_sql_manual {
    my $self = shift;

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
	user_scores_sql_username        $self->conf->{'install_spamassassin_dbuser'}
	user_scores_sql_password        $self->conf->{'install_spamassassin_dbpass'}

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
	bayes_sql_username              $self->conf->{'install_spamassassin_dbuser'}
	bayes_sql_password              $self->conf->{'install_spamassassin_dbpass'}
	#bayes_sql_override_username    someusername

	auto_whitelist_factory       Mail::SpamAssassin::SQLBasedAddrList
	user_awl_dsn                 DBI:mysql:spamassassin:localhost
	user_awl_sql_username        $self->conf->{'install_spamassassin_dbuser'}
	user_awl_sql_password        $self->conf->{'install_spamassassin_dbpass'}
	user_awl_sql_table           awl
";
};

sub spamassassin_sql_freebsd {
    my $self = shift;

    # is SpamAssassin installed?
    if ( ! $self->freebsd->is_port_installed( "p5-Mail-SpamAssassin" ) ) {
        print "SpamAssassin is not installed, skipping database setup.\n";
        return;
    }

    # have we been here already?
    if ( -f "/usr/local/etc/mail/spamassassin/sql.cf" ) {
        print "SpamAssassin database setup already done...skipping.\n";
        return 1;
    };

    print "SpamAssassin is installed, setting up MySQL databases\n";

    my $user = $self->conf->{'install_spamassassin_dbuser'};
    my $pass = $self->conf->{'install_spamassassin_dbpass'};

    my $dot = $self->mysql->parse_dot_file( ".my.cnf", "[mysql]", 0 );
    my ( $dbh, $dsn, $drh ) = $self->mysql->connect( $dot, 1 );

    if ($dbh) {
        my $query = "use spamassassin";
        my $sth = $self->mysql->query( $dbh, $query, 1 );
        if ( $sth->errstr ) {
            print "oops, no spamassassin database.\n";
            print "creating MySQL spamassassin database.\n";
            $query = "CREATE DATABASE spamassassin";
            $sth   = $self->mysql->query( $dbh, $query );
            $query =
"GRANT ALL PRIVILEGES ON spamassassin.* TO $user\@'localhost' IDENTIFIED BY '$pass'";
            $sth = $self->mysql->query( $dbh, $query );
            $sth = $self->mysql->query( $dbh, "flush privileges" );
            $sth->finish;
        }
        else {
            print "spamassassin: spamassassin database exists!\n";
            $sth->finish;
        }
    }

    my $mysqlbin = $self->util->find_bin( 'mysql', fatal => 0 );
    if ( ! -x $mysqlbin ) {
        $mysqlbin = $self->util->find_bin( 'mysql5' );
    };
    my $sqldir = "/usr/local/share/doc/p5-Mail-SpamAssassin/sql";
    foreach my $f (qw/bayes_mysql.sql awl_mysql.sql userpref_mysql.sql/) {
        if ( ! -f "$sqldir/$f" ) {
            warn "missing .sql file: $f\n";
            next;
        };
        if ( `grep MyISAM "$sqldir/$f"` ) {
            my @lines = $self->util->file_read( "$sqldir/$f" );
            foreach my $line (@lines) {
                if ( $line eq ') TYPE=MyISAM;' ) {
                    $line = ');';
                };
            };
            $self->util->file_write( "$sqldir/$f", lines=>\@lines );
        };
        $self->util->syscmd( "$mysqlbin spamassassin < $sqldir/$f" );
    }

    my $file = "/usr/local/etc/mail/spamassassin/sql.cf";
    unless ( -f $file ) {
        my @lines = <<EO_SQL_CF;
loadplugin Mail::SpamAssassin::Plugin::AWL

user_scores_dsn                 DBI:mysql:spamassassin:localhost
user_scores_sql_username        $self->conf->{'install_spamassassin_dbuser'}
user_scores_sql_password        $self->conf->{'install_spamassassin_dbpass'}
#user_scores_sql_table           userpref

bayes_store_module              Mail::SpamAssassin::BayesStore::SQL
bayes_sql_dsn                   DBI:mysql:spamassassin:localhost
bayes_sql_username              $self->conf->{'install_spamassassin_dbuser'}
bayes_sql_password              $self->conf->{'install_spamassassin_dbpass'}
#bayes_sql_override_username    someusername

auto_whitelist_factory          Mail::SpamAssassin::SQLBasedAddrList
user_awl_dsn                    DBI:mysql:spamassassin:localhost
user_awl_sql_username           $self->conf->{'install_spamassassin_dbuser'}
user_awl_sql_password           $self->conf->{'install_spamassassin_dbpass'}
user_awl_sql_table              awl
EO_SQL_CF
        $self->util->file_write( $file, lines => \@lines );
    }
}

sub spamassassin_update {
    my $self = shift;

    my $update = $self->util->find_bin( "sa-update", fatal => 0 ) or return;
    system $update and do {
        $self->error( "error updating spamassassin rules", fatal => 0);
    };
    $self->audit( "trying again without GPG" );

    system "$update --nogpg" and
        return $self->error( "error updating spamassassin rules", fatal => 0);

    return 1;
};

sub sqlite_freebsd {
    my $self = shift;

    $self->freebsd->install_port( 'icu',
        options => "# Options for icu-50.1.2
_OPTIONS_READ=icu-50.1.2
_FILE_COMPLETE_OPTIONS_LIST=THREADS
OPTIONS_FILE_SET+=THREADS
",
    );

    $self->freebsd->install_port( 'sqlite',
        options => "
# Options for sqlite3-3.7.17_1
_OPTIONS_READ=sqlite3-3.7.17_1
_FILE_COMPLETE_OPTIONS_LIST=DIRECT_READ EXTENSION FTS3 ICU MEMMAN METADATA RAMTABLE RTREE SECURE_DELETE SOUNDEX STAT3 THREADSAFE UNLOCK_NOTIFY UPD_DEL_LIMIT URI
OPTIONS_FILE_UNSET+=DIRECT_READ
OPTIONS_FILE_SET+=EXTENSION
OPTIONS_FILE_SET+=FTS3
OPTIONS_FILE_SET+=ICU
OPTIONS_FILE_UNSET+=MEMMAN
OPTIONS_FILE_SET+=METADATA
OPTIONS_FILE_UNSET+=RAMTABLE
OPTIONS_FILE_UNSET+=RTREE
OPTIONS_FILE_SET+=SECURE_DELETE
OPTIONS_FILE_UNSET+=SOUNDEX
OPTIONS_FILE_UNSET+=STAT3
OPTIONS_FILE_SET+=THREADSAFE
OPTIONS_FILE_SET+=UNLOCK_NOTIFY
OPTIONS_FILE_UNSET+=UPD_DEL_LIMIT
OPTIONS_FILE_SET+=URI
",
    );
}

sub squirrelmail {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    return $p{test_ok} if defined $p{test_ok}; # for testing

    my $ver = $self->conf->{'install_squirrelmail'} or do {
        $self->audit( 'skipping squirrelmail install (disabled)');
        return;
    };

    if ( $OSNAME eq "freebsd" && $ver eq "port" ) {
        $self->php();
        $self->squirrelmail_freebsd() and return;
    };

    $ver = "1.4.6" if $ver eq 'port';

    print "squirrelmail: attempting to install from sources.\n";

    my $htdocs = $self->conf->{'toaster_http_docs'} || "/usr/local/www/data";
    my $srcdir = $self->conf->{'toaster_src_dir'}   || "/usr/local/src";
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

    $self->util->install_from_source(
        package        => "squirrelmail-$ver",
        site           => "http://" . $self->conf->{'toaster_sf_mirror'},
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
    push @squirrel_flags, 'WITH_APACHE2=1' if ( $self->conf->{'install_apache'} == 2 );
    push @squirrel_flags, 'WITH_DATABASE=1' if $self->conf->{'install_squirrelmail_sql'};

    $self->freebsd->install_port( "squirrelmail",
        flags => join(',', @squirrel_flags),
    );
    $self->freebsd->install_port( "squirrelmail-quota_usage-plugin" );

    return if ! $self->freebsd->is_port_installed( "squirrelmail" );
    my $sqdir = "/usr/local/www/squirrelmail";
    return if ! -d $sqdir;

    $self->squirrelmail_config();
    $self->squirrelmail_mysql();

    return 1;
}

sub squirrelmail_mysql {
    my $self  = shift;

    return if ! $self->conf->{'install_mysql'};
    return if ! $self->conf->{'install_squirrelmail_sql'};

    if ( $OSNAME eq "freebsd" ) {
        $self->freebsd->install_port( "pear-DB" );

        print
'\nHEY!  You need to add include_path = ".:/usr/local/share/pear" to php.ini.\n\n';

        $self->freebsd->install_port( "php5-mysql" );
        $self->freebsd->install_port( "squirrelmail-sasql-plugin" );
    }

    my $db   = "squirrelmail";
    my $user = "squirrel";
    my $pass = $self->conf->{'install_squirrelmail_sql_pass'} || "secret";
    my $host = "localhost";

    my $dot = $self->mysql->parse_dot_file( ".my.cnf", "[mysql]", 0 );
    my ( $dbh, $dsn, $drh ) = $self->mysql->connect( $dot, 1 );

    if ($dbh) {
        my $query = "use squirrelmail";
        my $sth   = $self->mysql->query( $dbh, $query, 1 );

        if ( !$sth->errstr ) {
            print "squirrelmail: squirrelmail database already exists.\n";
            $sth->finish;
            return 1;
        }

        print "squirrelmail: creating MySQL database for squirrelmail.\n";
        $query = "CREATE DATABASE squirrelmail";
        $sth   = $self->mysql->query( $dbh, $query );

        $query =
"GRANT ALL PRIVILEGES ON $db.* TO $user\@'$host' IDENTIFIED BY '$pass'";
        $sth = $self->mysql->query( $dbh, $query );

        $query =
"CREATE TABLE squirrelmail.address ( owner varchar(128) DEFAULT '' NOT NULL,
nickname varchar(16) DEFAULT '' NOT NULL, firstname varchar(128) DEFAULT '' NOT NULL,
lastname varchar(128) DEFAULT '' NOT NULL, email varchar(128) DEFAULT '' NOT NULL,
label varchar(255), PRIMARY KEY (owner,nickname), KEY firstname (firstname,lastname));
";
        $sth = $self->mysql->query( $dbh, $query );

        $query =
"CREATE TABLE squirrelmail.global_abook ( owner varchar(128) DEFAULT '' NOT NULL, nickname varchar(16) DEFAULT '' NOT NULL, firstname varchar(128) DEFAULT '' NOT NULL,
lastname varchar(128) DEFAULT '' NOT NULL, email varchar(128) DEFAULT '' NOT NULL,
label varchar(255), PRIMARY KEY (owner,nickname), KEY firstname (firstname,lastname));";

        $sth = $self->mysql->query( $dbh, $query );

        $query =
"CREATE TABLE squirrelmail.userprefs ( user varchar(128) DEFAULT '' NOT NULL, prefkey varchar(64) DEFAULT '' NOT NULL, prefval BLOB DEFAULT '' NOT NULL, PRIMARY KEY (user,prefkey))";
        $sth = $self->mysql->query( $dbh, $query );

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

    my $mailhost = $self->conf->{'toaster_hostname'};
    my $dsn      = '';

    if ( $self->conf->{'install_squirrelmail_sql'} ) {
        my $pass = $self->conf->{install_squirrelmail_sql_pass} || 's3kret';
        $dsn = "mysql://squirrel:$pass\@localhost/squirrelmail";
    }

    my $string = <<"EOCONFIG";
<?php
\$signout_page  = 'https://$mailhost/';
\$provider_name     = 'Powered by Mail::Toaster';
\$provider_uri     = 'http://www.tnpi.net/wiki/Mail_Toaster';
\$domain                 = '$mailhost';
\$useSendmail            = true;
\$imap_server_type       = 'dovecot';
\$addrbook_dsn = '$dsn';
\$prefs_dsn = '$dsn';
?>
EOCONFIG
      ;

    $self->util->file_write( "config_local.php", lines => [ $string ] );

    if ( -d "$sqdir/plugins/sasql" ) {
        if ( ! -e "$sqdir/plugins/sasql/sasql_conf.php" ) {
            copy('sasql_conf.php.dist', 'sasql_conf.php');
        };

        my $user = $self->conf->{install_spamassassin_dbuser};
        my $pass = $self->conf->{install_spamassassin_dbpass};
        $self->config->apply_tweaks(
            file => "$sqdir/plugins/sasql/sasql_conf.php",
            changes => [
                {   search  => q{$SqlDSN = 'mysql://<user>:<pass>@<host>/<db>';},
                    replace => "\$SqlDSN = 'mysql://$user:$pass\@localhost/spamassassin'",
                },
            ],
        );
    };
}

sub sqwebmail {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    return $p{test_ok} if defined $p{test_ok};

    my $ver = $self->conf->{'install_sqwebmail'} or do {
        $self->audit( 'skipping sqwebmail install (disabled)');
        return;
    };

    my $httpdir = $self->conf->{'toaster_http_base'} || "/usr/local/www";
    my $cgi     = $self->conf->{'toaster_cgi_bin'};
    my $prefix  = $self->conf->{'toaster_prefix'} || "/usr/local";

    unless ( $cgi && -d $cgi ) { $cgi = "$httpdir/cgi-bin" }

    my $datadir = $self->conf->{'toaster_http_docs'};
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
        if ( !$self->util->yes_or_no(
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
    my $site    = "http://" . $self->conf->{'toaster_sf_mirror'} . "/courier";
    my $src     = $self->conf->{'toaster_src_dir'} || "/usr/local/src";

    $self->util->cwd_source_dir( "$src/mail" );

    if ( -d "$package" ) {
        unless ( $self->util->source_warning( $package, 1, $src ) ) {
            carp "sqwebmail: OK, skipping sqwebmail.\n";
            return;
        }
    }

    unless ( -e "$package.tar.bz2" ) {
        $self->util->get_url( "$site/$package.tar.bz2" );
        unless ( -e "$package.tar.bz2" ) {
            croak "sqwebmail FAILED: coudn't fetch $package\n";
        }
    }

    $self->util->extract_archive( "$package.tar.bz2" );

    chdir($package) or croak "sqwebmail FAILED: coudn't chdir $package\n";

    my $cmd = "./configure --prefix=$prefix --with-htmldir=$prefix/share/sqwebmail "
        . "--with-cachedir=/var/run/sqwebmail --enable-webpass=vpopmail "
        . "--with-module=authvchkpw --enable-https --enable-logincache "
        . "--enable-imagedir=$datadir/webmail --without-authdaemon "
        . "--enable-mimetypes=$mime --enable-cgibindir=" . $cgi;

    if ( $OSNAME eq "darwin" ) { $cmd .= " --with-cacheowner=daemon"; };

    my $make  = $self->util->find_bin("gmake", fatal=>0, verbose=>0);
    $make   ||= $self->util->find_bin("make", fatal=>0, verbose=>0);

    $self->util->syscmd( $cmd );
    $self->util->syscmd( "$make configure-check" );
    $self->util->syscmd( "$make check" );
    $self->util->syscmd( "$make" );

    my $share = "$prefix/share/sqwebmail";
    if ( -d $share ) {
        $self->util->syscmd( "make install-exec" );
        print
          "\n\nWARNING: I have only installed the $package binaries, thus\n";
        print "preserving any custom settings you might have in $share.\n";
        print
          "If you wish to do a full install, overwriting any customizations\n";
        print "you might have, then do this:\n\n";
        print "\tcd $src/mail/$package; make install\n";
    }
    else {
        $self->util->syscmd( "$make install" );
        chmod oct('0755'), $share;
        chmod oct('0755'), "$datadir/sqwebmail";
        copy( "$share/ldapaddressbook.dist", "$share/ldapaddressbook" )
          or croak "copy failed: $!";
    }

    $self->util->syscmd( "$make install-configure", fatal => 0 );
    $self->sqwebmail_conf();
}

sub sqwebmail_conf {
    my $self  = shift;
    my %p = validate(@_, { $self->get_std_opts },);

    my $cachedir = "/var/run/sqwebmail";
    my $prefix   = $self->conf->{'toaster_prefix'} || "/usr/local";

    unless ( -e $cachedir ) {
        my $uid = getpwnam("bin");
        my $gid = getgrnam("bin");
        mkdir( $cachedir, oct('0755') );
        chown( $uid, $gid, $cachedir );
    }

    my $file = "/usr/local/etc/sqwebmail/sqwebmaild";
    return if ! -w $file;

    my @lines = $self->util->file_read( $file );
    foreach my $line (@lines) { #
        if ( $line =~ /^[#]{0,1}PIDFILE/ ) {
            $line = "PIDFILE=$cachedir/sqwebmaild.pid";
        };
    };
    $self->util->file_write( $file, lines=>\@lines );
}

sub sqwebmail_freebsd_port {
    my $self = shift;

    $self->gnupg_install;
    $self->courier_authlib;

    my $cgi     = $self->conf->{'toaster_cgi_bin'};
    my $datadir = $self->conf->{'toaster_http_docs'};
    my $cachedir = "/var/run/sqwebmail";

    if ( $cgi     =~ /\/usr\/local\/(.*)$/ ) { $cgi     = $1; }
    if ( $datadir =~ /\/usr\/local\/(.*)$/ ) { $datadir = $1; }

    my @args = "CGIBINDIR=$cgi";
    push @args, "CGIBINSUBDIR=''";
    push @args, "WEBDATADIR=$datadir";
    push @args, "CACHEDIR=$cachedir";

    $self->freebsd->install_port( "sqwebmail",
        flags => join( ",", @args ),
        options => "# Options for sqwebmail-5.6.1
_OPTIONS_READ=sqwebmail-5.6.1
_FILE_COMPLETE_OPTIONS_LIST=AUTH_LDAP AUTH_MYSQL AUTH_PGSQL AUTH_USERDB AUTH_VCHKPW CACHEDIR CHARSET FAM GDBM GZIP HTTPS HTTPS_LOGIN ISPELL MIMETYPES SENTRENAME
OPTIONS_FILE_UNSET+=AUTH_LDAP
OPTIONS_FILE_UNSET+=AUTH_MYSQL
OPTIONS_FILE_UNSET+=AUTH_PGSQL
OPTIONS_FILE_UNSET+=AUTH_USERDB
OPTIONS_FILE_SET+=AUTH_VCHKPW
OPTIONS_FILE_SET+=CACHEDIR
OPTIONS_FILE_UNSET+=CHARSET
OPTIONS_FILE_UNSET+=FAM
OPTIONS_FILE_UNSET+=GDBM
OPTIONS_FILE_SET+=GZIP
OPTIONS_FILE_SET+=HTTPS
OPTIONS_FILE_UNSET+=HTTPS_LOGIN
OPTIONS_FILE_SET+=ISPELL
OPTIONS_FILE_SET+=MIMETYPES
OPTIONS_FILE_UNSET+=SENTRENAME
",
        );

    $self->freebsd->conf_check(
        check => "sqwebmaild_enable",
        line  => 'sqwebmaild_enable="YES"',
    );

    $self->sqwebmail_conf();

    print "sqwebmail: starting sqwebmaild.\n";
    my $prefix = $self->conf->{'toaster_prefix'} || "/usr/local";
    my $start  = "$prefix/etc/rc.d/sqwebmail-sqwebmaild";

        -x $start      ? $self->util->syscmd( "$start start" )
    : -x "$start.sh" ? $self->util->syscmd( "$start.sh start" )
    : carp "could not find the startup file for sqwebmaild!\n";

    $self->freebsd->is_port_installed( "sqwebmail" );
}

sub stunnel {
    my $self = shift;

    return $self->stunnel_freebsd() if $OSNAME eq 'freebsd';

    my $stunnel = $self->util->find_bin('stunnel', fatal=>0);

    $self->error("stunnel is not installed and you selected pop3_ssl_daemon eq 'qpop3d'. Either install stunnel or change your configuration settings." ) if ! -x $stunnel;
    return;
};

sub stunnel_freebsd {
    my $self = shift;
    return $self->freebsd->install_port( "stunnel",
        options => "#
# This file was generated by mail-toaster\n
# Options for stunnel-4.33
_OPTIONS_READ=stunnel-4.33
WITHOUT_FORK=true
WITH_PTHREAD=true
WITHOUT_UCONTEXT=true
WITHOUT_DH=true
WITHOUT_IPV6=true
WITH_LIBWRAP=true\n",
    );
};

sub supervise {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok};

    my $supervise = $self->conf->{'qmail_supervise'} || "/var/qmail/supervise";
    my $prefix    = $self->conf->{'toaster_prefix'}  || "/usr/local";

    $self->toaster->supervise_dirs_create(%p);
    $self->toaster->service_dir_create(%p);

    $self->qmail->control_create(%p);
    $self->qmail->install_qmail_control_files(%p);
    $self->qmail->install_qmail_control_log_files(%p);

    $self->startup_script();
    $self->toaster->service_symlinks();
    $self->qmail->config();
    $self->supervise_startup(%p);
};

sub supervise_startup {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    my $svok = $self->util->find_bin( 'svok', verbose => 0);
    my $svc_dir = $self->conf->{qmail_service} || '/var/service';
    if ( (system "$svok $svc_dir/send") == 0 ) {
        $self->audit("supervised processes are already started");
        return;
    };

    my $start  = $self->util->find_bin( 'services', verbose => 0);
    print "\n\nStarting up qmail services (Ctrl-C to cancel).

If there's problems, you can stop all supervised services by running:\n
          $start stop\n
\n\nStarting in 5 seconds: ";
    foreach ( 1 .. 5 ) { print '.'; sleep 1; };
    print "\n";

    system "$start start";
}

sub startup_script {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    my $dl_site = $self->conf->{'toaster_dl_site'} || "http://www.tnpi.net";
    my $dl_url = "$dl_site/internet/mail/toaster";

    # make sure the service dir is set up
    return $self->error( "the service directories don't appear to be set up. I refuse to start them until this is fixed.") unless $self->toaster->service_dir_test();

    return $p{test_ok} if defined $p{test_ok};

    return $self->startup_script_freebsd() if $OSNAME eq 'freebsd';
    return $self->startup_script_darwin()  if $OSNAME eq 'darwin';

    $self->error( "There is no startup script support written for $OSNAME. If you know the proper method of doing so, please have a look at $dl_url/start/services.txt, adapt it to $OSNAME, and send it to matt\@tnpi.net." );
};

sub startup_script_darwin {
    my $self = shift;

    my $start = "/Library/LaunchDaemons/to.yp.cr.daemontools-svscan.plist";
    my $dl_site = $self->conf->{'toaster_dl_site'} || "http://www.tnpi.net";
    my $dl_url = "$dl_site/internet/mail/toaster";

    unless ( -e $start ) {
        $self->util->get_url( "$dl_url/start/to.yp.cr.daemontools-svscan.plist" );
        my $r = $self->util->install_if_changed(
            newfile  => "to.yp.cr.daemontools-svscan.plist",
            existing => $start,
            mode     => '0551',
            clean    => 1,
        ) or return;
        $r == 1 ? $r = "ok" : $r = "ok (current)";
        $self->audit( "startup_script: updating $start, $r" );
    }

    my $prefix = $self->conf->{'toaster_prefix'} || "/usr/local";
    $start = "$prefix/sbin/services";

    if ( -w $start ) {
        $self->util->get_url( "$dl_url/start/services-darwin.txt" );

        my $r = $self->util->install_if_changed(
            newfile  => "services-darwin.txt",
            existing => $start,
            mode     => '0551',
            clean    => 1,
        ) or return;

        $r == 1 ? $r = "ok" : $r = "ok (current)";

        $self->audit( "startup_script: updating $start, $r" );
    }
};

sub startup_script_freebsd {
    my $self = shift;

    # The FreeBSD port for daemontools includes rc.d/svscan so we use it
    my $confdir = $self->conf->{'system_config_dir'} || "/usr/local/etc";
    my $start = "$confdir/rc.d/svscan";

    unless ( -f $start ) {
        print "WARNING: no svscan, is daemontools installed?\n";
        print "\n\nInstalling a generic startup file....";

        my $dl_site = $self->conf->{'toaster_dl_site'} || "http://www.tnpi.net";
        my $dl_url = "$dl_site/internet/mail/toaster";
        $self->util->get_url( "$dl_url/start/services.txt" );
        my $r = $self->util->install_if_changed(
            newfile  => "services.txt",
            existing => $start,
            mode     => '0751',
            clean    => 1,
        ) or return;

        $r == 1 ? $r = "ok" : $r = "ok (current)";

        $self->audit( "startup_script: updating $start, $r" );
    }

    $self->freebsd->conf_check(
        check => "svscan_enable",
        line  => 'svscan_enable="YES"',
    );

    # if the qmail start file is installed, nuke it
    unlink "$confdir/rc.d/qmail.sh" if -e "$confdir/rc.d/qmail";
    unlink "$confdir/rc.d/qmail.sh" if -e "$confdir/rc.d/qmail.sh";

    my $prefix = $self->conf->{'toaster_prefix'} || "/usr/local";
    my $sym = "$prefix/sbin/services";
    return 1 if ( -l $sym && -x $sym ); # already exists

    unlink $sym
        or return $self->error( "Please [re]move '$sym' and run again.",fatal=>0) if -e $sym;

    symlink( $start, $sym );
    $self->audit( "startup_script: added $sym as symlink to $start");
};

sub test {
    require Mail::Toaster::Setup::Test;
    return Mail::Toaster::Setup::Test->new;
};

sub ucspi_tcp {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    # pre-declarations. We configure these for each platform and use them
    # at the end to build ucspi_tcp from source.

    my $patches = [];
    my @targets = ( 'make', 'make setup check' );

    if ( $self->conf->{install_mysql} && $self->conf->{'vpopmail_mysql'} ) {
        $patches = ["ucspi-tcp-0.88-mysql+rss.patch"];
    }

    if ( $OSNAME eq "freebsd" ) {
        # install it from ports so it is registered in the ports db
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
    my $tcpserver = $self->util->find_bin( "tcpserver", fatal => 0, verbose=>0 );
    if ( $tcpserver ) {
        if ( ! $self->conf->{install_mysql} || !$self->conf->{'vpopmail_mysql'} ) {
            $self->audit( "ucspi-tcp: install, ok (exists)" );
            return 2; # we don't need mysql
        }
        my $strings = $self->util->find_bin( "strings", verbose=>0 );
        if ( grep {/sql/} `$strings $tcpserver` ) {
            $self->audit( "ucspi-tcp: mysql support check, ok (exists)" );
            return 1;
        }
        $self->audit( "ucspi-tcp is installed but w/o mysql support, " .
            "compiling from sources.");
    }

    # save some bandwidth
    if ( -e "/usr/ports/distfiles/ucspi-tcp-0.88.tar.gz" ) {
        copy( "/usr/ports/distfiles/ucspi-tcp-0.88.tar.gz",
              "/usr/local/src/ucspi-tcp-0.88.tar.gz"
        );
    }

    $self->util->install_from_source(
        package   => "ucspi-tcp-0.88",
        patches   => $patches,
        patch_url => $self->conf->{'toaster_dl_site'} . $self->conf->{'toaster_dl_url'} . "/patches",
        site      => 'http://cr.yp.to',
        url       => '/ucspi-tcp',
        targets   => \@targets,
    );

    return $self->util->find_bin( "tcpserver", fatal => 0, verbose => 0 ) ? 1 : 0;
}

sub ucspi_tcp_darwin {
    my $self = shift;

    my @targets = "echo '/opt/local' > conf-home";

    if ( $self->conf->{'vpopmail_mysql'} ) {
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
    my $self = shift;
    $self->freebsd->install_port( "ucspi-tcp",
        flags   => "BATCH=yes WITH_RSS_DIFF=1",
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

    print "checking ucspi-tcp binaries...\n";
    foreach (qw( tcprules tcpserver rblsmtpd tcpclient recordio )) {
        $self->toaster->test("  $_", $self->util->find_bin( $_, fatal => 0, verbose=>0 ) );
    }

    if ( $self->conf->{install_mysql} && $self->conf->{'vpopmail_mysql'} ) {
        my $tcpserver = $self->util->find_bin( "tcpserver", fatal => 0, verbose=>0 );
        $self->toaster->test( "  tcpserver mysql support",
            scalar `strings $tcpserver | grep sql`
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
        $cmd = $self->util->find_bin( 'useradd' );
        $cmd .= " -s $shell";
        $cmd .= " -d $homedir" if $homedir;
        $cmd .= " -u $uid" if $uid;
        $cmd .= " -g $gid" if $gid;
        $cmd .= " -m $user";
    }
    elsif ( $OSNAME eq 'freebsd' ) {
        $cmd = $self->util->find_bin( 'pw' );
        $cmd .= " useradd -n $user -s $shell";
        $cmd .= " -d $homedir" if $homedir;
        $cmd .= " -u $uid " if $uid;
        $cmd .= " -g $gid " if $gid;
        $cmd .= " -m -h-";
    }
    elsif ( $OSNAME eq 'darwin' ) {
        $cmd = $self->util->find_bin( 'dscl', fatal => 0 );
        my $path = "/users/$user";
        if ( $cmd ) {
            $self->util->syscmd( "$cmd . -create $path" );
            $self->util->syscmd( "$cmd . -createprop $path uid $uid");
            $self->util->syscmd( "$cmd . -createprop $path gid $gid");
            $self->util->syscmd( "$cmd . -createprop $path shell $shell" );
            $self->util->syscmd( "$cmd . -createprop $path home $homedir" ) if $homedir;
            $self->util->syscmd( "$cmd . -createprop $path passwd '*'" );
        }
        else {
            $cmd = $self->util->find_bin( 'niutil' );
            $self->util->syscmd( "$cmd -createprop . $path uid $uid");
            $self->util->syscmd( "$cmd -createprop . $path gid $gid");
            $self->util->syscmd( "$cmd -createprop . $path shell $shell");
            $self->util->syscmd( "$cmd -createprop . $path home $homedir" ) if $homedir;
            $self->util->syscmd( "$cmd -createprop . $path _shadow_passwd");
            $self->util->syscmd( "$cmd -createprop . $path passwd '*'");
        };
        return 1;
    }
    else {
        warn "cannot add user on OS $OSNAME\n";
        return;
    };
    return $self->util->syscmd( $cmd );
};

sub user_exists {
    my $self = shift;
    my $user = lc(shift) or die "missing user";
    my $uid = getpwnam($user);
    return ( $uid && $uid > 0 ) ? $uid : undef;
};

sub vpopmail {
    require Mail::Toaster::Setup::Vpopmail;
    return Mail::Toaster::Setup::Vpopmail->new;
};

sub vqadmin {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    return $p{test_ok} if defined $p{test_ok}; # for testing

    if ( ! $self->conf->{'install_vqadmin'} ) {
        $self->audit( "vqadmin: installing, skipping (disabled)" );
        return;
    }

    my $cgi  = $self->conf->{'toaster_cgi_bin'}   || "/usr/local/www/cgi-bin";
    my $data = $self->conf->{'toaster_http_docs'} || "/usr/local/www/data";

    if ( $cgi && $cgi =~ /\/usr\/local\/(.*)$/ ) {
        $cgi = $1;
        chop $cgi if $cgi =~ /\/$/; # remove trailing /
    }

    if ( $data =~ /\/usr\/local\/(.*)$/ ) {
        chop $data if $data =~ /\/$/; # remove trailing /
        $data = $1;
    }

    my @defs = 'CGIBINDIR="' . $cgi . '"';
    push @defs, 'WEBDATADIR="' . $data . '"';

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    if ( $OSNAME eq "freebsd" ) {
        $self->freebsd->install_port( "vqadmin", flags => join( ",", @defs ) )
            and return 1;
    }

    my $make  = $self->util->find_bin("gmake", fatal=>0, verbose=>0);
    $make   ||= $self->util->find_bin("make", fatal=>0, verbose=>0);

    print "trying to build vqadmin from sources\n";

    $self->util->install_from_source(
        package        => "vqadmin",
        site           => "http://vpopmail.sf.net",
        url            => "/downloads",
        targets        => [ "./configure ", $make, "$make install-strip" ],
        source_sub_dir => 'mail',
    );
}

sub webmail {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    # if the cgi_files dir is not available, we can't do much.
    my $tver = $Mail::Toaster::VERSION;
    my $dir = './cgi_files';
    if ( ! -d $dir ) {
        if ( -d "/usr/local/src/Mail-Toaster-$tver/cgi_files" ) {
            $dir = "/usr/local/src/Mail-Toaster-$tver/cgi_files";
        }
    };

    return $self->error( "You need to run this target while in the Mail::Toaster directory!\n"
        . "Try this instead:

   cd /usr/local/src/Mail-Toaster-$tver
   bin/toaster_setup.pl -s webmail

You are currently in " . Cwd::cwd ) if ! -d $dir;

    # set the hostname in mt-script.js
    my $hostname = $self->conf->{'toaster_hostname'};

    my @lines = $self->util->file_read("$dir/mt-script.js");
    foreach my $line ( @lines ) {
        if ( $line =~ /\Avar mailhost / ) {
            $line = qq{var mailhost = 'https://$hostname'};
        };
    }
    $self->util->file_write( "$dir/mt-script.js", lines => \@lines );

    my $htdocs = $self->conf->{'toaster_http_docs'} || '/usr/local/www/toaster';
    my $rsync = $self->rsync() or return;

    my $cmd = "$rsync -av $dir/ $htdocs/";
    print "about to run cmd: $cmd\n";

    print "\a";
    return if ! $self->util->yes_or_no(
            "\n\n\t CAUTION! DANGER! CAUTION!

    This action will install the Mail::Toaster webmail interface. Doing
    so may overwrite existing files in $htdocs. Is is safe to proceed?\n\n",
            timeout  => 60,
          );

    $self->util->syscmd( $cmd );
    return 1;
};

1;
__END__;


=head1 NAME

Mail::Toaster::Setup -  methods to configure and build all the components of a modern email server.

=head1 DESCRIPTION

The meat and potatoes of toaster_setup.pl. This is where the majority of the work gets done. Big chunks of the code and logic for getting all the various applications and scripts installed and configured resides in here.


=head1 METHODS

All documented methods in this package (shown below) accept two optional arguments, verbose and fatal. Setting verbose to zero will supress nearly all informational and debugging output. If you want more output, simply pass along verbose=>1 and status messages will print out. Fatal allows you to override the default behaviour of these methods, which is to die upon error. Each sub returns 0 if the action failed and 1 for success.

 arguments required:
   varies (most require conf)

 arguments optional:
   verbose - print status messages
   fatal   - die on errors (default)

 result:
   0 - failure
   1 - success

 Examples:

   1. $setup->apache( verbose=>0, fatal=>0 );
   Try to build apache, do not print status messages and do not die on error(s).

   2. $setup->apache( verbose=>1 );
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

=item clamav

Install ClamAV, configure the startup and config files, download the latest virus definitions, and start up the daemons.


=item config - personalize your toaster-watcher.conf settings

There are a subset of the settings in toaster-watcher.conf which must be personalized for your server. Things like the hostname, where you store your configuration files, html documents, passwords, etc. This function checks to make sure these settings have been changed and prompts for any necessary changes.

 required arguments:
   conf


=item config_tweaks

Makes changes to the config file, dynamically based on detected circumstances such as a jailed hostname, or OS platform. Platforms like FreeBSD, Darwin, and Debian have package management capabilities. Rather than installing software via sources, we prefer to try using the package manager first. The toaster-watcher.conf file typically includes the latest stable version of each application to install. This subroutine will replace those version numbers with with 'port', 'package', or other platform specific tweaks.

=item daemontools

Fetches sources from DJB's web site and installs daemontools, per his instructions.

=item dependencies

  $setup->dependencies( );

Installs a bunch of dependency programs that are needed by other programs we will install later during the build of a Mail::Toaster. You can install these yourself if you would like, this does not do anything special beyond installing them:

ispell, gdbm, setquota, expect, maildrop, autorespond, qmail, qmailanalog, daemontools, openldap-client, Crypt::OpenSSL-RSA, DBI, DBD::mysql.

required arguments:
  conf

result:
  1 - success
  0 - failure


=item djbdns

Fetches djbdns, compiles and installs it.

  $setup->djbdns( );

 required arguments:
   conf

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

 result:
   1 - success
   0 - failure


=item filtering

Installs SpamAssassin, ClamAV, simscan, QmailScanner, maildrop, procmail, and programs that support the aforementioned ones. See toaster-watcher.conf for options that allow you to customize which programs are installed and any options available.

  $setup->filtering();


=item maillogs

Installs the maillogs script, creates the logging directories (toaster_log_dir/), creates the qmail supervise dirs, installs maillogs as a log post-processor and then builds the corresponding service/log/run file to use with each post-processor.

  $setup->maillogs();


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


=back


=head1 DEPENDENCIES

    IO::Socket::SSL


=head1 AUTHOR

Matt Simerson - matt@tnpi.net


=head1 SEE ALSO

The following are all perldoc pages:

 Mail::Toaster
 Mail::Toaster::Conf
 toaster.conf
 toaster-watcher.conf

 http://mail-toaster.org/

=cut
