package Mail::Toaster::Apache;

use strict;
use warnings;

our $VERSION = '5.26';

use Carp;
use English qw( -no_match_vars );
use File::Copy;
use Params::Validate qw( :all );

use lib 'lib';
my ( $log, $util, %std_opts );

sub new {
    my $class = shift;
    my %p = validate( @_, 
        {   'log' => { type=>OBJECT },
            fatal => { type => BOOLEAN, optional => 1, default => 1 },
            debug => { type => BOOLEAN, optional => 1 },
        } 
    );

    $log  = $p{'log'};
    $util = $log->get_util;

    my $debug = $log->get_debug;    # inherit from our parent
    my $fatal = $log->get_fatal;
    $debug = $p{debug} if defined $p{debug};  # explicity overridden
    $fatal = $p{fatal} if defined $p{fatal};

    my $self = {
        'log' => $log,
        debug => $debug,
        fatal => $fatal,    
    };    
    bless $self, $class;

# globally scoped hash, populated with defaults requested by the caller
    %std_opts = (
        'test_ok' => { type => BOOLEAN, optional => 1 },
        'fatal'   => { type => BOOLEAN, optional => 1, default => $fatal },
        'debug'   => { type => BOOLEAN, optional => 1, default => $debug },    
    );

    return $self;
}

sub install_apache1 {
    my $self = shift;
    my ( $src, $conf ) = @_;

    return if $OSNAME eq "darwin";
    return $self->install_1_freebsd() if $OSNAME eq "freebsd";

    $self->install_1_source($conf);
};

sub install_1_source {
    my ($self, $conf) = @_;

    my $apache   = "apache_1.3.34";
    my $mod_perl = "mod_perl-1.29";
    my $mod_ssl  = "mod_ssl-2.8.24-1.3.34";
    my $layout   = "FreeBSD.layout";

    my $prefix   = $conf->{'toaster_prefix'}  || "/usr/local";
    my $src      = $conf->{'toaster_src_dir'} || "$prefix/src";

    $util->cwd_source_dir( "$src/www", debug=>0 );

    unless ( -e "$apache.tar.gz" ) {
        $util->get_file("http://www.apache.org/dist/httpd/$apache.tar.gz");
    }

    unless ( -e "$mod_perl.tar.gz" ) {
        $util->get_file("http://perl.apache.org/dist/$mod_perl.tar.gz");
    }

    unless ( -e "$mod_ssl.tar.gz" ) {
        $util->get_file("http://www.modssl.org/source/$mod_ssl.tar.gz");
    }

    unless ( -e $layout ) {
        $util->get_file("http://www.tnpi.net/internet/www/apache.layout");
        move( "apache.layout", $layout );
    }

    RemoveOldApacheSources($apache);

    foreach my $package ( $apache, $mod_perl, $mod_ssl ) {
        if ( -d $package ) {
            my $r = $util->source_warning( $package, 1 );
            unless ($r) { croak "sorry, I can't continue.\n" }
        }
        $util->extract_archive( "$package.tar.gz" );
    }

    chdir($mod_ssl);
    if ( $OSNAME eq "darwin" ) {
        $util->syscmd( "./configure --with-apache=../$apache" );
    }
    else {
        $util->syscmd( 
"./configure --with-apache=../$apache --with-ssl=/usr --enable-shared=ssl --with-mm=/usr/local"
        );
    };

    chdir("../$mod_perl");
    if ( $OSNAME eq "darwin" ) {
        $util->syscmd( 
"perl Makefile.PL APACHE_SRC=../$apache NO_HTTPD=1 USE_APACI=1 PREP_HTTPD=1 EVERYTHING=1"
        );
    }
    else {
        $util->syscmd( 
"perl Makefile.PL DO_HTTPD=1 USE_APACI=1 APACHE_PREFIX=/usr/local EVERYTHING=1 APACI_ARGS='--server-uid=www, --server-gid=www, --enable-module=so --enable-module=most, --enable-shared=max --disable-shared=perl, --enable-module=perl, --with-layout=../$layout:FreeBSD, --without-confadjust'"
        );
    }

    $util->syscmd( "make" );

    if ( $OSNAME eq "darwin" ) {
        $util->syscmd( "make install" );
        chdir("../$apache");
        $util->syscmd( "./configure --with-layout=Darwin --enable-module=so --enable-module=ssl --enable-shared=ssl --activate-module=src/modules/perl/libperl.a --disable-shared=perl --without-execstrip"
        );
        $util->syscmd( "make" );
        $util->syscmd( "make install" );
    }

    if ( -e "../$apache/src/httpd" ) {

        print '\n
Apache build successful, now you must install as follows:

For new installs:

     cd $src/www/$mod_perl
     make test
     cd ../$apache; make certificate TYPE=custom
     rm /usr/local/etc/apache/httpd.conf
     cd ../$mod_perl; make install
     cd /usr/ports/www/mod_php4; make install clean (optional)
     apachectl stop; apachectl startssl

For re-installs:

     cd $src/www/$mod_perl;\n\tmake test
     make install
     cd /usr/ports/www/mod_php4; make install clean (optional)
     apachectl stop; apachectl startssl
';
    }

    return 1;
}

sub install_1_freebsd {
    my ($self, $conf) = @_;

    require Mail::Toaster::FreeBSD;
    my $freebsd = Mail::Toaster::FreeBSD->new( 'log' => $log );

    if ( $conf->{'package_install_method'} eq "packages" ) {
        $freebsd->install_package( "mm" );
        $freebsd->install_package( "gettext" );
        $freebsd->install_package( "libtool" );
        $freebsd->install_package( "apache" );
        $freebsd->install_package( "p5-libwww" );
    }
    else {
        $freebsd->install_port( "mm",      );
        $freebsd->install_port( "gettext", );
        $freebsd->install_port( "libtool", );
        $freebsd->install_port( "apache", dir => "apache13");
        $freebsd->install_port( "p5-libwww" );
    }
    $freebsd->install_port( "cronolog", );

    my $log = "/var/log/apache";
    unless ( -d $log ) {
        mkdir( $log, oct('0755') ) or croak "Couldn't create $log: $!\n";
        $util->chown( $log, uid=>'www', gid=>'www' );
    }

    unless ( $freebsd->is_port_installed( "apache" ) ) {
        $freebsd->install_package( "apache" );
    }

    $freebsd->conf_check( check=>"apache_enable", line=>'apache_enable="YES"' );
}

sub install_2 {
    my $self = shift;

    my %p = validate( @_, {
            'conf' => { type=>HASHREF, },
            %std_opts,
        },
    );

    my ( $conf, $fatal, $debug ) = ( $p{'conf'}, $p{'fatal'}, $p{'debug'} );

    my $prefix = $conf->{'toaster_prefix'}  || "/usr/local";
    my $src    = $conf->{'toaster_src_dir'} || "$prefix/src";
    $src .= "/www";

    $util->cwd_source_dir( $src, debug=>0 );

    if ( $OSNAME eq "freebsd" ) {
        return $self->install_2_freebsd( $conf , $debug );
    }

    if ( $OSNAME eq "darwin" ) {
        print "\nInstalling Apache 2 on Darwin (MacOS X)?\n\n";

        if ( ! -d "/usr/dports/dports" ) {
            print
"I can't find DarwinPorts! Try following the instructions here:  
http://www.tnpi.net/internet/mail/toaster/darwin.shtml.\n";
            return;
        }

        require Mail::Toaster::Darwin;
        my $darwin = Mail::Toaster::Darwin->new( 'log' => $log );

        $darwin->install_port( "apache2" );
        $darwin->install_port( "php5", opts => "+apache2" );
        return 1;
    }

    $log->error("sorry, no apache build support on OS $OSNAME", fatal => 0);
};

sub install_2_freebsd {
    my ($self, $conf, $debug ) = @_;

    my $ports_dir = "apache22";
    my $ver = $conf->{'install_apache'}  || 22;

    if    ( $ver eq  "2" ) { $ports_dir = "apache20"; }
    elsif ( $ver eq "20" ) { $ports_dir = "apache20"; }
    elsif ( $ver eq "21" ) { $ports_dir = "apache21"; }  # defunct
    elsif ( $ver eq "22" ) { $ports_dir = "apache22"; }

    $log->audit( "install_2: v$ver from www/$ports_dir on FreeBSD");

    require Mail::Toaster::FreeBSD;
    my $freebsd = Mail::Toaster::FreeBSD->new( 'log' => $log );

    # if some variant of apache 2 is installed
    my $r = $freebsd->is_port_installed( "apache-2", debug=>$debug );
    if ( $r ) {
        $log->audit( "install_2: installing v$ver, ok ($r)" );

        # fixup Apache 2 installs
        $self->apache2_fixups( $conf, $ports_dir );
        $self->freebsd_extras( $conf, $freebsd );
        $self->install_ssl_certs(conf=>$conf );
        $self->apache_conf_patch(conf=>$conf );
        $self->startup(conf=>$conf );
        return 1;
    }

    if ( $conf->{'package_install_method'} eq "packages" ) {
        if (   $conf->{'install_apache_proxy'}
            || $conf->{'install_apache_suexec'} )
        {
            $log->audit( "skipping package install because custom options are selected.");
        }
        else {
            print "install_2: attempting package install.\n";
            $freebsd->install_package( $ports_dir, alt => "apache-2" );
            $freebsd->install_package( "p5-libwww" );
        }
    }

    # building m4 with options suppresses an dialog
    $freebsd->install_port( 'm4',
        options => "# This file is generated by mail-toaster
# No user-servicable parts inside!
# Options for m4-1.4.14_1,1
_OPTIONS_READ=m4-1.4.14_1,1
WITHOUT_LIBSIGSEGV=true",
    );

    $freebsd->install_port( 'apr',
        dir      => 'apr1',
        category => 'devel',
        options  => "# This file is generated by mail-toaster
# Options for apr-devrandom-1.4.2.1.3.9_1
_OPTIONS_READ=apr-devrandom-1.4.2.1.3.9_1
WITH_THREADS=true
WITHOUT_IPV6=true
WITHOUT_BDB=true
WITHOUT_GDBM=true
WITHOUT_LDAP=true
WITHOUT_MYSQL=true
WITHOUT_NDBM=true
WITHOUT_PGSQL=true
WITHOUT_SQLITE=true
WITH_DEVRANDOM=true",
    );

    $log->audit( "trying port install from /usr/ports/www/$ports_dir");
    $freebsd->install_port( $ports_dir,
        check => "apache",
        flags => $self->install_2_freebsd_flags($conf),
    );

    # fixup Apache 2 installs
    $self->apache2_fixups( $conf, $ports_dir ) if ( $ver =~ /2/ );
    $self->freebsd_extras( $conf, $freebsd );
    $self->install_ssl_certs( conf=>$conf );
    $self->apache_conf_patch( conf=>$conf );
    $self->startup(conf=>$conf );
    return 1;
}

sub install_2_freebsd_flags {
    my ($self, $conf) = @_;

    my $flags = "WITH_OPENSSL_PORT=yes";
    $flags .= ",WITH_PROXY_MODULES=yes" if $conf->{'install_apache_proxy'};
#   $flags .= ",WITH_BERKELEY_DB=42" if $conf->{'install_apache_bdb'};

    return $flags if ! $conf->{'install_apache_suexec'};

    $flags .= ",WITH_SUEXEC=yes";
    $flags .= ",SUEXEC_DOCROOT=$conf->{'apache_suexec_docroot'}"
        if $conf->{'apache_suexec_docroot'};
    $flags .= ",SUEXEC_USERDIR=$conf->{'apache_suexec_userdir'}"
        if $conf->{'apache_suexec_userdir'};
    $flags .= ",SUEXEC_SAFEPATH=$conf->{'apache_suexec_safepath'}"
        if $conf->{'apache_suexec_safepath'};
    $flags .= ",SUEXEC_LOGFILE=$conf->{'apache_suexec_logfile'}"
        if $conf->{'apache_suexec_logfile'};
    $flags .= ",SUEXEC_UIDMIN=$conf->{'apache_suexec_uidmin'}"
        if $conf->{'apache_suexec_uidmin'};
    $flags .= ",SUEXEC_GIDMIN=$conf->{'apache_suexec_gidmin'}"
        if $conf->{'apache_suexec_gidmin'};
    $flags .= ",SUEXEC_CALLER=$conf->{'apache_suexec_caller'}"
        if $conf->{'apache_suexec_caller'};
    $flags .= ",SUEXEC_UMASK=$conf->{'apache_suexec_umask'}"
        if $conf->{'apache_suexec_umask'};

    return $flags;
}

sub startup {
    my $self = shift;

    my %p = validate( @_, {
            'conf'    => { type=>HASHREF, },
            %std_opts,
        },
    );

    my ( $conf, $fatal, $debug ) = ( $p{'conf'}, $p{'fatal'}, $p{'debug'} );

    if ( $util->is_process_running("httpd") ) {
        $log->audit( "apache->startup: starting Apache, ok  (already started)" );
        return 1;
    }

    if ( $OSNAME eq "freebsd" ) {
        $self->startup_freebsd($conf, $debug);
    };

    if ( $util->is_process_running("httpd") ) {
        $log->audit( "apache->startup: starting Apache, ok" );
        return 1;
    };

    my $apachectl = $util->find_bin( "apachectl", debug=>0 );
    return if ! -x $apachectl;

    $util->syscmd( "$apachectl start", debug=>0 );
}

sub startup_freebsd {
    my $self = shift;
    my ($conf, $debug) = @_;

    require Mail::Toaster::FreeBSD;
    my $freebsd = Mail::Toaster::FreeBSD->new( 'log' => $log );

    $freebsd->conf_check( check=>"apache2_enable", line=>'apache2_enable="YES"' );
    $freebsd->conf_check( check=>"apache22_enable", line=>'apache22_enable="YES"' );
    $freebsd->conf_check( 
        check=>"apache2ssl_enable", line=>'apache2ssl_enable="YES"' );

    my $etcdir = $conf->{'system_config_dir'} || "/usr/local/etc";
    my @rcs = qw/ apache22 apache2 apache apache22.sh apache2.sh apache.sh /;
    foreach ( @rcs ) {
        $util->syscmd( "$etcdir/rc.d/$_ start" ) if -x "$etcdir/rc.d/$_";
    };
}

sub apache2_fixups {

    my ( $self, $conf, $ports_dir ) = @_;

    my $prefix = $conf->{'toaster_prefix'}    || "/usr/local";
    my $htdocs = $conf->{'toaster_http_docs'} || "/usr/local/www/toaster";
    my $cgibin = $conf->{'toaster_cgi_bin'}   || "/usr/local/www/cgi-bin";
    my $ver    = $conf->{'install_apache'};

    unless ( -d $htdocs ) {    # should exist
        print "ERROR: Interesting. What happened to your $htdocs directory? Since it does not exist, I will create it. Verify that the path in toaster-watcher.conf (toaster_http_docs) is set correctly.\n";
        $util->mkdir_system(dir=>$htdocs, debug=>0,fatal=>0);
    }

    unless ( -d $cgibin ) {    # should exist
        print "ERROR: What happened to your $cgibin directory? Since it does not exist, I will create it. Check to verify Is the path in toaster-watcher.conf (toaster_cgi_bin) set correctly?\n";
        $util->mkdir_system(dir=>$cgibin, debug=>0,fatal=>0);
    }

    if ( $OSNAME eq "freebsd" && $ver eq "22" && ! -d "$prefix/www/$ports_dir" ) {
        print "Why doesn't $prefix/www/$ports_dir exist? "
            . "Did Apache install correctly?\n";
        return;
    }

    return 1 if ! $conf->{'toaster_apache_vhost'};
    $self->apache2_install_vhost( $conf );
};

sub apache2_install_vhost {
    my ($self, $conf) = @_;

    my $ver    = $conf->{'install_apache'};
    my $htdocs = $conf->{'toaster_http_docs'} || "/usr/local/www/toaster";
    my $cgibin = $conf->{'toaster_cgi_bin'}   || "/usr/local/www/cgi-bin";
    my $httpd_conf = $self->conf_get_dir(conf=>$conf);
    my ($apache_conf_dir) = $util->path_parse($httpd_conf);

    my $file_to_write = "mail-toaster.conf";
    my $full_path;

    if ( -d "$apache_conf_dir/Includes" ) {
        $full_path = "$apache_conf_dir/Includes/$file_to_write";
    } 
    else {
        $full_path = "$apache_conf_dir/$file_to_write";
    };
    
    my $ssl_key = "etc/apache2/ssl.key/server.key";
    my $ssl_crt = "etc/apache2/ssl.crt/server.crt";

    if ( $ver eq "22" ) {
        $ssl_key = "etc/apache22/server.key";
        $ssl_crt = "etc/apache22/server.crt";
    };

    open my $MT_CONF, ">", "/tmp/$file_to_write";

    my $hostname = $conf->{'toaster_hostname'};
    my $ips      = $util->get_my_ips(only=>"first", debug=>0);
    my $local_ip = $ips->[0];
    my $redirect_host = $hostname;

    require Mail::Toaster::DNS;
    my $dns = Mail::Toaster::DNS->new( 'log' => $log );

    if ( ! $dns->resolve(type=>"A", record=>$hostname) ) {
        $redirect_host = $local_ip;
    };

    print $MT_CONF <<"EO_MAIL_TOASTER_CONF";
#
# Mail-Toaster specific Apache configuration file additions. 
#   These additions must be made to get Squirrelmail, Isoqlog, 
#   and other toaster features to work.
#
# This file is generated automatically, based upon your settings 
#    in toaster-watcher.conf
#
# This should be set in httpd.conf, but is not by default, so we turn it
# on here.
NameVirtualHost *:80

<VirtualHost *:80>
    ServerName $hostname

# the redirect effectively requires all users of your email applications to use ssl
    # connections. This is highly recommended and the default. If you wish to
    # allow your users to connect and send their passwords in clear text,
    # thereby allowing Very Naught People[TM] to hijack their accounts and
    # turn your mail server into a spam relay, then by all means, just go
    # ahead and comment out this redirect. 

    Redirect / https://$redirect_host/

# these settings are ignored while the  redirect is in force. They
# are here for those who want access to the email apps without requiring ssl.

    DocumentRoot $htdocs
    DirectoryIndex index.html
    ScriptAlias /cgi-bin/ "$cgibin/"
</VirtualHost>

# The asterisks for port 443 vhosts really should be replaced with an IP
# address.
<IfModule ssl_module>
    Listen $local_ip:443
    NameVirtualHost $local_ip:443

    AddType application/x-x509-ca-cert .crt
    AddType application/x-pkcs7-crl    .crl
    SSLPassPhraseDialog  builtin
    SSLSessionCache        "shmcb:/var/run/ssl_scache(512000)"
    SSLSessionCacheTimeout  300
    SSLMutex  "file:/var/run/ssl_mutex"
    SSLCipherSuite HIGH:!SSLv2

    <VirtualHost $local_ip:443>
        ServerName $hostname
        DocumentRoot $htdocs
        DirectoryIndex index.html
        ScriptAlias /cgi-bin/ "$cgibin/"

        SSLEngine on
        SSLCertificateFile $ssl_crt
        SSLCertificateKeyFile $ssl_key
    </VirtualHost>
</IfModule>

# these is an override for the default htdocs
# the main difference is having ExecCGI enabled

<Directory "$htdocs">
    Options Indexes FollowSymLinks ExecCGI
    AllowOverride None
    Order allow,deny
    Allow from all
</Directory>

# by default, this is exactly the same as the default included with Apache,
# but if \$cgibin is not the default location, this will catch it.

<Directory "$cgibin">
    AllowOverride None
    Options None
    Order allow,deny
    Allow from all
</Directory>

# don't divulge Apache version. Adds obscurity from scanners
# looking for vulnerable Apache versions.
ServerSignature Off
ServerTokens ProductOnly

# take Cert vulnerability #867593 off the table
<IfModule mod_rewrite.c>
    RewriteEngine On
    RewriteCond %{REQUEST_METHOD} ^(TRACE|TRACK)
    RewriteRule .* - [F]
</IfModule>

EO_MAIL_TOASTER_CONF

    if ( $conf->{'install_php'} ) {
        print $MT_CONF "# enable php parsing
AddType application/x-httpd-php .php
AddType application/x-httpd-php-source .phps
    ";
    };

    if ( $conf->{'install_isoqlog'} ) {
        print $MT_CONF '
Alias /isoqlog/images/ "/usr/local/share/isoqlog/htmltemp/images/"
<Directory "/usr/local/share/isoqlog/htmltemp/images">
    Options None
    AllowOverride None

    Order deny,allow
    deny from all
    #allow from 216.243.3
    AuthUserFile /usr/local/www/WebUsers
    AuthName Isoqlog
    AuthType Basic
    require valid-user
    satisfy any
</Directory>
';
    };

    print $MT_CONF '
Alias /qmailadmin/ "'.$htdocs.'/qmailadmin/"

Alias /squirrelmail/ "/usr/local/www/squirrelmail/"
<Directory "/usr/local/www/squirrelmail">
    DirectoryIndex index.php
    Options Indexes ExecCGI
    AllowOverride None
    Order allow,deny
    Allow from all
</Directory>
';

    if ( $conf->{'install_phpmyadmin'} ) {
        print $MT_CONF '
Alias /phpMyAdmin/ "/usr/local/www/phpMyAdmin/"
<Directory "/usr/local/www/phpMyAdmin">
    DirectoryIndex index.php
    Options Indexes ExecCGI
    AllowOverride None
    Order allow,deny
    Allow from all
</Directory>
';
    };

    print $MT_CONF '
Alias /rrdutil/ "/usr/local/rrdutil/html/"
<Directory "/usr/local/rrdutil/html">
    AllowOverride None
    Order allow,deny
    Allow from all
</Directory>
';

    print $MT_CONF '
Alias /roundcube "/usr/local/www/roundcube/"
<Directory "/usr/local/www/roundcube">
    DirectoryIndex index.php
    AllowOverride All
    Order allow,deny
    Allow from all
</Directory>
';

    print $MT_CONF '
Alias /v-webmail/ "/usr/local/www/v-webmail/htdocs/"
<Directory "/usr/local/www/v-webmail">
    DirectoryIndex index.php
    AllowOverride All
    Order allow,deny
    Allow from all
</Directory>
';

    print $MT_CONF '
Alias /images/vqadmin "'.$htdocs.'/images/vqadmin"
<Directory "' .$cgibin .'/vqadmin">
     deny from all
     Options ExecCGI
     AllowOverride AuthConfig
     Order deny,allow
</Directory>
';

#    if ($conf->{'install_apache'} == 22 ) {
#        print $MT_CONF '
#Alias /icons/ "/usr/local/www/apache22/icons/"
#';
#    }

    close $MT_CONF;

    $util->install_if_changed(
        newfile  => "/tmp/$file_to_write",
        existing => $full_path,
        clean    => 1,
        debug    => 0,
    );
}

sub freebsd_extras {

    my ( $self, $conf, $freebsd ) = @_;

    $freebsd->install_port( "cronolog" );

    # libwww requires this, so we preemptively install it to supress
    # the dialog box it opens
    $freebsd->install_port( "p5-Authen-SASL", 
        options => "#
# This file was generated by mail-toaster
# Options for p5-Authen-SASL-2.10_1
_OPTIONS_READ=p5-Authen-SASL-2.10_1
WITHOUT_KERBEROS=true\n",
    );

    $freebsd->install_port( "p5-libwww" );

    # php stuff
    if ( $conf->{'package_install_method'} eq "packages" ) {
        $freebsd->install_package( "bison" );
        $freebsd->install_package( "gd"  );
    }
    $freebsd->install_port( "bison" );
    $freebsd->install_port( "gd"    );

    if ( $conf->{'install_php'} == "5" ) {
        $freebsd->install_port( "php5",
            flags => "WITH_APACHE=yes WITH_APACHE2=yes BATCH=yes",
        );
    }
    else {
        $freebsd->install_port( "php4",
            flags => "WITH_APACHE=yes WITH_APACHE2=yes BATCH=yes",
        );
    }

    if ( $conf->{'install_2_modperl'} ) {
        $freebsd->install_port( "mod_perl2" );
    }
}

sub conf_get_dir {
    my $self = shift;
    my %p = validate( @_, { 'conf' => HASHREF, %std_opts } );

    my $conf = $p{'conf'};

    my $prefix = $conf->{'toaster_prefix'} || "/usr/local";
    my $apachectl = "$prefix/sbin/apachectl";

    if ( ! -x $apachectl ) {
        $apachectl = $util->find_bin( "apachectl" );
    }

    # the -V flag to apachectl returns this string:
    #  -D SERVER_CONFIG_FILE="etc/apache22/httpd.conf"
    # grab the path to httpd.conf from the string
    if ( grep (/SERVER_CONFIG_FILE/, `$apachectl -V`) =~ /=\"(.*)\"/ ) {

        # and return a fully qualified path to httpd.conf
        return "$prefix/$1" if ( -f "$prefix/$1" && -s "$prefix/$1" );

        $log->error( "apachectl returned $1 as the location of your httpd.conf file but $prefix/$1 does not exist! I'm sorry but I cannot go on like this. Please fix your Apache install and try again.");
    };

    # apachectl did not return anything useful from -V, must be apache 1.x
    my @paths;
    my @found;

    if    ( $OSNAME eq "darwin"  ) {
        push @paths, "/opt/local/etc";
        push @paths, "/private/etc";
    }
    elsif ( $OSNAME eq "freebsd" ) {
        push @paths, "/usr/local/etc";
    }
    elsif ( $OSNAME eq "linux" ) {
        push @paths, "/etc";
    }
    else {
        push @paths, "/usr/local/etc";
        push @paths, "/opt/local/etc";
        push @paths, "/etc";
    }

    PATH:
    foreach my $path ( @paths ) {
        if ( ! -e $path && ! -d $path ) {
            next PATH;
        };

        @found = `find $path -name httpd.conf`;
        chomp @found;
        foreach my $find (@found) {
            if ( -f $find ) {
                return $find;
            };
        };
    };

    return;
}

sub apache_conf_patch {
    my $self = shift;
    my %p = validate(@_, { 'conf' => HASHREF, %std_opts } );

    my $conf   = $p{'conf'};
    my $prefix = $conf->{'toaster_prefix'}    || "/usr/local";
    my $etcdir = $conf->{'system_config_dir'} || "/usr/local/etc";
    my $patchdir   = "$etcdir/apache";
    my $apacheconf = $self->conf_get_dir(conf=>$conf);
    my ($apacheetc) = $apacheconf =~ /(.*)\/httpd\.conf$/;

    $log->audit( "apache_conf_patch: updating httpd.conf for Mail-Toaster");

    if ( $conf->{'install_apache'} == "21" ) {
        return 1;
    };

    return $p{'test_ok'} if defined $p{'test_ok'};

    if ( $conf->{'install_apache'} == 2 && $OSNAME eq "darwin" ) {
        $apacheconf = "/etc/httpd/httpd.conf";
    }

    ( -d $apacheetc )  or croak "apache etc: $apacheetc doesn't exist!\n";
    ( -f $apacheconf ) or croak "apache conf: $apacheconf doesn't exist!\n";

    if ( !-e $apacheconf ) {
        print "\t FAILURE: I couldn't find your httpd.conf!\n";
        return;
    };

    my @lines = $util->file_read($apacheconf);
    foreach my $line ( @lines ) {
        if ( $line =~ q{#Include etc/apache22/extra/httpd-default.conf} ) {
            $line = "Include etc/apache22/extra/httpd-default.conf";
        };
        if ( $line =~ q{#Include etc/apache22/extra/httpd-ssl.conf} ) {
            $line = "Include etc/apache22/extra/httpd-ssl.conf";
        };

        # we want these only in mail-toaster.conf
        if ( $line =~ q{DocumentRoot "/usr/local/www/apache22/data"} ) {
            $line = '#DocumentRoot "/usr/local/www/apache22/data"';
        };
        if ( $line =~ q{ScriptAlias /cgi-bin/ "/usr/local/www/apache22/cgi-bin/"} ) {
            $line = '#ScriptAlias /cgi-bin/ "/usr/local/www/apache22/cgi-bin/"';
        };
    };
    $util->file_write( $apacheconf, lines=>\@lines );
}

sub install_ssl_certs {
    my $self = shift;
    my %p = validate (@_, {
            'conf'  => { type => HASHREF, },
            'type'  => { type => SCALAR, optional=>1, },
            %std_opts,
        }
    );

    my ( $conf, $type ) = ( $p{'conf'}, $p{'type'} );

    $log->audit( "install_ssl_certs: installing self-signed SSL certs for Apache.");

    my $prefix = $conf->{'toaster_prefix'}    || "/usr/local";
    my $etcdir = $conf->{'system_config_dir'} || "/usr/local/etc";

    my $apacheconf = $self->conf_get_dir(conf=>$conf);
    my ($apacheetc) = $util->path_parse($apacheconf);

    $log->audit( "   detected apache config dir $apacheetc.");

    my $crtdir = "$apacheetc/ssl.crt";
    my $keydir = "$apacheetc/ssl.key";

    my $ver = $conf->{'install_apache'};
    $crtdir = $keydir = $apacheetc if ( $ver =~ /^21|22$/ );

    return $p{'test_ok'} if defined $p{'test_ok'};

    $util->mkdir_system( dir => $crtdir ) if ! -d $crtdir;
    $util->mkdir_system( dir => $keydir ) if ! -d $crtdir;

    if ( $type && $type eq "dsa" ) {
        install_dsa_cert($crtdir, $keydir);
    }
    else {
        $self->install_rsa_cert( crtdir=>$crtdir, keydir=>$keydir );
    }
    return 1;
}

sub restart {
    my $self = shift;

    my $sudo = $util->sudo();
    my $etc  = "/usr/local/etc";
    $etc = "/opt/local/etc" if ! -d $etc;
    $etc = "/etc" if ! -d $etc;

    my $restarted = 0;
    foreach my $apa ( qw/ apache apache2 apache.sh apache2.sh / ) {
        next if ! -x "$etc/rc.d/$apa";

        $util->syscmd( "$sudo $etc/rc.d/$apa restart" );
        $restarted++;
    }

    if ( ! $restarted ) {
        my $apachectl = $util->find_bin( "apachectl" ) 
            or return $log->error( "couldn't restart Apache!");

        $util->syscmd( "$sudo $apachectl graceful" );
    }
}

sub RemoveOldApacheSources {

    my ($apache) = @_;

    my @list = glob("apache_1.*");
    foreach my $dir (@list) {
        if ( $dir && $dir ne $apache && $dir !~ /\.tar\.gz$/ ) {
            print "deleting: $dir... ";
            rmtree $dir or croak "couldn't delete $dir: $!\n";
            print "done.";
        }
    }
}

sub openssl_config_note {

    print "\n\t\tATTENTION! ATTENTION!

If you don't like the default values being offered to you, or you 
get tired of typing them in every time you generate a SSL cert, 
edit your openssl.cnf file. ";

    if ( $OSNAME eq "darwin" ) {
        print "On Darwin, it lives at /System/Library/OpenSSL/openssl.cnf.\n";
    } 
    elsif ( $OSNAME eq "freebsd" ) {
        print "On FreeBSD, it lives at /etc/ssl/openssl.cnf and /usr/local/openssl/openssl.cnf\n";
    }
    else {
        print "On most platforms, it lives in 
/etc/ssl/openssl.cnf.\n";
    };

    print "\n You can also run 'toaster_setup.pl -s ssl' to update your openssl.cnf file.\n\n";

    if ( $util->is_interactive ) {
        print chr(7);  # bell
        sleep 3;
    };

    return 1;
}

sub install_dsa_cert {

    my ( $crtdir, $keydir ) = @_;

    if ( -e "$crtdir/server-dsa.crt" ) {
        print "install_ssl_certs: $crtdir/server-dsa.crt is installed!\n";
        return 1;
    }

    openssl_config_note();

    my $crt = "server-dsa.crt";
    my $key = "server-dsa.key";
    my $csr = "server-dsa.csr";

#$util->syscmd( "openssl gendsa 1024 > $keydir/$key" );
#$util->syscmd( "openssl req -new -key $keydir/$key -out $crtdir/$csr" );
#$util->syscmd( "openssl req -x509 -days 999 -key $keydir/$key -in $crtdir/$csr -out $crtdir/$crt" );

#	$util->install_module( "Crypt::OpenSSL::DSA" );
#	require Crypt::OpenSSL::DSA;
#	my $dsa = Crypt::OpenSSL::DSA->generate_parameters( 1024 );
#	$dsa->generate_key;
#	unless ( -e "$crtdir/$crt" ) { $dsa->write_pub_key(  "$crtdir/$crt" ); };
#	unless ( -e "$keydir/$key" ) { $dsa->write_priv_key( "$keydir/$key" ); };
}

sub install_rsa_cert {

    my $self = shift;

    my %p = validate (@_, {
            'crtdir' => { type=>SCALAR },
            'keydir' => { type=>SCALAR },
            'debug'  => { type=>SCALAR, optional=>1, default=>1, },
            'test_ok'=> { type=>SCALAR, optional=>1, },
        },
    );

    my ( $crtdir, $keydir, $debug ) = ($p{'crtdir'}, $p{'keydir'}, $p{'debug'} );

    return $log->error( "keydir ($keydir) is required and missing!" ) if ! $keydir;
    return $log->error( "crtdir ($crtdir) is required and missing!") if ! $crtdir;

    return $p{'test_ok'} if defined $p{'test_ok'};

    $util->mkdir_system(dir=>$keydir, debug=>$debug) if ! -d $keydir;
    $util->mkdir_system(dir=>$crtdir, debug=>$debug) if ! -d $crtdir;

    my $csr = "server.csr";
    my $crt = "server.crt";
    my $key = "server.key";

    if ( -f '/usr/local/openssl/certs/server.crt' ) {
        copy( '/usr/local/openssl/certs/server.crt', "$crtdir/$crt" );
        copy( '/usr/local/openssl/certs/server.key', "$keydir/$key" );
    };

    if ( -f "$crtdir/$crt" && -f "$keydir/$key" ) {
        $log->audit( "   installing server.crt, ok (already done)" );
        return;
    }
    openssl_config_note();

    system "openssl genrsa 1024 > $keydir/$key" if ! -e "$keydir/$key";
    $log->error( "ssl cert key generation failed!") if ! -e "$keydir/$key";

    system "openssl req -new -key $keydir/$key -out $crtdir/$csr" if ! -e "$crtdir/$csr";
    return $log->error( "cert sign request ($crtdir/$csr) generation failed!") if ! -e "$crtdir/$csr";

    system "openssl req -x509 -days 999 -key $keydir/$key -in $crtdir/$csr -out $crtdir/$crt"
        if ! -e "$crtdir/$crt";
    $log->error( "cert generation ($crtdir/$crt) failed!") if ! -e "$crtdir/$crt";

    return 1;
}

1;
__END__


=head1 NAME

Mail::Toaster::Apache - modules for installing, configuring and managing Apache

=head1 SYNOPSIS

Modules for working with Apache. Some are specific to Mail Toaster while most are generic, such as provisioning vhosts for an Apache 2 server. Using just these subs, Apache will be installed, SSL certs generated, and serving.


=head1 DESCRIPTION 

Perl methods for working with Apache. See METHODS.


=head1 METHODS

=over

=item new

   use Mail::Toaster;
   use Mail::Toaster::Apache
   my $log = Mail::Toaster->new(debug=>0)
   my $apache = Mail::Toaster::Apache->new( 'log' => $log );

use this function to create a new apache object. From there you can use all the functions
included in this document.

Each method expect to recieve one or two hashrefs. The first hashref must have a value set for <i>vhost</i> and optional values set for the following: ip, serveralias serveradmin, documentroot, redirect, ssl, sslcert, sslkey, cgi, customlog, customerror.

The second hashref is key/value pairs from sysadmin.conf. See that file for details of what options you can set there to influence the behavior of these methods..


=item InstallApache1

	$apache->install_apache1(src=>"/usr/local/src")

Builds Apache from sources with DSO for all but mod_perl which must be compiled statically in order to work at all.

Will build Apache in the directory as shown. After compile, the script will show you a few options for testing and completing the installation.

Also installs mod_php4 and mod_ssl.


=item	install_2

	use Mail::Toaster::Apache;
	my $apache = new Mail::Toaster::Apache;

	$apache->install_2($conf);

Builds Apache from sources with DSO for all modules. Also installs mod_perl2 and mod_php4.

Currently tested on FreeBSD and Mac OS X. On FreeBSD, the chosen version of php is installed. It installs both the PHP cli and mod_php Apache module. This is done because the SpamAssassin + SQL module requires pear-DB and the pear-DB port thinks it needs the lang/php port installed. There are other ports which also have this requirement so it's best to just have it installed.

This script also builds default SSL certificates, based on your preferences in openssl.cnf (usually in /etc/ssl) and makes a few tweaks to your httpd.conf (for using PHP & perl scripts). 

Values in $conf are set in toaster-watcher.conf. Please refer to that file to see how you can influence your Apache build.


=item apache_conf_patch

	$apache->apache_conf_patch(conf=>$conf);

Patch apache's default httpd.conf file. See the patch in contrib of Mail::Toaster to see what changes are being made.


=item install_ssl_certs

Builds and installs SSL certificates in the locations that Apache expects to find them. This allows me to build a SSL enabled web server with a minimal amount of human interaction.


=item install_rsa_cert

Builds and installs a RSA certificate.

	$apache->install_rsa_cert(crtdir=>$crtdir, keydir=>$keydir);


=item restart

Restarts Apache. 

On FreeBSD, we use the rc.d script if it's available because it's smarter than apachectl. Under some instances, sending apache a restart signal will cause it to crash and not restart. The control script sends it a TERM, waits until it has done so, then starts it back up.

    $apache->restart($vals);



=item install_dsa_cert

Builds and installs a DSA Certificate.









=back

=head2 DEPENDENCIES

Mail::Toaster - http://mail-toaster.org/

=head1 AUTHOR

Matt Simerson <matt@tnpi.net>


=head1 BUGS

None known. Report any to author.


=head1 TODO


=head1 SEE ALSO

The following are all man/perldoc pages: 

 Mail::Toaster 
 Mail::Toaster::Conf
 toaster.conf
 toaster-watcher.conf

 http://matt.simerson.net/computing/mail/toaster/

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2003-2008, The Network People, Inc. All Rights Reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

Neither the name of the The Network People, Inc. nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

=cut


