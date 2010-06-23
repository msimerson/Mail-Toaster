package Mail::Toaster::FreeBSD;

use strict;
use warnings;

our $VERSION = '5.25';

use Cwd;
use Carp;
use File::Copy;
use Params::Validate qw( :all );

use vars qw($err);

use lib 'lib';
use Mail::Toaster 5.25;
my ($toaster, $log, $util );

sub new {
    my $class = shift;
    my %p = validate( @_, {
            toaster => { type=>HASHREF, optional => 1 },
        },
    );

    my $self = { };
    bless( $self, $class );

    $toaster = $log = $p{toaster} || Mail::Toaster->new;
    $util = $toaster->{util};

    bless( $self, $class );
    return $self;
}

sub drive_spin_down {

    my $self = shift;

    my %p = validate(
        @_,
        {   'drive'   => { type => SCALAR, },
            'test_ok' => { type => BOOLEAN, optional => 1 },
            'fatal'   => { type => BOOLEAN, optional => 1 },
            'debug'   => { type => BOOLEAN, optional => 1 },
        },
    );

    my ( $drive, $fatal, $debug )
        = ( $p{'drive'}, $p{'fatal'}, $p{'debug'} );

    return $p{'test_ok'} if defined $p{'test_ok'};

    #TODO: see if the drive exists!

    my $camcontrol = $util->find_bin( "camcontrol", debug => 0, fatal => 0 );
    if ( ! -x $camcontrol ) {
        print "couldn't find camcontrol!\n";
        return;
    };

    print "spinning down backup drive $drive...";
    $util->syscmd( "$camcontrol stop $drive", debug => 0 );
    print "done.\n";
    return 1;
}

sub get_port_category {
    my $self = shift;
    my $port = shift or die "missing port in request\n";

		my ($path) = </usr/ports/*/$port/distinfo>;
        if ( ! $path ) {
            $path = </usr/ports/*/$port/Makefile>;
        };
#warn "path: $path\n";
		return if ! $path;
		my @bits = split( '/', $path );
#warn "bits3: $bits[3]\n";
		return $bits[3];
}

sub get_version {
    my $self  = shift;
    my $debug = shift;

    my $uname = $util->find_bin( "uname", debug => 0 );
    print "found uname: $uname\n" if $debug;

    my $version = `$uname -r`;
    chomp $version;
    print "version is $version\n" if $debug;

    return $version;
}

sub is_port_installed {
    my $self = shift;
    my $port = shift or return $log->error("missing port/package name", fatal=>0);
    my %p    = validate(
        @_,
        {   'alt'     => { type => SCALAR | UNDEF, optional => 1 },
            'fatal'   => { type => BOOLEAN, optional => 1 },
            'debug'   => { type => BOOLEAN, optional => 1 },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my $debug = $p{debug}; my $fatal = $p{fatal};
    my $alt = $p{'alt'} || $port;

    my ( $r, @args );

    $log->audit( "checking for $port");

    return $p{'test_ok'} if defined $p{'test_ok'};

    my $pkg_info = $util->find_bin( 'pkg_info' );
    my @packages = `pkg_info`; chomp @packages;
    my @matches = grep { $_ =~ /^$port|$alt/ } @packages;
    return if scalar @matches == 0;   # no matches

    my ($installed_as) = split(/\s/, $matches[0]);
    $toaster->audit( "port search for $port found $installed_as" );
    return $installed_as;
}

sub install_portupgrade {
    my $self = shift;
    my %p = validate(
        @_,
        {   conf    => { type => HASHREF, optional => 1, },
            fatal   => { type => BOOLEAN, optional => 1, default => 1 },
            debug   => { type => BOOLEAN, optional => 1, default => 1 },
            test_ok => { type => BOOLEAN, optional => 1 },
        },
    );

    my ( $conf, $fatal, $debug ) = ( $p{'conf'}, $p{'fatal'}, $p{'debug'} );

    my $package = $conf->{'package_install_method'} || "packages";

    if ( defined $p{'test_ok'} ) { return $p{'test_ok'}; }

    # if we're running FreeBSD 6, try installing the package as it will do the
    # right thing. On older systems we want to install a (much newer) version
    # of portupgrade from ports

    if ( $self->get_version =~ m/\A6/ ) {
        $self->package_install(
            port  => "portupgrade",
            debug => 0,
            fatal => 0,
        );
    }

    if ( $package eq "packages" ) {
        $self->package_install(
            port  => "ruby18_static",
            alt   => "ruby-1.8",
            debug => 0,
            fatal => 0,
        );
    }

    $self->port_install(
        port  => "portupgrade",
        debug => 0,
        fatal => $fatal,
    );

    return 1 
        if $self->is_port_installed( "portupgrade", fatal => $fatal, debug => 0 );
    return;
}

sub package_install {

    my $self = shift;
    my %p    = validate(
        @_,
        {   'port'  => { type => SCALAR, },
            'alt'   => { type => SCALAR, optional => 1, },
            'url'   => { type => SCALAR, optional => 1, },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
            'test_ok' => { type => BOOLEAN, optional => 1 },
        },
    );

    my ( $package, $alt, $pkg_url, $fatal, $debug )
        = ( $p{'port'}, $p{'alt'}, $p{'url'}, $p{'fatal'}, $p{'debug'} );

    if ( !$package ) {
        return $util->error("sorry, but I really need a package name!");
    }

    $log->audit("package_install: checking if $package is installed")
        if $debug;

    if ( defined $p{'test_ok'} ) { return $p{'test_ok'}; }

    my $r = $self->is_port_installed( $package,
        alt   => $alt,
        debug => $debug,
        fatal => $fatal,
    );
    if ($r) {
        printf "package_install: %-20s installed as (%s).\n", $package, $r
            if $debug;
        return $r;
    }

    print "package_install: installing $package....\n" if $debug;
    $ENV{"PACKAGESITE"} = $pkg_url if $pkg_url;

    my $pkg_add = $util->find_bin( "pkg_add",
        debug => $debug,
        fatal => $fatal
    );
    if ( !$pkg_add || !-x $pkg_add ) {
        carp "couldn't find pkg_add, giving up.";
        return;
    }

    my $r2 = $util->syscmd( "$pkg_add -r $package", debug => 0 );

    if   ( !$r2 ) { print "\t pkg_add failed\t "; }
    else          { print "\t pkg_add success\t " if $debug }

    print "done.\n" if $debug;

    unless (
        $self->is_port_installed( $package,
            alt   => $alt,
            debug => $debug,
            fatal => $fatal,
        )
        )
    {
        print "package_install: Failed #1, trying alternate package site.\n";
        $ENV{"PACKAGEROOT"} = "ftp://ftp2.freebsd.org";
        $util->syscmd( "$pkg_add -r $package", debug => 0 );

        unless (
            $self->is_port_installed( $package,
                alt   => $alt,
                debug => $debug,
                fatal => $fatal,
            )
            )
        {
            print
                "package_install: Failed #2, trying alternate package site.\n";
            $ENV{"PACKAGEROOT"} = "ftp://ftp3.freebsd.org";
            $util->syscmd( "$pkg_add -r $package", debug => 0 );

            unless (
                $self->is_port_installed( $package,
                    alt   => $alt,
                    debug => $debug,
                    fatal => $fatal,
                )
                )
            {
                print
                    "package_install: Failed #3, trying alternate package site.\n";
                $ENV{"PACKAGEROOT"} = "ftp://ftp4.freebsd.org";
                $util->syscmd( "$pkg_add -r $package", debug => 0 );
            }
        }
    }

    unless (
        $self->is_port_installed( $package,
            alt   => $alt,
            debug => $debug,
            fatal => $fatal,
        )
        )
    {
        carp
            "package_install: Failed again! Sorry, I can't install the package $package!\n";
        return;
    }

    return $r;
}

sub port_install {
    my $self = shift;
    my $portname = shift or return $log->error("missing port/package name", fatal=>0);
    my %p    = validate(
        @_,
        {   dir      => { type => SCALAR, optional => 1 },
            category => { type => SCALAR|UNDEF, optional => 1 },
            check    => { type => SCALAR,  optional => 1 },
            flags    => { type => SCALAR,  optional => 1 },
            options  => { type => SCALAR,  optional => 1 },
            fatal    => { type => BOOLEAN, optional => 1 },
            debug    => { type => BOOLEAN, optional => 1 },
            test_ok  => { type => BOOLEAN, optional => 1 },
        },
    );

    my ( $options, $fatal, $debug ) = ( $p{options}, $p{fatal}, $p{debug} );

    my $make_defines = "";
    my @defs;

    return $p{test_ok} if defined $p{test_ok};

    my $check = $p{check} || $portname;
    my $as = $self->is_port_installed( $check, fatal => $fatal );
    if ($as) {
        $log->audit( "port_install: $portname install, ok ($as)" );
        return 1;
    }

    warn "port_install: installing $portname\n";

    my $port_dir = $p{dir} || $portname;
    $port_dir =~ s/::/-/g if $port_dir =~ /::/;

    my $start_directory = Cwd::getcwd();
		my $category = $p{category} || $self->get_port_category($portname) 
            or die "unable to find port directory for port $portname\n";

		my $path = "/usr/ports/$category/$port_dir";
		-d $path && chdir $path or croak "couldn't cd to $path: $!\n";

    $log->audit("port_install: installing $portname");

    # these are the "make -DWITH_OPTION" flags
    if ( $p{flags} ) {
        @defs = split( /,/, $p{flags} );
        foreach my $def (@defs) {

            # if provided in the DEFINE=VALUE format, use it as is
            if ( $def =~ /=/ ) { $make_defines .= " $def " }

            # otherwise, we need to prepend the -D flag
            else { $make_defines .= " -D$def " }
        }
    }

    if ($options) {
        $self->port_options( port => $portname, opts => $options );
    }

    if ( $portname eq "qmail" ) {
        $util->syscmd( "make clean && make $make_defines install && make clean", 
            debug => $debug
        );
    }
    elsif ( $portname eq "ezmlm-idx" ) {
        $util->syscmd( "make clean && make $make_defines install",
            debug => $debug,
            fatal => $fatal
        );
        copy( "work/ezmlm-0.53/ezmlmrc", "/usr/local/bin" );
        $util->syscmd( "make clean", debug => $debug, fatal => $fatal);
    }
    else {

        # reset our PATH, to make sure we use our system supplied tools
        $ENV{PATH}
            = "/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin";

        # the vast majority of ports work great this way
        print "running: make $make_defines install clean\n";
        system "make clean";
        system "make $make_defines";
        system "make $make_defines install";
        system "make clean";
    }
    print "done.\n" if $debug;

    # return to our original working directory
    chdir($start_directory);

    $as = $self->is_port_installed( $check, debug => $debug, fatal => $fatal,);
    if ($as) {
        $log->audit( "port_install: $portname install, ok ($as)" );
        return 1;
    }

    $log->audit( "port_install: $portname install, FAILED" );
    $self->port_install_try_manual( $portname, $path );

    if ( $portname =~ /\Ap5\-(.*)\z/ ) {
        my $p_name = $1;
        $p_name =~ s/\-/::/g;

        print <<"EO_PERL_MODULE_MANUAL";
Since it was a perl module that failed to install,  you could also try
manually installing via CPAN. Try something like this:

       perl -MCPAN -e 'install $p_name'

EO_PERL_MODULE_MANUAL
    };

    croak
        "FATAL FAILURE: Install of $portname failed. Please fix and try again.\n"
        if $fatal;
    return;
}

sub port_install_try_manual {
    my ($self, $portname, $path ) = @_;
    print <<"EO_PORT_TRY_MANUAL";

    Automatic installation of port $portname failed! You can try to install $portname manually
using the following commands:

        cd $path
        make
        make install clean

    If that does not work, make sure your ports tree is up to date and try again. You
can also check out the "Dealing With Broken Ports" article on the FreeBSD web site:

        http://www.freebsd.org/doc/en_US.ISO8859-1/books/handbook/ports-broken.html

If none of those options work out, there may be something "unique" about your system
that is the source of the  problem, or the port my just be broken. You have several
choices for proceeding. You can:

    a. Wait until the port is fixed
    b. Try fixing it yourself
    c. Get someone else to fix it

EO_PORT_TRY_MANUAL
}

sub port_options {
    my $self = shift;
    my %p = validate(
        @_,
        {   port  => SCALAR,
            opts  => SCALAR,
            debug => { type => BOOLEAN, optional => 1, default => 1, },
            fatal => { type => BOOLEAN, optional => 1, default => 1, },
            test_ok => { type => BOOLEAN, optional => 1, },
        },
    );

    my ( $port, $opts, $fatal ) = ( $p{port}, $p{opts}, $p{fatal} );

    return $p{test_ok} if defined $p{test_ok};

    if ( !-d "/var/db/ports/$port" ) {
        $util->mkdir_system(
            dir   => "/var/db/ports/$port",
            debug => 0,
            fatal => $fatal
        );
    }

    $util->file_write( "/var/db/ports/$port/options",
        lines => [$opts],
        debug => 0,
        fatal => $fatal
    );
}

sub ports_update {

    my $self = shift;

    my %p = validate(
        @_,
        {   conf    => { type => HASHREF, optional => 1, },
            fatal   => { type => BOOLEAN, optional => 1, default => 1 },
            debug   => { type => BOOLEAN, optional => 1, default => 1 },
            test_ok => { type => BOOLEAN, optional => 1, },
        },
    );

    my ( $conf, $fatal, $debug ) = ( $p{'conf'}, $p{'fatal'}, $p{'debug'} );

    return $p{test_ok} if defined $p{test_ok};

    if ( !-w "/usr/ports" ) {
        carp
            "you do not have write permission on /usr/ports, I cannot update your ports tree.";
        return;
    }

    my $supfile = $conf->{'cvsup_supfile_ports'} || "portsnap";

    return $self->portsnap( debug => $debug, fatal => $fatal );

    $self->install_portupgrade(
        conf  => $conf,
        debug => $debug,
        fatal => $fatal
    ) if $conf->{'install_portupgrade'};

    return 1;
}

sub portsnap {

    my $self = shift;
    my %p    = validate(
        @_,
        {   'fatal'   => { type => BOOLEAN, optional => 1, default => 1 },
            'debug'   => { type => BOOLEAN, optional => 1, default => 1 },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my ( $conf, $fatal, $debug ) = ( $p{'conf'}, $p{'fatal'}, $p{'debug'} );

    return $p{'test_ok'} if defined $p{'test_ok'};

    # should be installed already on FreeBSD 5.5 and 6.x
    my $portsnap
        = $util->find_bin( "portsnap", fatal => 0, debug => $debug );
    my $ps_conf = "/usr/local/etc/portsnap.conf";

    unless ( $portsnap && -x $portsnap ) {
        $self->port_install( "portsnap",
            'debug' => $debug,
            'fatal' => $fatal,
        );

        if ( !-e $ps_conf ) {
            if ( -e "$ps_conf.sample" ) {
                copy( "$ps_conf.sample", $ps_conf );
            }
            else {
                warn "WARNING: portsnap configuration file is missing!\n";
            }
        }

        $portsnap = $util->find_bin( "portsnap", fatal => 0, debug => $debug);
        unless ( $portsnap && -x $portsnap ) {
            return $util->error(
                "portsnap is not installed (correctly). I cannot go on!");
        }
    }

    if ( !-e $ps_conf ) {
        $portsnap .= " -s portsnap.freebsd.org";
    }

    # grabs the latest updates from the portsnap servers
    $util->syscmd( "$portsnap fetch", debug => 0, fatal => $fatal );

    if ( !-e "/usr/ports/.portsnap.INDEX" ) {
        print "\a
    COFFEE BREAK TIME: this step will take a while, dependent on how fast your
    disks are. After this initial extract, portsnap updates are much quicker than
    doing a cvsup and require less bandwidth (good for you, and the FreeBSD 
    servers). Please be patient.\n\n";
        sleep 2;
        $util->syscmd( "$portsnap extract", debug => 0, fatal => $fatal);
    }
    else {
        $util->syscmd( "$portsnap update", debug => 0, fatal => $fatal);
    }

    return 1;
}

sub conf_check {

    my $self = shift;

    my %p = validate(
        @_,
        {   'check' => { type => SCALAR, },
            'line'  => { type => SCALAR, },
            'file'  => { type => SCALAR,  optional => 1, },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
            test_ok => { type => BOOLEAN, optional => 1, },
        },
    );

    my %std_opts = ( fatal => $p{fatal}, debug => $p{debug} );
    my $check = $p{check};
    my $line  = $p{line};
    my $file  = $p{file} || "/etc/rc.conf";

    return $p{'test_ok'} if defined $p{'test_ok'};

    my $changes;
    my @lines = $util->file_read( $file );
    foreach ( @lines ) {
        next if $_ !~ /^$check\=/;
        return $log->audit("conf_check: no change to $check") if $_ eq $line;
        $log->audit("\tchanged:\n$_\n\tto:\n$line\n" );
        $_ = $line;
        $changes++;
    };
    if ( $changes ) {
        $util->file_write( $file, lines => \@lines, %std_opts ) and return 1;
    };

    $util->file_write( $file, append => 1, lines => [$line], %std_opts ) and return 1;

    @lines = $util->file_read( $file );
    return 1 if scalar grep { /$check/ } @lines;

    return $log->error( "conf_check tried to write to $file:\n$line: $!", %std_opts);
}

1;
__END__


=head1 NAME

Mail::Toaster::FreeBSD - FreeBSD specific Mail::Toaster functions.

=head1 SYNOPSIS

Primarily functions for working with FreeBSD ports (updating, installing, configuring with custom options, etc) but also includes a suite of methods for FreeBSD managing jails.


=head1 DESCRIPTION

Usage examples for each subroutine are included.


=head1 SUBROUTINES

=over

=item new

	use Mail::Toaster::FreeBSD;
	my $fbsd = Mail::Toaster::FreeBSD->new;


=item is_port_installed

Checks to see if a port is installed. 

    $fbsd->is_port_installed( "p5-CGI" );

 arguments required
   port - the name of the port/package

 arguments optional:
   alt - alternate package name. This can help as ports evolve and register themselves differently in the ports database.

 result:
   0 - not installed
   1 - if installed 


=item jail_create

    $fbsd->jail_create( );

 arguments required:
    ip        - 10.0.1.1
    
 arguments optional:
    hostname  - jail36.example.com,
    jail_home - /home/jail,
    debug

If hostname is not passed and reverse DNS is set up, it will
be looked up. Otherwise, the hostname defaults to "jail".

jail_home defaults to "/home/jail".

Here's an example of how I use it:

    ifconfig fxp0 inet alias 10.0.1.175/32

    perl -e 'use Mail::Toaster::FreeBSD;  
         my $fbsd = Mail::Toaster::FreeBSD->new; 
         $fbsd->jail_create( ip=>"10.0.1.175" )';

After running $fbsd->jail_create, you need to set up the jail. 
At the very least, you need to:

    1. set root password
    2. create a user account
    3. get remote root 
        a) use sudo (pkg_add -r sudo; visudo)
        b) add user to wheel group (vi /etc/group)
        c) modify /etc/ssh/sshd_config to permit root login
    4. install perl (pkg_add -r perl)

Here's how I set up my jails:

    pw useradd -n matt -d /home/matt -s /bin/tcsh -m -h 0
    passwd root
    pkg_add -r sudo rsync perl5.8
    rehash; visudo
    sh /etc/rc

Ssh into the jail from another terminal. Once successfully 
logged in with root privs, you can drop the initial shell 
and access the jail directly.

Read the jail man pages for more details. Read the perl code
to see what else it does.


=item jail_delete

Delete a jail.

  $freebsd->jail_delete( ip=>'10.0.1.160' );

This script unmounts the proc and dev filesystems and then nukes the jail directory.

It would be a good idea to shut down any processes in the jail first.


=item jail_start

Starts up a FreeBSD jail.

	$fbsd->jail_start( ip=>'10.0.1.1', hostname=>'jail03.example.com' );


 arguments required:
    ip        - 10.0.1.1,

 arguments optional:
    hostname  - jail36.example.com,
    jail_home - /home/jail,
    debug

If hostname is not passed and reverse DNS is set up, it will be
looked up. Otherwise, the hostname defaults to "jail".

jail_home defaults to "/home/jail".

Here's an example of how I use it:

    perl -e 'use Mail::Toaster::FreeBSD; 
      $fbsd = Mail::Toaster::FreeBSD->new;
      $fbsd->jail_start( ip=>"10.0.1.175" )';


    
=item port_install

    $fbsd->port_install( "openldap2" );

That's it. Really. Well, OK, sometimes it can get a little more complex. port_install checks first to determine if a port is already installed and if so, skips right on by. It is very intelligent that way. However, sometimes port maintainers do goofy things and we need to override settings that would normally work. A good example of this is currently openldap2. 

If you want to install OpenLDAP 2, then you can install from any of:

		/usr/ports/net/openldap2
		/usr/ports/net/openldap20
		/usr/ports/net/openldap21
		/usr/ports/net/openldap22

So, a full complement of settings could look like:
  
    $freebsd->port_install( "openldap2", 
		dir   => "openldap22",
		check => "openldap-2.2",
		flags => "NOPORTDOCS=true", 
		fatal => 0,
		debug => 1,
	);

 arguments required:
   port - the name of the directory in which the port resides

 arguments optional:
   dir   - overrides 'port' for the build directory
   check - what to test for to determine if the port is installed (see note #1)
   flags - comma separated list of arguments to pass when building
   fatal
   debug

 NOTES:   

#1 - On rare occasion, a port will get installed as a name other than the ports name. Of course, that wreaks all sorts of havoc so when one of them nasties is found, you can optionally pass along a fourth parameter which can be used as the port installation name to check with.


=item package_install

	$fbsd->package_install( port=>"ispell" );

Suggested usage: 

	unless ( $fbsd->package_install( port=>"ispell" ) ) {
		$fbsd->port_install( "ispell" );
	};

Installs the selected package from FreeBSD packages. If the first install fails, it will try again using an alternate FTP site (ftp2.freebsd.org). If that fails, it returns 0 (failure) so you know it failed and can try something else, like installing via ports.

If the package is registered in FreeBSD's package registry as another name and you want to check against that name (so it doesn't try installing a package that's already installed), instead, pass it along as alt.

 arguments required:
    port - the name of the package to install

 arguments optional:
    alt  - a name the package is registered in the ports tree as
    url  - a URL to fetch the package from

See the pkg_add man page for more details on using an alternate URL.


=item ports_update

Updates the FreeBSD ports tree (/usr/ports/).

    $fbsd->ports_update(conf=>$conf);

 arguments required:
   conf - a hashref
 
See the docs for toaster-watcher.conf for complete details.


=item conf_check

    $fbsd->conf_check(check=>"snmpd_enable", line=>"snmpd_enable=\"YES\"");

The above example is for snmpd. This checks to verify that an snmpd_enable line exists in /etc/rc.conf. If it doesn't, then it will add it by appending the second argument to the file.


=back

=head1 AUTHOR

Matt Simerson <matt@tnpi.net>

=head1 BUGS

None known. Report any to author.

=head1 TODO

Needs more documentation.

=head1 SEE ALSO

The following are all man/perldoc pages: 

 Mail::Toaster 
 Mail::Toaster::Conf
 toaster.conf
 toaster-watcher.conf

 http://mail-toaster.org/
 http://www.tnpi.net/computing/freebsd/


=head1 COPYRIGHT

Copyright 2003-2009, The Network People, Inc. All Rights Reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

Neither the name of the The Network People, Inc. nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

=cut
