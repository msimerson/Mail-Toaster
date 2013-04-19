#/usr/bin/perl
use strict;
use warnings;

use 5.008;

# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
use ExtUtils::MakeMaker;
use English qw( -no_match_vars );

$OUTPUT_AUTOFLUSH++;


BEGIN {
    if ( ! eval "require Params::Validate" ) {
        print "\n\tRequired dependencies are not installed!\n\n";
        print "run 'make deps' to install them.\n\n";
    }
}

my $confdir = set_conf_dir();

sub MY::postamble {

'TNPITOASTER	=	html
CONFDIR    =   ' . $confdir . '
MODULES		=	doc/modules
MT		=	Mail::Toaster

conf:
	install -m 0644 toaster.conf-dist $(CONFDIR)
	install -m 0640 toaster-watcher.conf-dist $(CONFDIR)
	echo make conf is deprecated! Use: toaster_setup.pl -s config

docs:
	pod2text bin/toaster_setup.pl           > README
	pod2html --noindex bin/toaster_setup.pl > doc/README.html

	pod2text doc/Changes.pod                > Changes
	pod2html --noindex doc/Changes.pod      > doc/Changes.html

	pod2text lib/toaster.conf.pod           > doc/toaster.conf
	pod2text lib/toaster-watcher.conf.pod   > doc/toaster-watcher.conf

	pod2html --title="$(MT) toaster.conf" lib/toaster.conf.pod           > doc/toaster.conf.html
	pod2html --title="$(MT) watcher.conf" lib/toaster-watcher.conf.pod   > doc/toaster-watcher.conf.html

	pod2html --title="$(MT)"          lib/Mail/Toaster.pm          > $(MODULES)/Toaster.html
	pod2html --title="$(MT)::Apache"  lib/Mail/Toaster/Apache.pm   > $(MODULES)/Apache.html
	pod2html --title="$(MT)::Darwin"  lib/Mail/Toaster/Darwin.pm   > $(MODULES)/Darwin.html
	pod2html --title="$(MT)::DNS"     lib/Mail/Toaster/DNS.pm      > $(MODULES)/DNS.html
	pod2html --title="$(MT)::Ezmlm"   lib/Mail/Toaster/Ezmlm.pm    > $(MODULES)/Ezmlm.html
	pod2html --title="$(MT)::FreeBSD" lib/Mail/Toaster/FreeBSD.pm  > $(MODULES)/FreeBSD.html
	pod2html --title="$(MT)::Logs"    lib/Mail/Toaster/Logs.pm     > $(MODULES)/Logs.html
	pod2html --title="$(MT)::Mysql"   lib/Mail/Toaster/Mysql.pm    > $(MODULES)/Mysql.html
	pod2html --title="$(MT)::Qmail"   lib/Mail/Toaster/Qmail.pm    > $(MODULES)/Qmail.html
	pod2html --title="$(MT)::Setup"   lib/Mail/Toaster/Setup.pm    > $(MODULES)/Setup.html
	pod2html --title="$(MT)::Utility" lib/Mail/Toaster/Utility.pm  > $(MODULES)/Utility.html

	rm pod2htm*

newconf:
	install -m 0644 toaster.conf-dist $(CONFDIR)
	install -m 0640 toaster-watcher.conf-dist $(CONFDIR)
	echo make newconf is deprecated! Use: toaster_setup.pl -s config

cgi:
	echo make cgi is deprecated! Use toaster_setup.pl -s webmail instead.

deps:
	perl bin/install_deps.pl

web:
	install -d $(TNPITOASTER)
	install -d $(TNPITOASTER)/watcher
	install -d $(TNPITOASTER)/etc
	install -d $(TNPITOASTER)/config
	install -d $(TNPITOASTER)/modules
	install -d $(TNPITOASTER)/src

	install bin/toaster_setup.pl       $(TNPITOASTER)/
	install bin/toaster-watcher.pl     $(TNPITOASTER)/watcher/
	install toaster-watcher.conf-dist  $(TNPITOASTER)/watcher/toaster-watcher.conf
	install toaster-watcher.conf-dist  $(TNPITOASTER)/etc/toaster-watcher.conf

	install -m 0644 doc/toaster.conf.html         $(TNPITOASTER)/config/
	install -m 0644 doc/toaster-watcher.conf.html $(TNPITOASTER)/config/

	install -m 0644 $(MODULES)/Toaster.html   $(TNPITOASTER)/modules/
	install -m 0644 $(MODULES)/Apache.html    $(TNPITOASTER)/modules/
	install -m 0644 $(MODULES)/DNS.html       $(TNPITOASTER)/modules/
	install -m 0644 $(MODULES)/Darwin.html    $(TNPITOASTER)/modules/
	install -m 0644 $(MODULES)/Ezmlm.html     $(TNPITOASTER)/modules/
	install -m 0644 $(MODULES)/FreeBSD.html   $(TNPITOASTER)/modules/
	install -m 0644 $(MODULES)/Logs.html      $(TNPITOASTER)/modules/
	install -m 0644 $(MODULES)/Mysql.html     $(TNPITOASTER)/modules/
	install -m 0644 $(MODULES)/Qmail.html     $(TNPITOASTER)/modules/
	install -m 0644 $(MODULES)/Setup.html     $(TNPITOASTER)/modules/
	install -m 0644 $(MODULES)/Utility.html   $(TNPITOASTER)/modules/

	install -m 0644 Mail-Toaster-$(VERSION).tar.gz $(TNPITOASTER)/Mail-Toaster.tar.gz
	install -m 0644 Mail-Toaster-$(VERSION).tar.gz $(TNPITOASTER)/src/Mail-Toaster-$(VERSION).tar.gz
	rm Mail-Toaster-$(VERSION).tar.gz
	rsync -nav html/ www.tnpi.net:/home/tnpi/html/internet/mail/toaster/
';

}

WriteMakefile(
	'NAME'           => 'Mail::Toaster',
	'VERSION_FROM'   => 'lib/Mail/Toaster.pm', # finds $VERSION
	'EXE_FILES'      => [ 'bin/toaster_setup.pl',
                              'bin/toaster-watcher.pl',
                              'bin/maillogs',
                              'bin/qqtool.pl',
                            ],
	'INSTALLSCRIPT'  => '/usr/local/sbin',
    'MIN_PERL_VERSION' => 5.008001,
	'PREREQ_PM'      => {
			'DBI'             => 1,
			'Date::Parse'     => 1,
			'Test::Simple'    => 0,
			'Params::Validate' => .7,
			'Net::DNS'        => 0.20,
			'Email::Valid'    => 0,
			'IO::Socket::SSL' => 0,
			'Mail::Ezmlm'     => 0,
			'Mail::Send'      => 0,
            'version'         => 0,
#			'vpopmail'        => 0,
#			'HTML::Template'  => 1,
            'URI'             => 0,
		},
	AUTHOR            => 'Matt Simerson (matt@tnpi.net)',
	ABSTRACT          => 'Mail::Toaster perl programs and modules',
	LICENSE           => 'bsd',
	PL_FILES          => {},
#	MAN1PODS          => [],
    dist              => { COMPRESS => 'gzip -9f', },
    clean            => {
                            FILES => [  "t/trash",
                                        "pod2htm*",
                                        'html',
                                    ],
                        },
);

sub set_conf_dir {
    my $dir = "/usr/local/etc";
    if  ( $^O eq "darwin") { $dir = "/opt/local/etc" };  # Mac OS X
    return $dir;
}

=head1 LICENCE AND COPYRIGHT

Copyright (c) 2004-2013, The Network People, Inc. All rights reserved.


Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

Neither the name of the The Network People, Inc. nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

=cut
