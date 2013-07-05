package Mail::Toaster::Setup::Config;

use strict;
use warnings;

#use Carp;
#use Config;
#use Cwd;
#use Data::Dumper;
#use File::Copy;
#use File::Path;
use English '-no_match_vars';
use Params::Validate ':all';
use Sys::Hostname;

use lib 'lib';
use parent 'Mail::Toaster::Base';

sub config {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    # apply the platform specific changes to the config file
    $self->tweaks();

    my $file_name = "toaster-watcher.conf";
    my $file_path = $self->util->find_config( $file_name );
    $self->setup->refresh_config( $file_path ) or return;

### start questions
    $self->config_hostname();
    $self->postmaster();
    $self->test_email();
    $self->test_email_pass();
    $self->vpopmail_mysql_pass();
    $self->openssl();
    $self->webmail_passwords();
### end questions
### don't forget to add changed fields to the list in save_changes

    $self->save_changes( $file_path );
    $self->install($file_name, $file_path );
};

sub apply_tweaks {
    my $self = shift;
    my %p = validate( @_,
        {   file    => { type => SCALAR },
            changes => { type => ARRAYREF },
            $self->get_std_opts
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
    my @lines = $self->util->file_read( $p{file} ) or return;

    my $total_found = 0;
    foreach my $e ( @{ $p{changes} } ) {
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
        $self->error( "attempt to replace\n$search\n\twith\n$replace\n\tfailed",
            fatal => 0) if ( ! $found && ! $e->{nowarn} );
        $total_found += $found;
    };

    $self->audit( "config tweaks replaced $total_found lines",verbose=>$p{verbose} );

    $self->util->file_write( $p{file}, lines => \@lines );
};

sub config_hostname {
    my $self = shift;

    return if ( $self->conf->{'toaster_hostname'} && $self->conf->{'toaster_hostname'} ne "mail.example.com" );

    $self->conf->{'toaster_hostname'} = $self->util->ask(
        "the hostname of this mail server",
        default  => hostname,
    );
    chomp $self->conf->{'toaster_hostname'};

    $self->audit( "toaster hostname set to " . $self->conf->{'toaster_hostname'} );
};

sub install {
    my $self = shift;
    my ($file_name, $file_path) = @_;

    # install $file_path in $prefix/etc/toaster-watcher.conf if it doesn't exist
    # already
    my $config_dir = $self->conf->{'system_config_dir'} || '/usr/local/etc';

    # if $config_dir is missing, create it
    $self->util->mkdir_system( dir => $config_dir ) if ! -e $config_dir;

    my @configs = (
        { newfile  => $file_path, existing => "$config_dir/$file_name", mode => '0640', overwrite => 0 },
        { newfile  => $file_path, existing => "$config_dir/$file_name-dist", mode => '0640', overwrite => 1 },
        { newfile  => 'toaster.conf-dist', existing => "$config_dir/toaster.conf", mode => '0644', overwrite => 0 },
        { newfile  => 'toaster.conf-dist', existing => "$config_dir/toaster.conf-dist", mode => '0644', overwrite => 1 },
    );

    foreach ( @configs ) {
        next if -e $_->{existing} && ! $_->{overwrite};
        $self->util->install_if_changed(
            newfile  => $_->{newfile},
            existing => $_->{existing},
            mode     => $_->{mode},
            clean    => 0,
            notify   => 1,
            verbose  => 0,
        );
    };
}

sub openssl {
    my $self = shift;
    # OpenSSL certificate settings

    # country
    if ( $self->conf->{'ssl_country'} eq "SU" ) {
        print "             SSL certificate defaults\n";
        $self->conf->{'ssl_country'} =
          uc( $self->util->ask( "your 2 digit country code (US)", default  => "US" )
          );
    }
    $self->audit( "config: ssl_country, (" . $self->conf->{'ssl_country'} . ")" );

    # state
    if ( $self->conf->{'ssl_state'} eq "saxeT" ) {
        $self->conf->{'ssl_state'} =
          $self->util->ask( "the name (non abbreviated) of your state" );
    }
    $self->audit( "config: ssl_state, (" . $self->conf->{'ssl_state'} . ")" );

    # locality (city)
    if ( $self->conf->{'ssl_locality'} eq "dnalraG" ) {
        $self->conf->{'ssl_locality'} =
          $self->util->ask( "the name of your locality/city" );
    }
    $self->audit( "config: ssl_locality, (" . $self->conf->{'ssl_locality'} . ")" );

    # organization
    if ( $self->conf->{'ssl_organization'} eq "moc.elpmaxE" ) {
        $self->conf->{'ssl_organization'} = $self->util->ask( "the name of your organization" );
    }
    $self->audit( "config: ssl_organization, (" . $self->conf->{'ssl_organization'} . ")" );
};

sub webmail_passwords {
    my $self = shift;

    if ( $self->conf->{install_squirrelmail} &&
         $self->conf->{install_squirrelmail_sql} &&
         $self->conf->{install_squirrelmail_sql_pass} eq 'chAnge7his' ) {
         $self->conf->{install_squirrelmail_sql_pass} =
            $self->util->ask("squirrelmail database password");
    };

    if ( $self->conf->{install_roundcube} &&
         $self->conf->{install_roundcube_db_pass} eq 'To4st3dR0ndc@be' ) {
         $self->conf->{install_roundcube_db_pass} =
            $self->util->ask("roundcube database password");
    };

    if ( $self->conf->{install_spamassassin} &&
         $self->conf->{install_spamassassin_sql} &&
         $self->conf->{install_spamassassin_dbpass} eq 'assSPAMing' ) {
         $self->conf->{install_spamassassin_dbpass} =
            $self->util->ask("spamassassin database password");
    };

    if ( $self->conf->{install_phpmyadmin} &&
         $self->conf->{phpMyAdmin_controlpassword} eq 'pmapass') {
         $self->conf->{phpMyAdmin_controlpassword} =
            $self->util->ask("phpMyAdmin control password");
    };

    return 1;
};

sub postmaster {
    my $self = shift;

    return if ( $self->conf->{'toaster_admin_email'} && $self->conf->{'toaster_admin_email'} ne "postmaster\@example.com" );

    $self->conf->{'toaster_admin_email'} = $self->util->ask(
        "the email address for administrative emails and notices\n".
            " (probably yours!)",
        default => "postmaster",
    ) || 'root';

    $self->audit(
        "toaster admin emails sent to " . $self->conf->{'toaster_admin_email'} );
};

sub save_changes {
    my $self = shift;
    my ($file_path) = @_;

    my @fields = qw/ toaster_hostname toaster_admin_email toaster_test_email
        toaster_test_email_pass vpopmail_mysql_pass ssl_country ssl_state
        ssl_locality ssl_organization install_squirrelmail_sql_pass
        install_roundcube_db_pass install_spamassassin_dbpass
        phpMyAdmin_controlpassword
        /;
    push @fields, 'vpopmail_mysql_pass' if $self->conf->{'vpopmail_mysql'};

    my @lines = $self->util->file_read( $file_path, verbose => 0 );
    foreach my $key ( @fields ) {
        foreach my $line (@lines) {
            if ( $line =~ /^$key\s*=/ ) {
# format the config entries to match config file format
                $line = sprintf( '%-34s = %s', $key, $self->conf->{$key} );
            }
        };
    };

    $self->util->file_write( "/tmp/toaster-watcher.conf", lines => \@lines );

    my $r = $self->util->install_if_changed(
            newfile  => "/tmp/toaster-watcher.conf",
            existing => $file_path,
            mode     => '0640',
            clean    => 1,
            notify   => -e $file_path ? 1 : 0,
    )
    or return $self->error( "installing /tmp/toaster-watcher.conf to $file_path failed!" );

    my $status = $r == 1 ? "ok" : "ok (current)";
    $self->audit( "config: updating $file_path, $status" );
    return $r;
};

sub test_email {
    my $self = shift;

    return if $self->conf->{'toaster_test_email'} ne "test\@example.com";

    $self->conf->{'toaster_test_email'} = $self->util->ask(
        "an email account for running tests",
        default  => "postmaster\@" . $self->conf->{'toaster_hostname'}
    );

    $self->audit( "toaster test account set to ".$self->conf->{'toaster_test_email'} );
};

sub test_email_pass {
    my $self = shift;

    return if ( $self->conf->{'toaster_test_email_pass'} && $self->conf->{'toaster_test_email_pass'} ne "cHanGeMe" );

    $self->conf->{'toaster_test_email_pass'} = $self->util->ask( "the test email account password" );

    $self->audit(
        "toaster test password set to ".$self->conf->{'toaster_test_email_pass'} );
};

sub tweaks {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    my $status = "ok";

    my $file = $self->util->find_config( 'toaster-watcher.conf' );

    # verify that find_config worked and $file is readable
    return $self->error( "tweaks: read test on $file, FAILED",
        fatal => $p{fatal} ) if ! -r $file;

    my %changes;
    %changes = $self->config_tweaks_freebsd() if $OSNAME eq 'freebsd';
    %changes = $self->config_tweaks_darwin()  if $OSNAME eq 'darwin';
    %changes = $self->config_tweaks_linux()   if $OSNAME eq 'linux';

    %changes = $self->config_tweaks_testing(%changes);
    %changes = $self->config_tweaks_mysql(%changes);

    # foreach key of %changes, apply to $conf
    my @lines = $self->util->file_read( $file );
    foreach my $line (@lines) {
        next if $line =~ /^#/;  # comment lines
        next if $line !~ /=/;   # not a key = value

        my ( $key, $val ) = $self->util->parse_line( $line, strip => 0 );

        if ( defined $changes{$key} && $changes{$key} ne $val ) {
            $status = "changed";
            #print "\t setting $key to ". $changes{$key} . "\n";
            $line = sprintf( '%-34s = %s', $key, $changes{$key} );
            print "\t$line\n";
        }
    }
    return 1 unless ( $status && $status eq "changed" );

    # ask the user for permission to install
    return 1
      if ! $self->util->yes_or_no(
'config tweaks: The changes shown above are recommended for use on your system.
May I apply the changes for you?',
        timeout => 30,
      );

    # write $conf to temp file
    $self->util->file_write( "/tmp/toaster-watcher.conf", lines => \@lines );

    # if the file ends with -dist, then save it back with out the -dist suffix
    # the find_config sub will automatically prefer the newer non-suffixed one
    if ( $file =~ m/(.*)-dist\z/ ) {
        $file = $1;
    };

    # update the file if there are changes
    my $r = $self->util->install_if_changed(
        newfile  => "/tmp/toaster-watcher.conf",
        existing => $file,
        clean    => 1,
        notify   => 0,
        verbose    => 0,
    );

    return 0 unless $r;
    $r == 1 ? $r = "ok" : $r = "ok (current)";
    $self->audit( "config tweaks: updated $file, $r" );
}

sub config_tweaks_darwin {
    my $self = shift;

    $self->audit( "config tweaks: applying Darwin tweaks" );

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
    my $self = shift;
    $self->audit( "config tweaks: applying FreeBSD tweaks" );

    return (
        install_squirrelmail => 'port    # 0, ver, port',
        install_autorespond  => 'port    # 0, ver, port',
        install_ezmlm        => 'port    # 0, ver, port',
        install_courier_imap => '0       # 0, ver, port',
        install_dovecot      => 'port    # 0, ver, port',
        install_clamav       => 'port    # 0, ver, port',
        install_ripmime      => 'port    # 0, ver, port',
        install_cronolog     => 'port    # ver, port',
        install_daemontools  => 'port    # ver, port',
        install_qmailadmin   => 'port    # 0, ver, port',
        install_djbdns       => 'port    # ver, port',
    )
}

sub config_tweaks_linux {
    my $self = shift;
    $self->audit( "config tweaks: applying Linux tweaks " );

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

sub config_tweaks_mysql {
    my ($self, %changes) = @_;

    return %changes if $self->conf->{install_mysql};
    return %changes if ! $self->util->yes_or_no("Enable MySQL support?");

    $self->audit( "config tweaks: applying MT testing tweaks" );

    $changes{'install_mysql'}   = '55      # 0, 1, 2, 3, 40, 41, 5, 55';
    $changes{'install_mysqld'}  = '1       # 0, 1';
    $changes{'vpopmail_mysql'}  = '1         # enables all mysql options';
    $changes{'smtpd_use_mysql_relay_table'} = 0;
    $changes{'install_squirrelmail_sql'}    = 1;
    $changes{'install_spamassassin_sql'}    = 1;

    return %changes;
};

sub config_tweaks_testing {
    my ($self, %changes) = @_;

    my $hostname = hostname;
    return %changes if ( ! $hostname || $hostname ne 'jail.simerson.net' );

    $self->audit( "config tweaks: applying MT testing tweaks" );

    $changes{'toaster_hostname'}      = 'jail.simerson.net';
    $changes{'toaster_admin_email'}   = 'postmaster@jail.simerson.net';
    $changes{'toaster_test_email'}    = 'test@jail.simerson.net';
    $changes{'toaster_test_email_pass'}   = 'sdfsdf';
    $changes{'install_squirrelmail_sql'}  = '1';
    $changes{'install_phpmyadmin'}        = '1';
    $changes{'install_sqwebmail'}         = 'port';
    $changes{'install_vqadmin'}           = 'port';
    $changes{'install_openldap_client'}   = '1';
    $changes{'install_ezmlm_cgi'}         = '1';
    $changes{'install_dspam'}             = '1';
    $changes{'install_pyzor'}             = '1';
    $changes{'install_bogofilter'}        = '1';
    $changes{'install_dcc'}               = '1';
    $changes{'install_lighttpd'}          = '1';
    $changes{'install_apache'}            = '22';
    $changes{'install_courier_imap'}      = 'port';
    $changes{'install_gnupg'}             = 'port';
    $changes{'vpopmail_default_domain'}   = 'jail.simerson.net';
    $changes{'pop3_ssl_daemon'}           = 'qpop3d';
    $changes{'install_spamassassin_flags'}= '-v -u spamd -q -A 10.0.1.67 -H /var/spool/spamd -x';
    $changes{'install_isoqlog'}           = 'port    # 0, ver, port';

    return %changes;
}

sub vpopmail_mysql_pass {
    my $self = shift;

    return if ! $self->conf->{'vpopmail_mysql'};
    return if ( $self->conf->{'vpopmail_mysql_pass'}
        && $self->conf->{'vpopmail_mysql_pass'} ne "supersecretword" );

    $self->conf->{'vpopmail_mysql_pass'} =
        $self->util->ask( "the password for securing vpopmails "
            . "database connection. You MUST enter a password here!",
        );

    $self->audit( "vpopmail MySQL password set to ".$self->conf->{'vpopmail_mysql_pass'});
}

1;

