package Mail::Toaster::Utility;

our $VERSION = '5.29';

use strict;
use warnings;

use Cwd;
use Carp;
use English qw( -no_match_vars );
use File::Copy;
use File::Path;
use File::stat;
use Params::Validate qw(:all);
use Scalar::Util qw( openhandle );
use URI;

use lib 'lib';
use vars qw/ $log /;

sub new {
    my $class = shift;
    my %p     = validate( @_,
        {   'log' => { type => OBJECT,  optional => 1 },
            debug => { type => BOOLEAN, optional => 1, default => 1 },
            fatal => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    $log = $p{'log'};
    if ( ! $log ) {
        my @bits = split '::', $class; pop @bits;
        my $parent_class = join '::', grep { defined $_ } @bits;
        eval "require $parent_class";
        $log = $parent_class->new();
    };

    my $self = {
        'log' => $log,
        debug => $p{debug},
        fatal => $p{fatal},
    };
    bless $self, $class;
    $log->audit( $class . sprintf( " loaded by %s, %s, %s", caller ) );
    return $self;
}

sub ask {
    my $self = shift;
    my $question = shift;
    my %p = validate(
        @_,
        {   default  => { type => SCALAR,  optional => 1 },
            timeout  => { type => SCALAR,  optional => 1 },
            password => { type => BOOLEAN, optional => 1, default => 0 },
            test_ok  => { type => BOOLEAN, optional => 1 },
        }
    );

    my $pass     = $p{password};
    my $default  = $p{default};

    if ( ! $self->is_interactive() ) {
        $log->audit( "not running interactively, can not prompt!");
        return $default;
    }

    return $log->error( "ask called with \'$question\' which looks unsafe." )
        if $question !~ m{\A \p{Any}* \z}xms;

    my $response;

    return $p{test_ok} if defined $p{test_ok};

PROMPT:
    print "Please enter $question";
    print " [$default]" if ( $default && !$pass );
    print ": ";

    system "stty -echo" if $pass;

    if ( $p{timeout} ) {
        eval {
            local $SIG{ALRM} = sub { die "alarm\n" };
            alarm $p{timeout};
            $response = <STDIN>;
            alarm 0;
        };
        if ($EVAL_ERROR) {
            $EVAL_ERROR eq "alarm\n" ? print "timed out!\n" : warn;
        }
    }
    else {
        $response = <STDIN>;
    }

    if ( $pass ) {
        print "Please enter $question (confirm): ";
        my $response2 = <STDIN>;
        unless ( $response eq $response2 ) {
            print "\nPasswords don't match, try again.\n";
            goto PROMPT;
        }
        system "stty echo";
        print "\n";
    }

    chomp $response;

    return $response if $response; # if they typed something, return it
    return $default if $default;   # return the default, if available
    return '';                     # return empty handed
}

sub archive_expand {
    my $self = shift;
    my %p = validate(
        @_,
        {   'archive' => { type => SCALAR, },
            'fatal'   => { type => BOOLEAN, optional => 1, default => 1 },
            'debug'   => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my $archive = $p{archive};
    my %std_args = ( debug => $p{debug}, fatal => $p{fatal} );

    my $r;

    if ( !-e $archive ) {
        if    ( -e "$archive.tar.gz" )  { $archive = "$archive.tar.gz" }
        elsif ( -e "$archive.tgz" )     { $archive = "$archive.tgz" }
        elsif ( -e "$archive.tar.bz2" ) { $archive = "$archive.tar.bz2" }
        else {
            return $log->error( "file $archive is missing!", %std_args );
        }
    }

    $log->audit("found $archive");

    $ENV{PATH} = '/bin:/usr/bin'; # do this or taint checks will blow up on ``

    return $log->error( "unknown archive type: $archive", %std_args )
        if $archive !~ /[bz2|gz]$/;

    # find these binaries, we need them to inspect and expand the archive
    my $tar  = $self->find_bin( 'tar',  %std_args);
    my $file = $self->find_bin( 'file', %std_args);

    my %types = (
        gzip => { bin => 'gunzip',  content => 'gzip',       },
        bzip => { bin => 'bunzip2', content => 'b(un)?zip2', }, 
            # on BSD bunzip2, on Linux bzip2
    );

    my $type
        = $archive =~ /bz2$/ ? 'bzip'
        : $archive =~ /gz$/  ? 'gzip'
        :  return $log->error( 'unknown archive type', %std_args);

    # make sure the archive contents match the file extension
    return $log->error( "$archive not a $type compressed file", %std_args)
        unless grep ( /$types{$type}{content}/, `$file $archive` );

    my $bin = $self->find_bin( $types{$type}{bin}, %std_args);

    $self->syscmd( "$bin -c $archive | $tar -xf -" )
        or  return $log->error( "error extracting $archive", %std_args );

    $log->audit( "extracted $archive" );
    return 1;
}

sub chmod {
    my $self = shift;
    my %p = validate(
        @_,
        {   'file'        => { type => SCALAR,  optional => 1, },
            'file_or_dir' => { type => SCALAR,  optional => 1, },
            'dir'         => { type => SCALAR,  optional => 1, },
            'mode'        => { type => SCALAR,  optional => 0, },
            'sudo'        => { type => BOOLEAN, optional => 1, default => 0 },
            'fatal'       => { type => BOOLEAN, optional => 1, default => 1 },
            'debug'       => { type => BOOLEAN, optional => 1, default => 1 },
            'test_ok'     => { type => BOOLEAN, optional => 1 },
        }
    );

    my $mode = $p{mode};
    my %std_args = ( debug => $p{debug}, fatal => $p{fatal} );

    my $file = $p{file} || $p{file_or_dir} || $p{dir}
        or return $log->error( "invalid params to chmod in ". ref $self  );

    if ( $p{sudo} ) {
        my $chmod = $self->find_bin( 'chmod', debug => 0 );
        my $sudo  = $self->sudo();
        $self->syscmd( "$sudo $chmod $mode $file", debug => 0 ) 
            or return $log->error( "couldn't chmod $file: $!", %std_args );
    }

    # note the conversion of ($mode) to an octal value. Very important!
    CORE::chmod( oct($mode), $file ) or
        return $log->error( "couldn't chmod $file: $!", %std_args);

    $log->audit("chmod $mode $file");
}

sub chown {
    my $self = shift;
    my %p = validate(
        @_,
        {   'file'        => { type => SCALAR, optional => 1, },
            'file_or_dir' => { type => SCALAR, optional => 1, },
            'dir'         => { type => SCALAR, optional => 1, },
            'uid'         => { type => SCALAR, optional => 0, },
            'gid'         => { type => SCALAR, optional => 1, default => -1 },
            'sudo'    => { type => BOOLEAN, optional => 1, default => 0 },
            'fatal'   => { type => BOOLEAN, optional => 1, default => 1 },
            'debug'   => { type => BOOLEAN, optional => 1, default => 1 },
            'test_ok' => { type => BOOLEAN, optional => 1 },
        }
    );

    my $uid = $p{uid};
    my %std_args = ( debug => $p{debug}, fatal => $p{fatal} );

    my $file = $p{file} || $p{file_or_dir} || $p{dir}
        or return $log->error( "missing file or dir", %std_args );

    $log->audit("chown: preparing to chown $uid $file");

    return $log->error( "file $file does not exist!", %std_args ) 
        if ! -e $file;

    # sudo forces us to use the system chown instead of the perl builtin
    return $self->chown_system( %std_args,
        dir   => $file,
        user  => $uid,
        group => $p{gid},
    ) if $p{sudo};

    # if uid or gid is not numeric, convert it
    my ( $nuid, $ngid );

    if ( $uid =~ /\A[0-9]+\z/ ) {
        $nuid = int($uid);
        $log->audit("using $nuid from int($uid)");
    }
    else {
        $nuid = getpwnam($uid);
        return $log->error( "failed to get uid for $uid", %std_args) if ! defined $nuid;
        $log->audit("converted $uid to a number: $nuid");
    }

    if ( $p{gid} =~ /\A[0-9\-]+\z/ ) {
        $ngid = int( $p{gid} );
        $log->audit("using $ngid from int($p{gid})");
    }
    else {
        $ngid = getgrnam( $p{gid} );
        return $log->error( "failed to get gid for $p{gid}", %std_args) if ! defined $ngid;
        $log->audit("converted $p{gid} to numeric: $ngid");
    }

    chown( $nuid, $ngid, $file )
        or return $log->error( "couldn't chown $file: $!",%std_args);

    return 1;
}

sub chown_system {
    my $self = shift;
    my %p = validate(
        @_,
        {   'file'        => { type => SCALAR,  optional => 1, },
            'file_or_dir' => { type => SCALAR,  optional => 1, },
            'dir'         => { type => SCALAR,  optional => 1, },
            'user'        => { type => SCALAR,  optional => 0, },
            'group'       => { type => SCALAR,  optional => 1, },
            'recurse'     => { type => BOOLEAN, optional => 1, },
            'fatal'       => { type => BOOLEAN, optional => 1, default => 1 },
            'debug'       => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my ( $user, $group, $recurse ) = ( $p{user}, $p{group}, $p{recurse} );
    my %std_args = ( debug => $p{debug}, fatal => $p{fatal} );

    my $dir = $p{dir} || $p{file_or_dir} || $p{file} or
        return $log->error( "missing file or dir", %std_args ); 

    my $cmd = $self->find_bin( 'chown', %std_args );

    $cmd .= " -R"     if $recurse;
    $cmd .= " $user";
    $cmd .= ":$group" if $group;
    $cmd .= " $dir";

    $log->audit( "cmd: $cmd" );

    $self->syscmd( $cmd, fatal => 0, debug => 0 ) or 
        return $log->error( "couldn't chown with $cmd: $!", %std_args);

    my $mess;
    $mess .= "Recursively " if $recurse;
    $mess .= "changed $dir to be owned by $user";
    $log->audit( $mess );

    return 1;
}

sub clean_tmp_dir {
    my $self = shift;
    my %p = validate(
        @_,
        {   'dir'   => { type => SCALAR,  optional => 0, },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my $dir = $p{dir};
    my ($debug, $fatal) = ($p{debug}, $p{fatal});

    my $before = cwd;   # remember where we started

    return $log->error( "couldn't chdir to $dir: $!", fatal => $fatal )
        if !chdir $dir;

    foreach ( $self->get_dir_files( dir => $dir ) ) {
        next unless $_;

        my ($file) = $_ =~ /^(.*)$/;

        $log->audit( "deleting file $file" );

        if ( -f $file ) {
            unlink $file or
                $self->file_delete( file => $file, debug => $debug );
        }
        elsif ( -d $file ) {
            use File::Path;
            rmtree $file or return $log->error( "couldn't delete $file");
        }
        else {
            $log->audit( "Cannot delete unknown entity: $file" );
        }
    }

    chdir $before;
    return 1;
}

sub cwd_source_dir {
    my $self = shift;
    my %p = validate(
        @_,
        {   'dir'   => { type => SCALAR,  optional => 0, },
            'src'   => { type => SCALAR,  optional => 1, },
            'sudo'  => { type => BOOLEAN, optional => 1, },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my ( $dir, $src, $sudo, ) = ( $p{dir}, $p{src}, $p{sudo}, );

    my %std_args = ( debug => $p{debug}, fatal => $p{fatal} );

    return $log->error( "Something (other than a directory) is at $dir and " . 
        "that's my build directory. Please remove it and try again!" )
        if ( -e $dir && !-d $dir );

    if ( !-d $dir ) {

        _try_mkdir( $dir ); # use the perl builtin mkdir

        if ( !-d $dir ) {
            $log->audit( "trying again with system mkdir...");
            $self->mkdir_system( dir => $dir, %std_args);

            if ( !-d $dir ) {
                $log->audit( "trying one last time with $sudo mkdir -p....");
                $self->mkdir_system( dir  => $dir, sudo => 1, %std_args) 
                    or return $log->error("Couldn't create $dir.");
            }
        }
    }

    chdir $dir or return $log->error( "FAILED to cd to $dir: $!");
    return 1;
}

sub _try_mkdir {
    my ( $dir ) = @_;
    mkpath( $dir, 0, 0755) 
        or return $log->error( "mkdir $dir failed: $!");
    $log->audit( "created $dir");
    return 1;
}

sub file_archive {
    my $self = shift;
    my $file = shift or return $log->error("missing filename in request");
    my %p = validate(
        @_,
        {   'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
            'sudo'  => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my $date = time;
    my %std_args = ( debug => $p{debug}, fatal => $p{fatal} );

    return $log->error( "file ($file) is missing!", %std_args )
        if !-e $file;

    # see if we can write to both files (new & archive) with current user
    if (    $self->is_writable( file => $file, %std_args )
         && $self->is_writable( file => "$file.$date", %std_args ) ) {

        # we have permission, use perl's native copy
        if ( copy( $file, "$file.$date" ) ) {
            $log->audit("file_archive: $file backed up to $file.$date");
            return "$file.$date" if -e "$file.$date";
        }
    }

    # we failed with existing permissions, try to escalate
    if ( $< != 0 ) {   # we're not root
        if ( $p{sudo} ) {
            my $sudo = $self->sudo( %std_args );
            my $cp = $self->find_bin( 'cp', %std_args );

            if ( $sudo && $cp && -x $cp ) {
                $self->syscmd( "$sudo $cp $file $file.$date", %std_args);
            }
            else {
                $log->audit(
                    "file_archive: sudo or cp was missing, could not escalate."
                );
            }
        }
    }

    if ( -e "$file.$date" ) {
        $log->audit("$file backed up to $file.$date");
        return "$file.$date";
    }

    return $log->error( "backup of $file to $file.$date failed: $!", %std_args);
}

sub file_delete {
    my $self = shift;
    my %p = validate(
        @_,
        {   'file'  => { type => SCALAR },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
            'sudo'  => { type => BOOLEAN, optional => 1, default => 0 },
        }
    );

    my $file = $p{file};
    my %std_args = ( debug => $p{debug}, fatal => $p{fatal} );

    return $log->error( "$file does not exist", %std_args ) if !-e $file;

    if ( -w $file ) {
        $log->audit( "write permission to $file: ok" );

        unlink $file or return $log->error( "failed to delete $file", %std_args );

        $log->audit( "deleted: $file" );
        return 1;
    }

    if ( !$p{sudo} ) {    # all done
        return -e $file ? undef : 1;
    }

    my $err = "trying with system rm";
    my $rm_command = $self->find_bin( "rm", %std_args );
    $rm_command .= " -f $file";

    if ( $< != 0 ) {      # we're not running as root
        my $sudo = $self->sudo( %std_args );
        $rm_command = "$sudo $rm_command";
        $err .= " (sudo)";
    }

    $self->syscmd( $rm_command, %std_args ) 
        or return $log->error( $err, %std_args );

    return -e $file ? undef : 1;
}

sub file_get {
    my $self = shift;
    my %p = validate(
        @_,
        {   url     => { type => SCALAR },
            dir     => { type => SCALAR, optional => 1 },
            timeout => { type => SCALAR, optional => 1 },
            fatal   => { type => BOOLEAN, optional => 1, default => 1 },
            debug   => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my $url = $p{url};
    my $dir = $p{dir};
    my $debug = $p{debug};
    my $fatal = $p{fatal};

    my ($ua, $response);
    eval "require LWP::Simple";
    return $self->file_get_system( %p ) if $EVAL_ERROR;

    my $uri = URI->new($url);
    my @parts = $uri->path_segments;
    my $file = $parts[-1];  # everything after the last / in the URL
    my $file_path = $file;
    $file_path = "$dir/$file" if $dir;

    $log->audit( "fetching $url" );
    eval { $response = LWP::Simple::mirror($url, $file_path ); };

    if ( $response ) {
        if ( $response == 404 ) {
            return $log->error( "file not found ($url)", fatal => $fatal );
        }
        elsif ($response == 304 ) {
            $log->audit( "result 304: file is up-to-date" );
        }
        elsif ( $response == 200 ) {
            $log->audit( "result 200: file download ok" );
        }
        else {
            $log->error( "unhandled response: $response", fatal => 0 );
        };
    };

    return if ! -e $file_path;
    return $response;
}

sub file_get_system {
    my $self = shift;
    my %p = validate(
        @_,
        {   url     => { type => SCALAR },
            dir     => { type => SCALAR,  optional => 1 },
            timeout => { type => SCALAR,  optional => 1, },
            fatal   => { type => BOOLEAN, optional => 1, default => 1 },
            debug   => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my $dir      = $p{dir};
    my $url      = $p{url};
    my $debug    = $p{debug};
    my %std_args = ( debug => $p{debug}, fatal => $p{fatal} );

    my ($fetchbin, $found);
    if ( $OSNAME eq "freebsd" ) {
        $fetchbin = $self->find_bin( 'fetch', %std_args);
        if ( $fetchbin && -x $fetchbin ) {
            $found = $fetchbin;
            $found .= " -q" unless $debug;
        }
    }
    elsif ( $OSNAME eq "darwin" ) {
        $fetchbin = $self->find_bin( 'curl', %std_args );
        if ( $fetchbin && -x $fetchbin ) {
            $found = "$fetchbin -O";
            $found .= " -s " if !$debug;
        }
    }

    if ( !$found ) {
        $fetchbin = $self->find_bin( 'wget', %std_args);
        $found = $fetchbin if $fetchbin && -x $fetchbin;
    }

    return $log->error( "Failed to fetch $url.\n\tCouldn't find wget. Please install it.", %std_args )
        if !$found;

    my $fetchcmd = "$found $url";

    my $timeout = $p{timeout} || 0;
    if ( ! $timeout ) {
        $self->syscmd( $fetchcmd, %std_args ) or return;
        my $uri = URI->new($url);
        my @parts = $uri->path_segments;
        my $file = $parts[-1];  # everything after the last / in the URL
        if ( -e $file && $dir && -d $dir ) {
            $log->audit("moving file $file to $dir" );
            move $file, "$dir/$file";
            return 1;
        };
    };

    my $r;
    eval {
        local $SIG{ALRM} = sub { die "alarm\n" };
        alarm $timeout;
        $r = $self->syscmd( $fetchcmd, %std_args );
        alarm 0;
    };

    if ($EVAL_ERROR) {    # propagate unexpected errors
        print "timed out!\n" if $EVAL_ERROR eq "alarm\n";
        return $log->error( $EVAL_ERROR, %std_args );
    }

    return $log->error( "error executing $fetchcmd", %std_args) if !$r;
    return 1;
}

sub file_is_newer {
    my $self = shift;
    my %p = validate(
        @_,
        {   f1    => { type => SCALAR },
            f2    => { type => SCALAR },
            debug => { type => SCALAR, optional => 1, default => 1 },
            fatal => { type => SCALAR, optional => 1, default => 1 },
        }
    );

    my ( $file1, $file2 ) = ( $p{f1}, $p{f2} );

    # get file attributes via stat
    # (dev,ino,mode,nlink,uid,gid,rdev,size,atime,mtime,ctime,blksize,blocks)

    $log->audit( "checking age of $file1 and $file2");

    my $stat1 = stat($file1)->mtime;
    my $stat2 = stat($file2)->mtime;

    $log->audit( "timestamps are $stat1 and $stat2");

    return 1 if ( $stat2 > $stat1 );
    return;

    # I could just:
    #
    # if ( stat($f1)[9] > stat($f2)[9] )
    #
    # but that forces the reader to read the man page for stat
    # to see what's happening
}

sub file_read {
    my $self = shift;
    my $file = shift or return $log->error("missing filename in request");
    my %p = validate(
        @_,
        {   'max_lines'  => { type => SCALAR, optional => 1 },
            'max_length' => { type => SCALAR, optional => 1 },
            'fatal'      => { type => BOOLEAN, optional => 1, default => 1 },
            'debug'      => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my ( $max_lines, $max_length ) = ( $p{max_lines}, $p{max_length} );
    my %std_args = ( debug => $p{debug}, fatal => $p{fatal} );

    return $log->error( "$file does not exist!", %std_args) if !-e $file;
    return $log->error( "$file is not readable", %std_args ) if !-r $file;

    open my $FILE, '<', $file or 
        return $log->error( "could not open $file: $OS_ERROR", %std_args );

    my ( $line, @lines );

    if ( ! $max_lines) {
        chomp( @lines = <$FILE> );
        close $FILE;
        return @lines;
# TODO: make max_length work with slurp mode, without doing something ugly like
# reading in the entire line and then truncating it.
    };

    while ( my $i < $max_lines ) {
        if ($max_length) { $line = substr <$FILE>, 0, $max_length; }
        else             { $line = <$FILE>; };
        push @lines, $line;
        $i++;
    }
    chomp @lines;
    close $FILE;
    return @lines;
}

sub file_mode {
    my $self = shift;
    my %p = validate(
        @_,
        {   'file'  => { type => SCALAR },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 0 },
        }
    );

    my $file = $p{file};
    my %std_args = ( debug => $p{debug}, fatal => $p{fatal} );

    return $log->error( "file '$file' does not exist!", %std_args)
        if !-e $file;

    # one way to get file mode (using File::mode)
    #    my $raw_mode = stat($file)->[2];
    ## no critic
    my $mode = sprintf "%04o", stat($file)->[2] & 07777;

    # another way to get it
    #    my $st = stat($file);
    #    my $mode = sprintf "%lo", $st->mode & 07777;

    $log->audit( "file $file has mode: $mode" );
    return $mode;
}

sub file_write {
    my $self = shift;
    my $file = shift or return $log->error("missing filename in request");
    my %p = validate(
        @_,
        {   'lines'  => { type => ARRAYREF },
            'append' => { type => BOOLEAN, optional => 1, default => 0 },
            'mode'  => { type => SCALAR,  optional => 1 },
            'fatal' => { type => BOOLEAN, optional => 1, default => $self->{fatal} },
            'debug' => { type => BOOLEAN, optional => 1, default => $self->{debug} },
        }
    );

    my $append = $p{append};
    my $lines  = $p{lines};
    my %std_args = ( debug => $p{debug}, fatal => $p{fatal} );

    return $log->error( "oops, $file is a directory", %std_args) if -d $file;
    return $log->error( "oops, $file is not writable", %std_args ) 
        if ( ! $self->is_writable( file => $file, %std_args) );

    my $m = "writing";
    my $write_mode = '>';    # (over)write

    if ( $append ) {
        $m = "appending";
        $write_mode = '>>';
        if ( -f $file ) {
            copy $file, "$file.tmp" or return $log->error(
                "couldn't create $file.tmp for safe append", %std_args );
        };
    };

    open my $HANDLE, $write_mode, "$file.tmp" 
        or return $log->error( "file_write: couldn't open $file: $!", %std_args );

    my $c = 0;
    foreach ( @$lines ) { chomp; print $HANDLE "$_\n"; $c++ };
    close $HANDLE or return $log->error( "couldn't close $file", %std_args );

    $log->audit( "file_write: $m $c lines to $file", %std_args );

    move( "$file.tmp", $file ) 
        or return $log->error("  unable to update $file", %std_args);

    # set file permissions mode if requested
    $self->chmod( file => $file, mode => $p{mode}, %std_args ) if $p{mode};

    return 1;
}

sub files_diff {
    my $self = shift;
    my %p = validate(
        @_,
        {   f1    => { type => SCALAR },
            f2    => { type => SCALAR },
            type  => { type => SCALAR,  optional => 1, default => 'text' },
            fatal => { type => BOOLEAN, optional => 1, default => $self->{fatal} },
            debug => { type => BOOLEAN, optional => 1, default => $self->{debug} },
        }
    );

    my ( $f1, $f2, $type, $debug ) = ( $p{f1}, $p{f2}, $p{type}, $p{debug} );
    my %std_args = ( debug => $p{debug}, fatal => $p{fatal} );

    if ( !-e $f1 || !-e $f2 ) {
        $log->error( "$f1 or $f2 does not exist!", %std_args );
        return -1;
    };

    return $self->files_diff_md5( $f1, $f2, \%std_args)
        if $type ne "text";

### TODO
    # use file here to make sure files are ASCII
    #
    $log->audit("comparing ascii files $f1 and $f2 using diff", %std_args);

    my $diff = $self->find_bin( 'diff', %std_args );
    my $r = `$diff $f1 $f2`;
    chomp $r;
    return $r;
};

sub files_diff_md5 {
    my $self = shift;
    my ($f1, $f2, $args) = @_;

    $log->audit("comparing $f1 and $f2 using md5", %$args);

    eval { require Digest::MD5 };
    return $log->error( "couldn't load Digest::MD5!", %$args )
        if $EVAL_ERROR;

    $log->audit( "\t Digest::MD5 loaded", %$args );

    my @md5sums;

    foreach my $f ( $f1, $f2 ) {
        my ( $sum, $changed );

        # if the md5 file exists
        if ( -f "$f.md5" ) {
            $sum = $self->file_read( "$f.md5", %$args );
            $log->audit( "  md5 file for $f exists", %$args );
        }

   # if the md5 file is missing, invalid, or older than the file, recompute it
        if ( ! -f "$f.md5" or $sum !~ /[0-9a-f]+/i or
            $self->file_is_newer( f1 => "$f.md5", f2 => $f, %$args )
            )
        {
            my $ctx = Digest::MD5->new;
            open my $FILE, '<', $f;
            $ctx->addfile(*$FILE);
            $sum = $ctx->hexdigest;
            close $FILE;
            $changed++;
            $log->audit("  calculated md5: $sum", %$args);
        }

        push( @md5sums, $sum );
        $self->file_write( "$f.md5", lines => [$sum], %$args ) if $changed;
    }

    return if $md5sums[0] eq $md5sums[1];
    return 1;
}

sub find_bin {
    my $self = shift;
    my $bin  = shift or die "missing argument to find_bin\n";
    my %p = validate(
        @_,
        {   'dir'   => { type => SCALAR, optional => 1, },
            'fatal' => { type => SCALAR, optional => 1, default => $self->{fatal} },
            'debug' => { type => SCALAR, optional => 1, default => $self->{fatal} },
        },
    );

    my $debug = $p{debug};
    my %std_args = ( debug => $p{debug}, fatal => $p{fatal} );

    my $prefix = "/usr/local";

    if ( $bin =~ /^\// && -x $bin ) {  # we got a full path
        $log->audit( "find_bin: found $bin", %std_args );
        return $bin;
    };

    my @prefixes;
    push @prefixes, $p{dir} if $p{dir};
    push @prefixes, qw" 
        /usr/local/bin /usr/local/sbin/ /opt/local/bin /opt/local/sbin
        $prefix/mysql/bin /bin /usr/bin /sbin /usr/sbin 
        ";
    push @prefixes, cwd;

    my $found;
    foreach my $prefix ( @prefixes ) { 
        if ( -x "$prefix/$bin" ) {
            $found = "$prefix/$bin" and last;
        };  
    };

    if ($found) {
        $log->audit( "find_bin: found $found", %std_args);
        return $found;
    }

    return $log->error( "find_bin: could not find $bin", %std_args);
}

sub fstab_list {
    my $self = shift;
    my %p = validate(
        @_,
        {   'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    if ( $OSNAME eq "darwin" ) {
        return ['fstab not used on Darwin!'];
    }

    my $fstab = "/etc/fstab";
    if ( !-e $fstab ) {
        print "fstab_list: FAILURE: $fstab does not exist!\n" if $p{debug};
        return;
    }

    my $grep = $self->find_bin( "grep", debug => 0 );
    my @fstabs = `$grep -v cdr $fstab`;

    #	foreach my $fstab (@fstabs)
    #	{}
    #		my @fields = split(" ", $fstab);
    #		#print "device: $fields[0]  mount: $fields[1]\n";
    #	{};
    #	print "\n\n END of fstabs\n\n";

    return \@fstabs;
}

sub get_cpan_config {

    my $ftp = `which ftp`; chomp $ftp;
    my $gzip = `which gzip`; chomp $gzip;
    my $unzip = `which unzip`; chomp $unzip;
    my $tar  = `which tar`; chomp $tar;
    my $make = `which make`; chomp $make;
    my $wget = `which wget`; chomp $wget;

    return 
{
  'build_cache' => q[10],
  'build_dir' => qq[$ENV{HOME}/.cpan/build],
  'cache_metadata' => q[1],
  'cpan_home' => qq[$ENV{HOME}/.cpan],
  'ftp' => $ftp,
  'ftp_proxy' => q[],
  'getcwd' => q[cwd],
  'gpg' => q[],
  'gzip' => $gzip,
  'histfile' => qq[$ENV{HOME}/.cpan/histfile],
  'histsize' => q[100],
  'http_proxy' => q[],
  'inactivity_timeout' => q[5],
  'index_expire' => q[1],
  'inhibit_startup_message' => q[1],
  'keep_source_where' => qq[$ENV{HOME}/.cpan/sources],
  'lynx' => q[],
  'make' => $make,
  'make_arg' => q[],
  'make_install_arg' => q[],
  'makepl_arg' => q[],
  'ncftp' => q[],
  'ncftpget' => q[],
  'no_proxy' => q[],
  'pager' => q[less],
  'prerequisites_policy' => q[follow],
  'scan_cache' => q[atstart],
  'shell' => q[/bin/csh],
  'tar' => $tar,
  'term_is_latin' => q[1],
  'unzip' => $unzip,
  'urllist' => [ 'http://www.perl.com/CPAN/', 'ftp://cpan.cs.utah.edu/pub/CPAN/', 'ftp://mirrors.kernel.org/pub/CPAN', 'ftp://osl.uoregon.edu/CPAN/', 'http://cpan.yahoo.com/' ],
  'wget' => $wget, 
};

}

sub get_dir_files {
    my $self = shift;
    my %p = validate(
        @_,
        {   'dir'   => { type => SCALAR,  optional => 0, },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my ( $dir, $fatal, $debug ) = ( $p{dir}, $p{fatal}, $p{debug} );
    my %std_args = ( debug => $p{debug}, fatal => $p{fatal} );

    my @files;

    return $log->error( "dir $dir is not a directory!", %std_args)
        if ! -d $dir;

    opendir D, $dir or return $log->error( "couldn't open $dir: $!", %std_args );

    while ( defined( my $f = readdir(D) ) ) {
        next if $f =~ /^\.\.?$/;
        push @files, "$dir/$f";
    }

    closedir(D);

    return @files;
}

sub get_my_ips {

    ############################################
    # Usage      : @list_of_ips_ref = $util->get_my_ips();
    # Purpose    : get a list of IP addresses on local interfaces
    # Returns    : an arrayref of IP addresses
    # Parameters : only - can be one of: first, last
    #            : exclude_locahost  (all 127.0 addresses)
    #            : exclude_internals (192.168, 10., 169., 172.)
    #            : exclude_ipv6
    # Comments   : exclude options are boolean and enabled by default.
    #              tested on Mac OS X and FreeBSD

    my $self = shift;
    my %p = validate(
        @_,
        {   'only' => { type => SCALAR, optional => 1, default => 0 },
            'exclude_localhost' =>
                { type => BOOLEAN, optional => 1, default => 1 },
            'exclude_internals' =>
                { type => BOOLEAN, optional => 1, default => 1 },
            'exclude_ipv6' =>
                { type => BOOLEAN, optional => 1, default => 1 },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my $debug = $p{debug};
    my $only  = $p{only};

    my $ifconfig = $self->find_bin( "ifconfig", debug => 0 );
    my $grep     = $self->find_bin( "grep",     debug => 0 );
    my $cut      = $self->find_bin( "cut",      debug => 0 );

    my $once = 0;

TRY:
    my $cmd = "$ifconfig | $grep inet ";

    $cmd .= "| $grep -v inet6 " if $p{exclude_ipv6};
    $cmd .= "| $cut -d' ' -f2 ";
    $cmd .= "| $grep -v '^127.0.0' " if $p{exclude_localhost};

    if ( $p{exclude_internals} ) {
        $cmd .= "| $grep -v '^192.168.' | $grep -v '^10.' "
            . "| $grep -v '^172.16.'  | $grep -v '^169.254.' ";
    }

    if ( $only eq "first" ) {
        my $head = $self->find_bin( "head", debug => 0 );
        $cmd .= "| $head -n1 ";
    }
    elsif ( $only eq "last" ) {
        my $tail = $self->find_bin( "tail", debug => 0 );
        $cmd .= "| $tail -n1 ";
    }

    my @ips = `$cmd`;
    chomp @ips;

    # this keeps us from failing if the box has only internal IPs 
    if ( @ips < 1 || $ips[0] eq "" ) {
        carp "yikes, you really don't have any public IPs?!" if $debug;
        $p{exclude_internals} = 0;
        $once++;
        goto TRY if ( $once < 2 );
    }

    return \@ips;
}

sub get_the_date {
    my $self = shift;
    my %p = validate(
        @_,
        {   'bump'  => { type => SCALAR,  optional => 1, },
            'fatal' => { type => BOOLEAN, optional => 1, default => $self->{fatal} },
            'debug' => { type => BOOLEAN, optional => 1, default => $self->{debug} },
        }
    );

    my $bump  = $p{bump} || 0;
    my %std_args = ( debug => $p{debug}, fatal => $p{fatal} );

    my $time = time;
    my $mess = "get_the_date time: " . time;

    $bump = $bump * 86400 if $bump;
    my $offset_time = time - $bump;
    $mess .= ", (selected $offset_time)" if $time != $offset_time;

    # load Date::Format to get the time2str function
    eval { require Date::Format };
    if ( !$EVAL_ERROR ) {

        my $ss = Date::Format::time2str( "%S", ($offset_time) );
        my $mn = Date::Format::time2str( "%M", ($offset_time) );
        my $hh = Date::Format::time2str( "%H", ($offset_time) );
        my $dd = Date::Format::time2str( "%d", ($offset_time) );
        my $mm = Date::Format::time2str( "%m", ($offset_time) );
        my $yy = Date::Format::time2str( "%Y", ($offset_time) );
        my $lm = Date::Format::time2str( "%m", ( $offset_time - 2592000 ) );

        $log->audit( "$mess, $yy/$mm/$dd $hh:$mn", %std_args);
        return $dd, $mm, $yy, $lm, $hh, $mn, $ss;
    }

    #  0    1    2     3     4    5     6     7     8
    # ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) =
    #                    localtime(time);
    # 4 = month + 1   ( see perldoc localtime)
    # 5 = year + 1900     ""

    my @fields = localtime($offset_time);

    my $ss = sprintf( "%02i", $fields[0] );    # seconds
    my $mn = sprintf( "%02i", $fields[1] );    # minutes
    my $hh = sprintf( "%02i", $fields[2] );    # hours (24 hour clock)

    my $dd = sprintf( "%02i", $fields[3] );        # day of month
    my $mm = sprintf( "%02i", $fields[4] + 1 );    # month
    my $yy = ( $fields[5] + 1900 );                # year

    $log->audit( "$mess, $yy/$mm/$dd $hh:$mn", %std_args );
    return $dd, $mm, $yy, undef, $hh, $mn, $ss;
}

sub get_mounted_drives {
    my $self = shift;
    my %p = validate(
        @_,
        {   'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my %std_args = ( debug => $p{debug}, fatal => $p{fatal} );

    my $mount = $self->find_bin( 'mount', %std_args );

    -x $mount or return $log->error( "I couldn't find mount!", %std_args );

    $ENV{PATH} = "";
    my %hash;
    foreach (`$mount`) {
        my ( $d, $m ) = $_ =~ /^(.*) on (.*) \(/;

        #if ( $m =~ /^\// && $d =~ /^\// )  # mount drives that begin with /
        if ( $m && $m =~ /^\// ) {   # only mounts that begin with /
            $log->audit( "adding: $m \t $d" ) if $p{debug};
            $hash{$m} = $d;
        }
    }
    return \%hash;
}

sub install_if_changed {
    my $self = shift;
    my %p = validate(
        @_,
        {   newfile => { type => SCALAR, optional => 0, },
            existing=> { type => SCALAR, optional => 0, },
            mode    => { type => SCALAR, optional => 1, },
            uid     => { type => SCALAR, optional => 1, },
            gid     => { type => SCALAR, optional => 1, },
            sudo    => { type => BOOLEAN, optional => 1, default => 0 },
            notify  => { type => BOOLEAN, optional => 1, },
            email   => { type => SCALAR, optional => 1, default => 'postmaster' },
            clean   => { type => BOOLEAN, optional => 1, default => 1 },
            archive => { type => BOOLEAN, optional => 1, default => 0 },
            fatal   => { type => BOOLEAN, optional => 1, default => $self->{fatal} },
            debug   => { type => BOOLEAN, optional => 1, default => $self->{debug} },
        },
    );

    my ( $newfile, $existing, $mode, $uid, $gid, $email) = (
        $p{newfile}, $p{existing}, $p{mode}, $p{uid}, $p{gid}, $p{email} );
    my ($debug, $sudo, $notify ) = ($p{debug}, $p{sudo}, $p{notify} );
    my %std_args = ( debug => $p{debug}, fatal => $p{fatal} );

    if ( $newfile !~ /\// ) {
        # relative filename given
        $log->audit( "relative filename given, use complete paths "
            . "for more predicatable results!\n"
            . "working directory is " . cwd() );
    }

    return $log->error( "file ($newfile) does not exist", %std_args )
        if !-e $newfile;

    return $log->error( "file ($newfile) is not a file", %std_args )
        if !-f $newfile;

    # make sure existing and new are writable
    if (   !$self->is_writable( file => $existing, fatal => 0 )
        || !$self->is_writable( file => $newfile,  fatal => 0 ) ) {

        # root does not have permission, sudo won't do any good
        return $log->error("no write permission", %std_args) if $UID == 0;

        if ( $sudo ) {
            $sudo = $self->find_bin( 'sudo', %std_args ) or
                return $log->error( "you are not root, sudo was not found, and you don't have permission to write to $newfile or $existing" );
        }
    }

    my $diffie;
    if ( -f $existing ) {
        $diffie = $self->files_diff( %std_args,
            f1    => $newfile,
            f2    => $existing,
            type  => "text",
        ) or do {
            $log->audit( "$existing is already up-to-date.", %std_args);
            unlink $newfile if $p{clean};
            return 2;
        };
    };

    $log->audit("checking $existing", %std_args);

    $self->chown( 
        file_or_dir => $newfile,
        uid => $uid,
        gid => $gid,
        sudo => $sudo,
        %std_args
    ) 
    if ( $uid && $gid );  # set file ownership on the new file

    # set file permissions on the new file
    $self->chmod(
        file_or_dir => $existing,
        mode        => $mode,
        sudo        => $sudo,
        %std_args
    )
    if ( -e $existing && $mode );

    $self->install_if_changed_notify( $notify, $email, $existing, $diffie);
    $self->file_archive( $existing, %std_args) if ( -e $existing && $p{archive} );
    $self->install_if_changed_copy( $sudo, $newfile, $existing, $p{clean}, \%std_args );

    $self->chown(
        file_or_dir => $existing,
        uid         => $uid,
        gid         => $gid,
        sudo        => $sudo,
        %std_args
    ) if ( $uid && $gid ); # set ownership on new existing file

    $self->chmod(
        file_or_dir => $existing,
        mode        => $mode,
        sudo        => $sudo,
        %std_args
    )
    if $mode; # set file permissions (paranoid)

    $log->audit( "  updated $existing" );
    return 1;
}

sub install_if_changed_copy {
    my $self = shift;
    my ( $sudo, $newfile, $existing, $clean, $args ) = @_;

    # install the new file
    if ($sudo) {
        my $cp = $self->find_bin( 'cp', %$args );

        # back up the existing file
        $self->syscmd( "$sudo $cp $existing $existing.bak", %$args)
            if -e $existing;

        # install the new one
        if ( $clean ) {
            my $mv = $self->find_bin( 'mv' );
            $self->syscmd( "$sudo $mv $newfile $existing", %$args);
        }
        else {
            $self->syscmd( "$sudo $cp $newfile $existing",%$args);
        }
    }
    else {

        # back up the existing file
        copy( $existing, "$existing.bak" ) if -e $existing;

        if ( $clean ) {
            move( $newfile, $existing ) or
                return $log->error( "failed copy $newfile to $existing", %$args);
        }
        else {
            copy( $newfile, $existing ) or
                return $log->error( "failed copy $newfile to $existing", %$args );
        }
    }
};

sub install_if_changed_notify {

    my ($self, $notify, $email, $existing, $diffie) = @_;

    return if ! $notify;
    return if ! -f $existing;

    # email diffs to admin

    eval { require Mail::Send; };

    return $log->error( "could not send notice, Mail::Send is not installed!", fatal => 0)
        if $EVAL_ERROR;

    my $msg = Mail::Send->new;
    $msg->subject("$existing updated by $0");
    $msg->to($email);
    my $email_message = $msg->open;

    print $email_message "This message is to notify you that $existing has been altered. The difference between the new file and the old one is:\n\n$diffie";

    $email_message->close;
};

sub install_from_source {
    my $self = shift;
    my %p = validate(
        @_,
        {   'site'           => { type => SCALAR,   optional => 0, },
            'url'            => { type => SCALAR,   optional => 0, },
            'package'        => { type => SCALAR,   optional => 0, },
            'targets'        => { type => ARRAYREF, optional => 1, },
            'patches'        => { type => ARRAYREF, optional => 1, },
            'patch_url'      => { type => SCALAR,   optional => 1, },
            'patch_args'     => { type => SCALAR,   optional => 1, },
            'source_dir'     => { type => SCALAR,   optional => 1, },
            'source_sub_dir' => { type => SCALAR,   optional => 1, },
            'bintest'        => { type => SCALAR,   optional => 1, },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug'   => { type => BOOLEAN, optional => 1, default => 1 },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    return $p{test_ok} if defined $p{test_ok};

    my ( $site, $url, $package, $targets, $patches, $debug, $bintest ) =
        ( $p{site},    $p{url}, $p{package},
          $p{targets}, $p{patches}, $p{debug}, $p{bintest} );

    my $patch_args = $p{patch_args} || '';
    my $src = $p{source_dir} || "/usr/local/src";
       $src .= "/$p{source_sub_dir}" if $p{source_sub_dir};

    my %std_args = ( debug => $p{debug}, fatal => $p{fatal} );

    my $original_directory = cwd;

    $self->cwd_source_dir( dir => $src, debug => $debug );

    if ( $bintest && $self->find_bin( $bintest, fatal => 0, debug => 0 ) ) {
        return if ! $self->yes_or_no(
            "$bintest exists, suggesting that"
                . "$package is installed. Do you want to reinstall?",
            timeout  => 60,
        );
    }

    $log->audit( "install_from_source: building $package in $src");

    $self->install_from_source_cleanup($package,$src) or return;
    $self->install_from_source_get_files($package,$site,$url,$p{patch_url},$patches) or return;

    $self->archive_expand( archive => $package, debug => $debug )
        or return $log->error( "Couldn't expand $package: $!", %std_args );

    # cd into the package directory
    my $sub_path;
    if ( -d $package ) {
        chdir $package or 
            return $log->error( "FAILED to chdir $package!", %std_args ); 
    }
    else {

       # some packages (like daemontools) unpack within an enclosing directory
        $sub_path = `find ./ -name $package`;       # tainted data
        chomp $sub_path;
        ($sub_path) = $sub_path =~ /^([-\w\/.]+)$/; # untaint it

        $log->audit( "found sources in $sub_path" ) if $sub_path;
        return $log->error( "FAILED to find $package sources!",fatal=>0)
            unless ( -d $sub_path && chdir($sub_path) );
    }

    $self->install_from_source_apply_patches($src, $patches, $patch_args) or return;

    # set default build targets if none are provided
    if ( !@$targets[0] ) {
        $log->audit( "\tusing default targets (./configure, make, make install)" );
        @$targets = ( "./configure", "make", "make install" );
    }

    my $msg = "install_from_source: using targets\n";
    foreach (@$targets) { $msg .= "\t$_\n" };
    $log->audit( $msg ) if $debug;

    # build the program
    foreach my $target (@$targets) {

        if ( $target =~ /^cd (.*)$/ ) {
            $log->audit( "cwd: " . cwd . " -> " . $1 );
            chdir($1) or return $log->error( "couldn't chdir $1: $!", %std_args);
            next;
        }

        $self->syscmd( $target, debug => $debug ) or
            return $log->error( "pwd: " . cwd .  "\n$target failed: $!", %std_args );
    }

    # clean up the build sources
    chdir $src;
    $self->syscmd( "rm -rf $package", debug => $debug ) if -d $package;

    $self->syscmd( "rm -rf $package/$sub_path", %std_args )
        if defined $sub_path && -d "$package/$sub_path";

    chdir $original_directory;
    return 1;
}

sub install_from_source_apply_patches {
    my $self = shift;
    my ($src, $patches,$patch_args) = @_;

    return 1 if ! $patches;
    return 1 if ! $patches->[0];

    my $patchbin = $self->find_bin( "patch" );
    foreach my $patch (@$patches) {
        $self->syscmd( "$patchbin $patch_args < $src/$patch" )
            or return $log->error("failed to apply patch $patch");
    }
    return 1;
};

sub install_from_source_cleanup {
    my $self = shift;
    my ($package,$src) = @_;

    # make sure there are no previous sources in the way
    return 1 if ! -d $package;

    $self->source_warning(
        package => $package,
        clean   => 1,
        src     => $src,
    ) or return $log->error( "OK then, skipping install.", fatal => 0);

    print "install_from_source: removing previous build sources.\n";
    return $self->syscmd( "rm -rf $package-*" );
};

sub install_from_source_get_files {
    my $self = shift;
    my ($package,$site,$url,$patch_url,$patches) = @_;

    #print "install_from_source: looking for existing sources...";
    $self->sources_get( 
        package => $package,
        site    => $site,
        path    => $url,
    ) or return;

    if ( ! $patches || ! $patches->[0] ) {
        $log->audit( "install_from_source: no patches to fetch." );
        return 1;
    };  

    return $log->error( "oops! You supplied patch names to apply without a URL!")
        if ! $patch_url;


    foreach my $patch (@$patches) {
        next if ! $patch;
        next if -e $patch;

        $log->audit( "install_from_source: fetching patch from $url");
        my $url = "$patch_url/$patch";
        $self->file_get( url => $url ) 
            or return $log->error( "could not fetch $url" );
    };

    return 1;
};

sub install_package {
    my ($self, $app, $info) = @_;

    if ( lc($OSNAME) eq 'freebsd' ) {

        my $portname = $info->{port}
            or return $log->error( "skipping install of $app b/c port dir not set.", fatal => 0);

        if (`/usr/sbin/pkg_info | /usr/bin/grep $app`) {
            print "$app is installed.\n";
            return 1;
        }

        print "installing $app\n";
        my $portdir = </usr/ports/*/$portname>;

        if ( ! -d $portdir || ! chdir $portdir ) {
            print "oops, couldn't find port $app at '$portname'\n";
            return;
        }

        system "make install clean"
            and return $log->error( "'make install clean' failed for port $app", fatal => 0);
        return 1;
    };

    if ( lc($OSNAME) eq 'linux' ) {
        my $rpm = $info->{rpm} or return $log->error("skipping install of $app b/c rpm not set", fatal => 0);
        my $yum = '/usr/bin/yum';
        return $log->error( "couldn't find yum, skipping install.", fatal => 0)
            if ! -x $yum;
        return system "$yum install $rpm";
    };
}

sub install_module {
    my ($self, $module, %info) = @_;

    eval "use $module";
    if ( ! $EVAL_ERROR ) {
        $log->audit( "$module is already installed." );
        return 1;
    };

    if ( lc($OSNAME) eq 'darwin' ) {
        my $dport = '/opt/local/bin/port';
        return $log->error( "Darwin ports is not installed!", fatal => 0)
            if ! -x $dport;

        my $port = "p5-$module";
        $port =~ s/::/-/g;
        system "sudo $dport install $port";
    }

    if ( lc($OSNAME) eq 'freebsd' ) {

        my $portname = $info{port}; # optional override
        if ( ! $portname ) {
            $portname = "p5-$module";
            $portname =~ s/::/-/g;
        };

        if (`/usr/sbin/pkg_info | /usr/bin/grep $portname`) {
            print "$module is installed.\n";
            return 1;
        }

        print "installing $module";

        my $portdir = </usr/ports/*/$portname>;

        if ( $portdir && -d $portdir && chdir $portdir ) {
            print " from ports ($portdir)\n";
            system "make clean && make install clean";
        }
    }

    if ( lc($OSNAME) eq 'linux' ) {

        my $rpm = $info{rpm};
        if ( $rpm ) {
            my $portname = "perl-$rpm";
            $portname =~ s/::/-/g;
            my $yum = '/usr/bin/yum';
            system "$yum -y install $portname" if -x $yum;
        }
    };

    print " from CPAN...";
    require CPAN;

    # some Linux distros break CPAN by auto/preconfiguring it with no URL mirrors.
    # this works around that annoying little habit
    no warnings;
    $CPAN::Config = $self->get_cpan_config();
    use warnings;

    CPAN::Shell->install($module);

    eval "use $module";
    if ( ! $EVAL_ERROR ) {
        $log->audit( "$module is installed." );
        return 1;
    };
}

sub install_module_from_src {
    my $self = shift;
    my %p = validate( @_, {
            module  => { type=>SCALAR,  optional=>0, },
            archive => { type=>SCALAR,  optional=>0, },
            site    => { type=>SCALAR,  optional=>0, },
            url     => { type=>SCALAR,  optional=>0, },
            src     => { type=>SCALAR,  optional=>1, default=>'/usr/local/src' },
            targets => { type=>ARRAYREF,optional=>1, },
            fatal   => { type=>BOOLEAN, optional=>1, default=>1 },
            debug   => { type=>BOOLEAN, optional=>1, default=>1 },
        },
    );

    my ( $module, $site, $url, $src, $targets, $debug )
        = ( $p{module}, $p{site}, $p{url}, $p{src}, $p{targets}, $p{debug} );
    my %std_args = ( debug => $p{debug}, fatal => $p{fatal} );

    $self->cwd_source_dir( dir => $src, %std_args );

    $log->audit( "checking for previous build attempts.");
    if ( -d $module ) {
        if ( ! $self->source_warning( package=>$module, src=>$src, %std_args ) ) {
            carp "\nokay, skipping install.\n";
            return;
        }
        $self->syscmd( cmd => "rm -rf $module", %std_args );
    }

    $self->sources_get(
        site    => $site,
        path    => $url,
        package => $p{'archive'} || $module,
        %std_args,
    ) or return;

    $self->archive_expand( archive => $module, %std_args) or return;

    my $found;
    print "looking for $module in $src...";
    foreach my $file ( $self->get_dir_files( dir => $src ) ) {

        next if ! -d $file;  # only check directories
        next if $file !~ /$module/;

        print "found: $file\n";
        $found++;
        chdir $file;

        unless ( @$targets[0] && @$targets[0] ne "" ) {
            $log->audit( "using default targets." );
            $targets = [ "perl Makefile.PL", "make", "make install" ];
        }

        print "building with targets " . join( ", ", @$targets ) . "\n";
        foreach (@$targets) {
            return $log->error( "$_ failed!", %std_args)
                if ! $self->syscmd( cmd => $_ , %std_args);
        }

        chdir('..');
        $self->syscmd( cmd => "rm -rf $file", debug=>0);
        last;
    }

    return $found;
}

sub is_interactive {

    ## no critic
    # borrowed from IO::Interactive
    my $self = shift;
    my ($out_handle) = ( @_, select );    # Default to default output handle

    # Not interactive if output is not to terminal...
    return if not -t $out_handle;

    # If *ARGV is opened, we're interactive if...
    if ( openhandle * ARGV ) {

        # ...it's currently opened to the magic '-' file
        return -t *STDIN if defined $ARGV && $ARGV eq '-';

        # ...it's at end-of-file and the next file is the magic '-' file
        return @ARGV > 0 && $ARGV[0] eq '-' && -t *STDIN if eof *ARGV;

        # ...it's directly attached to the terminal
        return -t *ARGV;
    }

   # If *ARGV isn't opened, it will be interactive if *STDIN is attached
   # to a terminal and either there are no files specified on the command line
   # or if there are files and the first is the magic '-' file
    else {
        return -t *STDIN && ( @ARGV == 0 || $ARGV[0] eq '-' );
    }
}

sub is_process_running {
    my ( $self, $process ) = @_;

    eval "require Proc::ProcessTable";
    if ( ! $EVAL_ERROR ) {
        my $i = 0;
        my $t = Proc::ProcessTable->new();
        if ( scalar @{ $t->table } ) {
            foreach my $p ( @{ $t->table } ) {
                $i++ if ( $p->cmndline =~ m/$process/i );
            };
            return $i;
        };
    };

    my $ps   = $self->find_bin( 'ps',   debug => 0 );
    my $grep = $self->find_bin( 'grep', debug => 0 );

    if    ( lc($OSNAME) =~ /solaris/i ) { $ps .= ' -ef';  }
    elsif ( lc($OSNAME) =~ /irix/i    ) { $ps .= ' -ef';  }
    elsif ( lc($OSNAME) =~ /linux/i   ) { $ps .= ' -efw'; }
    else                                { $ps .= ' axw';  };

    my $is_running = `$ps | $grep $process | $grep -v grep` ? 1 : 0;
    #warn "$ps | $grep $process | $grep -v grep\n" if ! $is_running;
    return $is_running;
}

sub is_readable {
    my $self = shift;
    my %p = validate(
        @_,
        {   'file'  => { type => SCALAR },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my ( $file, $fatal, $debug ) = ( $p{file}, $p{fatal}, $p{debug} );
    my %std_args = ( debug => $p{debug}, fatal => $p{fatal} );

    -e $file or return $log->error( "file $file does not exist.", %std_args);
    -r $file or return $log->error( "file $file is not readable by you ("
            . getpwuid($>)
            . "). You need to fix this, using chown or chmod.", %std_args);

    return 1;
}

sub is_writable {
    my $self = shift;
    my %p = validate(
        @_,
        {   'file'  => SCALAR,
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my ( $file, $fatal, $debug ) = ( $p{file}, $p{fatal}, $p{debug} );

    my $nl = "\n";
    $nl = "<br>" if ( $ENV{GATEWAY_INTERFACE} );

    if ( !-e $file ) {

        use File::Basename;
        my ( $base, $path, $suffix ) = fileparse($file);

        return $log->error( "is_writable: $path not writable by "
            . getpwuid($>)
            . "!$nl$nl") if (-e $path && !-w $path);
        return 1;
    }

    # if we get this far, the file exists
    return $log->error( "is_writable: $file is not a file!" ) if ! -f $file;

    return $log->error( "  $file not writable by " . getpwuid($>)
        . "$nl$nl",fatal=>$fatal ) if ! -w $file;

    $log->audit( "$file is writable" ) if $debug;
    return 1;
}

sub logfile_append {
    my $self = shift;
    my %p = validate(
        @_,
        {   'file'  => { type => SCALAR,   optional => 0, },
            'lines' => { type => ARRAYREF, optional => 0, },
            'prog'  => { type => BOOLEAN,  optional => 1, default => 0, },
            'fatal' => { type => BOOLEAN,  optional => 1, default => $self->{debug} },
            'debug' => { type => BOOLEAN,  optional => 1, default => $self->{debug} },
        },
    );

    my ( $file, $lines ) = ( $p{file}, $p{lines} );
    my %std_args = ( debug => $p{debug}, fatal => $p{fatal} );

    my ( $dd, $mm, $yy, $lm, $hh, $mn, $ss ) = $self->get_the_date( %std_args );

    open my $LOG_FILE, '>>', $file 
        or return $log->error( "couldn't open $file: $OS_ERROR", %std_args);

    print $LOG_FILE "$yy-$mm-$dd $hh:$mn:$ss $p{prog} ";

    my $i;
    foreach (@$lines) { print $LOG_FILE "$_ "; $i++ }

    print $LOG_FILE "\n";
    close $LOG_FILE;

    $log->audit( "logfile_append wrote $i lines to $file", %std_args );
    return 1;
}

sub mail_toaster {
    my ( $self, $debug ) = @_;
    my ( $conf, $ver );

    my $perlbin = $self->find_bin( "perl", debug => 0 );

    if ( -e "/usr/local/etc/toaster-watcher.conf" ) {

        $conf = $self->parse_config(
            file   => "toaster-watcher.conf",
            etcdir => "/usr/local/etc",
            debug  => 0,
        );
    }

    $self->install_module( 'Mail::Toaster' );
}

sub mkdir_system {
    my $self = shift;
    my %p = validate(
        @_,
        {   'dir'   => { type => SCALAR,  optional => 0, },
            'mode'  => { type => SCALAR,  optional => 1, },
            'sudo'  => { type => BOOLEAN, optional => 1, default => 0 },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my ( $dir, $mode, $debug ) = ( $p{dir}, $p{mode}, $p{debug} );
    my %std_args = ( debug => $p{debug}, fatal => $p{fatal} );

    if ( -d $dir ) {
        print "mkdir_system: $dir already exists.\n" if $debug;
        return 1;
    }

    # can't do anything without mkdir
    my $mkdir = $self->find_bin( 'mkdir', %std_args);

    # if we are root, just do it (no sudo nonsense)
    if ( $< == 0 ) {
        $self->syscmd( "$mkdir -p $dir", %std_args);

        $self->chmod( dir => $dir, mode => $mode, debug => $debug ) if $mode;

        return 1 if -d $dir;
        return $log->error( "failed to create $dir", %std_args);
    }

    if ( $p{sudo} ) {

        my $sudo = $self->sudo();

        $log->audit( "trying $sudo mkdir -p") if $debug;
        $mkdir = $self->find_bin( 'mkdir', %std_args);
        $self->syscmd( "$sudo $mkdir -p $dir", %std_args);

        $log->audit( "setting ownership to $<.") if $debug;
        my $chown = $self->find_bin( 'chown', %std_args);
        $self->syscmd( "$sudo $chown $< $dir", %std_args);

        $self->chmod( dir => $dir, mode => $mode, sudo => $sudo, %std_args)
             if $mode;

        return -d $dir ? 1 : 0;
    }

    $log->audit( "trying mkdir -p $dir" ) if $debug;

    # no root and no sudo, just try and see what happens
    $self->syscmd( "$mkdir -p $dir", %std_args );

    $self->chmod( dir => $dir, mode => $mode, %std_args) if $mode;

    return $log->audit( "mkdir_system created $dir" ) if -d $dir;
    return $log->error( '', %std_args );
}

sub path_parse {

    # code left here for reference, use File::Basename instead
    my ( $self, $dir ) = @_;

    # if it ends with a /, chop if off
    if ( $dir =~ q{/$} ) { chop $dir }

    # get the position of the last / in the path
    my $rindex = rindex( $dir, "/" );

    # grabs everything up to the last /
    my $updir = substr( $dir, 0, $rindex );
    $rindex++;

    # matches from the last / char +1 to the end of string
    my $curdir = substr( $dir, $rindex );

    return $updir, $curdir;
}

sub pidfile_check {
    my $self = shift;
    my %p = validate(
        @_,
        {   'pidfile' => { type => SCALAR },
            'fatal'   => { type => BOOLEAN, optional => 1, default => 1 },
            'debug'   => { type => BOOLEAN, optional => 1, default => 1 },
        },
    );

    my ( $pidfile, $debug ) = ( $p{pidfile}, $p{debug} );
    my %std_args = ( debug => $p{debug}, fatal => $p{fatal} );

    return $log->error( "$pidfile is not a regular file", %std_args)
        if -e $pidfile && !-f $pidfile;

    # test if file & enclosing directory is writable, revert to /tmp if not
    $self->is_writable( file  => $pidfile, %std_args) 
        or do {
            use File::Basename;
            my ( $base, $path, $suffix ) = fileparse($pidfile);
            $log->audit( "NOTICE: using /tmp for pidfile, $path is not writable!")
                if $debug;
            $pidfile = "/tmp/$base";
        };

    # if it does not exist
    if ( !-e $pidfile ) {
        $log->audit( "writing process id $PROCESS_ID to $pidfile...") if $debug;
        $self->file_write( $pidfile, lines => [$PROCESS_ID], %std_args)
            and do {
                print "done.\n" if $debug;
                return $pidfile;
            };
    };

    my $age = time() - stat($pidfile)->mtime;

    if ( $age < 1200 ) {    # less than 20 minutes old
        carp "\nWARNING! pidfile_check: $pidfile is "
            . $age / 60
            . " minutes old and might still be running. If it is not running,"
            . " please remove the pidfile (rm $pidfile). \n"
            if $debug;
        return;
    }
    elsif ( $age < 3600 ) {    # 1 hour
        carp "\nWARNING! pidfile_check: $pidfile is "
            . $age / 60
            . " minutes old and might still be running. If it is not running,"
            . " please remove the pidfile. (rm $pidfile)\n";    #if $debug;

        return;
    }
    else {
        print
            "\nWARNING: pidfile_check: $pidfile is $age seconds old, ignoring.\n\n"
            if $debug;
    }

    return $pidfile;
}

sub provision_unix {
    my ( $self, $debug ) = @_;
    my ( $conf, $ver );

    my $perlbin = $self->find_bin( "perl", debug => 0 );

    if ( -e "/usr/local/etc/provision.conf" ) {

        $conf = $self->parse_config(
            file   => "provision.conf",
            etcdir => "/usr/local/etc",
            debug  => 0,
        );
    }

    $self->install_module( 'Provision::Unix' );
}

sub regexp_test {
    my $self = shift;
    my %p = validate(
        @_,
        {   'exp'    => { type => SCALAR },
            'string' => { type => SCALAR },
            'pbp'    => { type => BOOLEAN, optional => 1, default => 0 },
            'debug'  => { type => BOOLEAN, optional => 1, default => 1 },
        },
    );

    my ( $exp, $string, $pbp, $debug )
        = ( $p{exp}, $p{string}, $p{pbp}, $p{debug} );

    if ($pbp) {
        if ( $string =~ m{($exp)}xms ) {
            print "\t Matched pbp: |$`<$&>$'|\n" if $debug;
            return $1;
        }
        else {
            print "\t No match.\n" if $debug;
            return;
        }
    }

    if ( $string =~ m{($exp)} ) {
        print "\t Matched: |$`<$&>$'|\n" if $debug;
        return $1;
    }

    print "\t No match.\n" if $debug;
    return;
}

sub sources_get {
    my $self = shift;
    my %p = validate(
        @_,
        {   'package' => { type => SCALAR,  optional => 0 },
            site      => { type => SCALAR,  optional => 0 },
            path      => { type => SCALAR,  optional => 1 },
            debug     => { type => BOOLEAN, optional => 1, default => 1 },
            fatal     => { type => BOOLEAN, optional => 1, default => 1 },
        },
    );

    my ( $package, $site, $path, $debug )
        = ( $p{package}, $p{site}, $p{path}, $p{debug} );

    my %std_args = ( debug => $p{debug}, fatal => $p{fatal} );

    print "sources_get: fetching $package from site $site\n\t path: $path\n" if $debug;

    my @extensions = qw/ tar.gz tgz tar.bz2 tbz2 /;

    my $filet = $self->find_bin( 'file', %std_args);
    my $grep  = $self->find_bin( 'grep', %std_args);

    foreach my $ext (@extensions) {

        my $tarball = "$package.$ext";
        next if !-e $tarball;
        $log->audit( " found $tarball!") if -e $tarball;

        if (`$filet $tarball | $grep compress`) {
            $self->yes_or_no( "$tarball exists, shall I use it?: ")
                and do {
                    print "\n\t ok, using existing archive: $tarball\n";
                    return 1;
                }
        }

        $self->file_delete( file => $tarball, %std_args );
    }

    foreach my $ext (@extensions) {
        my $tarball = "$package.$ext";

        print "sources_get: fetching $site$path/$tarball...";

        $self->file_get(
            url   => "$site$path/$tarball",
            debug => 0,
            fatal => 0
        ) or carp "sources_get: couldn't fetch $site$path/$tarball";

        next if ! -e $tarball;

        print "sources_get: testing $tarball ...";

        if (`$filet $tarball | $grep zip`) {
            print "sources_get: looks good!\n";
            return 1;
        };

        print "YUCK, is not [b|g]zipped data!\n";
        $self->file_delete( file => $tarball, %std_args);
    }

    print "sources_get: FAILED, I am giving up!\n";
    return;
}

sub source_warning {
    my $self = shift;
    my %p = validate(
        @_,
        {   'package' => { type => SCALAR, },
            'clean'   => { type => BOOLEAN, optional => 1, default => 1 },
            'src' => {
                type     => SCALAR,
                optional => 1,
                default  => "/usr/local/src"
            },
            'timeout' => { type => SCALAR,  optional => 1, default => 60 },
            'fatal'   => { type => BOOLEAN, optional => 1, default => 1 },
            'debug'   => { type => BOOLEAN, optional => 1, default => 1 },
        },
    );

    my ( $package, $src ) = ( $p{package}, $p{src} );
    my %std_args = ( debug => $p{debug}, fatal => $p{fatal} );

    if ( !-d $package ) {
        $log->audit( "source_warning: $package sources not present." );
        return 1;
    }

    if ( -e $package ) {
        print "
	$package sources are already present, indicating that you've already
	installed $package. If you want to reinstall it, remove the existing
	sources (rm -r $src/$package) and re-run this script\n\n";
        return if !$p{clean};
    }

    if ( !$self->yes_or_no( "\n\tMay I remove the sources for you?",
        timeout  => $p{timeout},
    ) ) {
        carp "\nOK then, skipping $package install.\n\n";
        return;
    };

    print "wd: " . cwd . "\n";
    print "Deleting $src/$package...";

    return $log->error( "FAILED to delete $package: $OS_ERROR", %std_args )
        if !rmtree "$src/$package";
    print "done.\n";
    return 1;
}

sub sudo {
    my $self = shift;
    my %p = validate(
        @_,
        {   'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
        },
    );

    my $debug = $p{debug};
    my %std_args = ( debug => $p{debug}, fatal => $p{fatal} );

    # if we are running as root via $<
    if ( $REAL_USER_ID == 0 ) {
        print "sudo: you are root, sudo isn't necessary.\n" if $debug;
        return '';    # return an empty string, purposefully
    }

    my $sudo;
    my $path_to_sudo = $self->find_bin( 'sudo', debug => $debug, fatal => 0 );

    # sudo is installed
    if ( $path_to_sudo && -x $path_to_sudo ) {
        print "sudo: sudo is set using $path_to_sudo.\n" if $debug;
        return "$path_to_sudo -p 'Password for %u@%h:'";
    }

    print
        "\n\n\tWARNING: Couldn't find sudo. This may not be a problem but some features require root permissions and will not work without them. Having sudo can allow legitimate and limited root permission to non-root users. Some features of Mail::Toaster may not work as expected without it.\n\n";

    # try installing sudo
    $self->yes_or_no( "may I try to install sudo?", timeout => 20 ) or do {
        print "very well then, skipping along.\n";
        return "";
    };

    -x $self->find_bin( "sudo", debug => $debug, fatal => 0 ) or
        $self->install_from_source(
            package => 'sudo-1.6.9p17',
            site    => 'http://www.courtesan.com',
            url     => '/sudo/',
            targets => [ './configure', 'make', 'make install' ],
            patches => '',
            debug   => 1,
        );

    # can we find it now?
    $path_to_sudo = $self->find_bin( "sudo", %std_args);

    if ( !-x $path_to_sudo ) {
        carp "sudo install failed!";
        return '';
    }

    return "$path_to_sudo -p 'Password for %u@%h:'";
}

sub syscmd {
    my $self = shift;
    my $cmd = shift or die "missing command!\n";
    my %p = validate(
        @_,
        {   'timeout' => { type => SCALAR,  optional => 1 },
            'fatal'   => { type => BOOLEAN, optional => 1, default => 1 },
            'debug'   => { type => BOOLEAN, optional => 1, default => 1 },
        },
    );

    my $debug    = $p{debug};
    my %std_args = ( debug => $p{debug}, fatal => $p{fatal} );

    $log->audit("syscmd: $cmd") if $debug;

    my ( $is_safe, $tainted, $bin, @args );

    # separate the program from its arguments
    if ( $cmd =~ m/\s+/xm ) {
        ($cmd) = $cmd =~ /^\s*(.*?)\s*$/; # trim lead/trailing whitespace
        @args = split /\s+/, $cmd;  # split on whitespace
        $bin = shift @args;
        $is_safe++;
        $log->audit("\tprogram: $bin, args : " . join ' ', @args) if $debug;
    }
    else {
        # does not not contain a ./ pattern
        if ( $cmd !~ m{\./} ) { $bin = $cmd; $is_safe++; };
    }

    if ( $is_safe && !$bin ) {
        return $log->error("command is not safe! BAILING OUT!", %std_args);
    }

    my $message;
    $message .= "syscmd: bin is <$bin>" if $bin;
    $message .= " (safe)" if $is_safe;
    $log->audit($message) if $debug;

    if ( $bin && !-e $bin ) {  # $bin is set, but we have not found it
        $bin = $self->find_bin( $bin, fatal => 0, debug => 0 )
            or return $log->error( "$bin was not found", %std_args);
    }
    unshift @args, $bin;

    require Scalar::Util;
    $tainted++ if Scalar::Util::tainted($cmd);

    my $before_path = $ENV{PATH};

    # instead of croaking, maybe try setting a
    # very restrictive PATH?  I'll err on the side of safety 
    # $ENV{PATH} = '';
    return $log->error( "syscmd request has tainted data", %std_args)
        if ( $tainted && !$is_safe );

    if ($is_safe) {
        my $prefix = "/usr/local";   # restrict the path
        $prefix = "/opt/local" if -d "/opt/local";
        $ENV{PATH} = "/bin:/sbin:/usr/bin:/usr/sbin:$prefix/bin:$prefix/sbin";
    }

    my $r;
    eval {
        if ( defined $p{timeout} ) {
            local $SIG{ALRM} = sub { die "alarm\n" };
            alarm $p{timeout};
        };
        #$r = system $cmd;
        $r = `$cmd 2>&1`;
        alarm 0 if defined $p{timeout};
    };

    if ($EVAL_ERROR) {
        if ( $EVAL_ERROR eq "alarm\n" ) {
            $log->audit("timed out");
        }
        else {
            return $log->error( "unknown error '$EVAL_ERROR'", %std_args);
        }
    }
    $ENV{PATH} = $before_path;   # set PATH back to original value

    my @caller = caller;
    return $self->syscmd_exit_code( $r, $CHILD_ERROR, \@caller, \%std_args  );
}

sub syscmd_exit_code {
    my $self = shift;
    my ($r, $err, $caller, $args) = @_;

    $log->audit( "r: $r" );

    my $exit_code = sprintf ("%d", $err >> 8);
    return 1 if $exit_code == 0; # success

    #print 'error # ' . $ERRNO . "\n";   # $! == $ERRNO
    $log->error( "$err: $r",fatal=>0);

    if ( $err == -1 ) {     # check $? for "normal" errors
        $log->error( "failed to execute: $ERRNO", fatal=>0);
    }
    elsif ( $err & 127 ) {  # check for core dump
        printf "child died with signal %d, %s coredump\n", ( $? & 127 ),
            ( $? & 128 ) ? 'with' : 'without';
    }

    return $log->error( "$err: $r", location => join( ", ", @$caller ), %$args );
};

sub yes_or_no {
    my $self = shift;
    my $question = shift;
    my %p = validate(
        @_,
        {   'timeout'  => { type => SCALAR,  optional => 1 },
            'debug'    => { type => BOOLEAN, optional => 1, default => 1 },
            'force'    => { type => BOOLEAN, optional => 1, default => 0 },
        },
    );


    # for 'make test' testing
    return 1 if $question eq "test";

    # force if interactivity testing is not working properly.
    if ( !$p{force} && !$self->is_interactive ) {
        carp "not running interactively, can't prompt!";
        return;
    }

    my $response;

    print "\nYou have $p{timeout} seconds to respond.\n" if $p{timeout};
    print "\n\t\t$question";

    # I wish I knew why this is not working correctly
    #	eval { local $SIG{__DIE__}; require Term::ReadKey };
    #	if ($@) { #
    #		require Term::ReadKey;
    #		Term::ReadKey->import();
    #		print "yay, Term::ReadKey is present! Are you pleased? (y/n):\n";
    #		use Term::Readkey;
    #		ReadMode 4;
    #		while ( not defined ($key = ReadKey(-1)))
    #		{ # no key yet }
    #		print "Got key $key\n";
    #		ReadMode 0;
    #	};

    if ( $p{timeout} ) {
        eval {
            local $SIG{ALRM} = sub { die "alarm\n" };
            alarm $p{timeout};
            do {
                print "(y/n): ";
                $response = lc(<STDIN>);
                chomp($response);
            } until ( $response eq "n" || $response eq "y" );
            alarm 0;
        };

        if ($@) {
            $@ eq "alarm\n" ? print "timed out!\n" : carp;
        }

        return ($response && $response eq "y") ? 1 : 0;
    }

    do {
        print "(y/n): ";
        $response = lc(<STDIN>);
        chomp($response);
    } until ( $response eq "n" || $response eq "y" );

    return ($response eq "y") ? 1 : 0;
}

1;
__END__


=head1 NAME

Mail::Toaster::Utility - utility subroutines for sysadmin tasks


=head1 SYNOPSIS

  use Mail::Toaster::Utility;
  my $util = Mail::Toaster::Utility->new;

  $util->file_write($file, lines=> @lines);

This is just one of the many handy little methods I have amassed here. Rather than try to remember all of the best ways to code certain functions and then attempt to remember them, I have consolidated years of experience and countless references from Learning Perl, Programming Perl, Perl Best Practices, and many other sources into these subroutines.


=head1 DESCRIPTION

This Mail::Toaster::Utility package is my most frequently used one. Each method has its own documentation but in general, all methods accept as input a hashref with at least one required argument and a number of optional arguments. 


=head1 DIAGNOSTICS

All methods set and return error codes (0 = fail, 1 = success) unless otherwise stated. 

Unless otherwise mentioned, all methods accept two additional parameters:

  debug - to print status and verbose error messages, set debug=>1.
  fatal - die on errors. This is the default, set fatal=>0 to override.


=head1 DEPENDENCIES

  Perl.
  Scalar::Util -  built-in as of perl 5.8

Almost nothing else. A few of the methods do require certian things, like archive_expand requires tar and file. But in general, this package (Mail::Toaster::Utility) should run flawlessly on any UNIX-like system. Because I recycle this package in other places (not just Mail::Toaster), I avoid creating dependencies here.

=head1 METHODS

=over


=item new

To use any of the methods below, you must first create a utility object. The methods can be accessed via the utility object.

  ############################################
  # Usage      : use Mail::Toaster::Utility;
  #            : my $util = Mail::Toaster::Utility->new;
  # Purpose    : create a new Mail::Toaster::Utility object
  # Returns    : a bona fide object
  # Parameters : none
  ############################################


=item ask


Get a response from the user. If the user responds, their response is returned. If not, then the default response is returned. If no default was supplied, 0 is returned.

  ############################################
  # Usage      :  my $ask = $util->ask( "Would you like fries with that",
  #  		           default  => "SuperSized!",
  #  		           timeout  => 30  
  #               );
  # Purpose    : prompt the user for information
  #
  # Returns    : S - the users response (if not empty) or
  #            : S - the default ask or
  #            : S - an empty string
  #
  # Parameters
  #   Required : S - question - what to ask
  #   Optional : S - default  - a default answer
  #            : I - timeout  - how long to wait for a response
  # Throws     : no exceptions
  # See Also   : yes_or_no


=item archive_expand


Decompresses a variety of archive formats using your systems built in tools.

  ############### archive_expand ##################
  # Usage      : $util->archive_expand(
  #            :     archive => 'example.tar.bz2' );
  # Purpose    : test the archiver, determine its contents, and then
  #              use the best available means to expand it.
  # Returns    : 0 - failure, 1 - success
  # Parameters : S - archive - a bz2, gz, or tgz file to decompress


=item cwd_source_dir


Changes the current working directory to the supplied one. Creates it if it does not exist. Tries to create the directory using perl's builtin mkdir, then the system mkdir, and finally the system mkdir with sudo. 

  ############ cwd_source_dir ###################
  # Usage      : $util->cwd_source_dir( dir=>"/usr/local/src" );
  # Purpose    : prepare a location to build source files in
  # Returns    : 0 - failure,  1 - success
  # Parameters : S - dir - a directory to build programs in


=item check_homedir_ownership 

Checks the ownership on all home directories to see if they are owned by their respective users in /etc/password. Offers to repair the permissions on incorrectly owned directories. This is useful when someone that knows better does something like "chown -R user /home /user" and fouls things up.

  ######### check_homedir_ownership ############
  # Usage      : $util->check_homedir_ownership();
  # Purpose    : repair user homedir ownership
  # Returns    : 0 - failure,  1 - success
  # Parameters :
  #   Optional : I - auto - no prompts, just fix everything
  # See Also   : sysadmin

Comments: Auto mode should be run with great caution. Run it first to see the results and then, if everything looks good, run in auto mode to do the actual repairs. 


=item check_pidfile

see pidfile_check

=item chown_system

The advantage this sub has over a Pure Perl implementation is that it can utilize sudo to gain elevated permissions that we might not otherwise have.


  ############### chown_system #################
  # Usage      : $util->chown_system( dir=>"/tmp/example", user=>'matt' );
  # Purpose    : change the ownership of a file or directory
  # Returns    : 0 - failure,  1 - success
  # Parameters : S - dir    - the directory to chown
  #            : S - user   - a system username
  #   Optional : S - group  - a sytem group name
  #            : I - recurse - include all files/folders in directory?
  # Comments   : Uses the system chown binary
  # See Also   : n/a


=item clean_tmp_dir


  ############## clean_tmp_dir ################
  # Usage      : $util->clean_tmp_dir( dir=>$dir );
  # Purpose    : clean up old build stuff before rebuilding
  # Returns    : 0 - failure,  1 - success
  # Parameters : S - $dir - a directory or file. 
  # Throws     : die on failure
  # Comments   : Running this will delete its contents. Be careful!


=item get_mounted_drives

  ############# get_mounted_drives ############
  # Usage      : my $mounts = $util->get_mounted_drives();
  # Purpose    : Uses mount to fetch a list of mounted drive/partitions
  # Returns    : a hashref of mounted slices and their mount points.


=item file_archive


  ############### file_archive #################
  # Purpose    : Make a backup copy of a file by copying the file to $file.timestamp.
  # Usage      : my $archived_file = $util->file_archive( $file );
  # Returns    : the filename of the backup file, or 0 on failure.
  # Parameters : S - file - the filname to be backed up
  # Comments   : none


=item chmod

Set the permissions (ugo-rwx) of a file. Will use the native perl methods (by default) but can also use system calls and prepend sudo if additional permissions are needed.

  $util->chmod(
		file_or_dir => '/etc/resolv.conf',
		mode => '0755',
		sudo => $sudo
  )

 arguments required:
   file_or_dir - a file or directory to alter permission on
   mode   - the permissions (numeric)

 arguments optional:
   sudo  - the output of $util->sudo
   fatal - die on errors? (default: on)
   debug

 result:
   0 - failure
   1 - success


=item chown

Set the ownership (user and group) of a file. Will use the native perl methods (by default) but can also use system calls and prepend sudo if additional permissions are needed.

  $util->chown(
		file_or_dir => '/etc/resolv.conf',
		uid => 'root',
		gid => 'wheel',
		sudo => 1
  );

 arguments required:
   file_or_dir - a file or directory to alter permission on
   uid   - the uid or user name
   gid   - the gid or group name

 arguments optional:
   file  - alias for file_or_dir
   dir   - alias for file_or_dir
   sudo  - the output of $util->sudo
   fatal - die on errors? (default: on)
   debug

 result:
   0 - failure
   1 - success


=item file_delete

  ############################################
  # Usage      : $util->file_delete( file=>$file );
  # Purpose    : Deletes a file.
  # Returns    : 0 - failure, 1 - success
  # Parameters 
  #   Required : file - a file path
  # Comments   : none
  # See Also   : 

 Uses unlink if we have appropriate permissions, otherwise uses a system rm call, using sudo if it is not being run as root. This sub will try very hard to delete the file!


=item file_get

   $util->file_get( url=>$url, debug=>1 );

Use the standard URL fetching utility (fetch, curl, wget) for your OS to download a file from the $url handed to us.

 arguments required:
   url - the fully qualified URL

 arguments optional:
   timeout - the maximum amount of time to try
   fatal
   debug

 result:
   1 - success
   0 - failure


=item file_is_newer

compares the mtime on two files to determine if one is newer than another. 


=item file_mode

 usage:
   my @lines = "1", "2", "3";  # named array
   $util->file_write ( "/tmp/foo", lines=>\@lines );   
        or
   $util->file_write ( "/tmp/foo", lines=>['1','2','3'] );  # anon arrayref

 required arguments:
   mode - the files permissions mode

 arguments optional:
   fatal
   debug

 result:
   0 - failure
   1 - success


=item file_read

Reads in a file, and returns it in an array. All lines in the array are chomped.

   my @lines = $util->file_read( $file, max_lines=>100 )

 arguments required:
   file - the file to read in

 arguments optional:
   max_lines  - integer - max number of lines
   max_length - integer - maximum length of a line
   fatal
   debug

 result:
   0 - failure
   success - returns an array with the files contents, one line per array element


=item file_write

 usage:
   my @lines = "1", "2", "3";  # named array
   $util->file_write ( "/tmp/foo", lines=>\@lines );   
        or
   $util->file_write ( "/tmp/foo", lines=>['1','2','3'] );  # anon arrayref

 required arguments:
   file - the file path you want to write to
   lines - an arrayref. Each array element will be a line in the file

 arguments optional:
   fatal
   debug

 result:
   0 - failure
   1 - success


=item files_diff

Determine if the files are different. $type is assumed to be text unless you set it otherwise. For anthing but text files, we do a MD5 checksum on the files to determine if they are different or not.

   $util->files_diff( f1=>$file1,f2=>$file2,type=>'text',debug=>1 );

   if ( $util->files_diff( f1=>"foo", f2=>"bar" ) )
   {
       print "different!\n";
   };

 required arguments:
   f1 - the first file to compare
   f2 - the second file to compare

 arguments optional:
   type - the type of file (text or binary)
   fatal
   debug

 result:
   0 - files are the same
   1 - files are different
  -1 - error.


=item find_bin

Check all the "normal" locations for a binary that should be on the system and returns the full path to the binary.

   $util->find_bin( 'dos2unix', dir=>'/opt/local/bin' );

Example: 

   my $apachectl = $util->find_bin( "apachectl", dir=>"/usr/local/sbin" );


 arguments required:
   bin - the name of the program (its filename)

 arguments optional:
   dir - a directory to check first
   fatal
   debug

 results:
   0 - failure
   success will return the full path to the binary.


=item get_file

an alias for file_get for legacy purposes. Do not use.

=item get_my_ips

returns an arrayref of IP addresses on local interfaces. 

=item is_process_running

Verify if a process is running or not.

   $util->is_process_running($process) ? print "yes" : print "no";

$process is the name as it would appear in the process table.



=item is_readable


  ############################################
  # Usage      : $util->is_readable( file=>$file );
  # Purpose    : ????
  # Returns    : 0 = no (not reabable), 1 = yes
  # Parameters : S - file - a path name to a file
  # Throws     : no exceptions
  # Comments   : none
  # See Also   : n/a

  result:
     0 - no (file is not readable)
     1 - yes (file is readable)



=item is_writable

If the file exists, it checks to see if it is writable. If the file does not exist, it checks to see if the enclosing directory is writable. 

  ############################################
  # Usage      : $util->is_writable(file =>"/tmp/boogers");
  # Purpose    : make sure a file is writable
  # Returns    : 0 - no (not writable), 1 - yes (is writeable)
  # Parameters : S - file - a path name to a file
  # Throws     : no exceptions


=item fstab_list


  ############ fstab_list ###################
  # Usage      : $util->fstab_list;
  # Purpose    : Fetch a list of drives that are mountable from /etc/fstab.
  # Returns    : an arrayref
  # Comments   : used in backup.pl
  # See Also   : n/a


=item get_dir_files

   $util->get_dir_files( dir=>$dir, debug=>1 )

 required arguments:
   dir - a directory

 optional arguments:
   fatal
   debug

 result:
   an array of files names contained in that directory.
   0 - failure


=item get_the_date

Returns the date split into a easy to work with set of strings. 

   $util->get_the_date( bump=>$bump, debug=>$debug )

 required arguments:
   none

 optional arguments:
   bump - the offset (in days) to subtract from the date.
   debug

 result: (array with the following elements)
	$dd = day
	$mm = month
	$yy = year
	$lm = last month
	$hh = hours
	$mn = minutes
	$ss = seconds

	my ($dd, $mm, $yy, $lm, $hh, $mn, $ss) = $util->get_the_date();


=item install_from_source

  usage:

	$util->install_from_source(
		package => 'simscan-1.07',
   	    site    => 'http://www.inter7.com',
		url     => '/simscan/',
		targets => ['./configure', 'make', 'make install'],
		patches => '',
		debug   => 1,
	);

Downloads and installs a program from sources.

 required arguments:
    conf    - hashref - mail-toaster.conf settings.
    site    - 
    url     - 
    package - 

 optional arguments:
    targets - arrayref - defaults to [./configure, make, make install].
    patches - arrayref - patch(es) to apply to the sources before compiling
    patch_args - 
    source_sub_dir - a subdirectory within the sources build directory
    bintest - check the usual places for an executable binary. If found, it will assume the software is already installed and require confirmation before re-installing.
    debug
    fatal

 result:
   1 - success
   0 - failure


=item install_from_source_php

Downloads a PHP program and installs it. This function is not completed due to lack o interest.


=item is_interactive

tests to determine if the running process is attached to a terminal.


=item logfile_append

   $util->logfile_append( file=>$file, lines=>\@lines )

Pass a filename and an array ref and it will append a timestamp and the array contents to the file. Here's a working example:

   $util->logfile_append( file=>$file, prog=>"proggy", lines=>["Starting up", "Shutting down"] )

That will append a line like this to the log file:

   2004-11-12 23:20:06 proggy Starting up
   2004-11-12 23:20:06 proggy Shutting down

 arguments required:
   file  - the log file to append to
   prog  - the name of the application
   lines - arrayref - elements are events to log.

 arguments optional:
   fatal
   debug

 result:
   1 - success
   0 - failure


=item mailtoaster

   $util->mailtoaster();

Downloads and installs Mail::Toaster.


=item mkdir_system

   $util->mkdir_system( dir => $dir, debug=>$debug );

creates a directory using the system mkdir binary. Can also make levels of directories (-p) and utilize sudo if necessary to escalate.


=item pidfile_check

pidfile_check is a process management method. It will check to make sure an existing pidfile does not exist and if not, it will create the pidfile.

   $pidfile = $util->pidfile_check( pidfile=>"/var/run/program.pid" );

The above example is all you need to do to add process checking (avoiding multiple daemons running at the same time) to a program or script. This is used in toaster-watcher.pl. toaster-watcher normally completes a run in a few seconds and is run every 5 minutes. 

However, toaster-watcher can be configured to do things like expire old messages from maildirs and feed spam through a processor like sa-learn. This can take a long time on a large mail system so we don't want multiple instances of toaster-watcher running.

 result:
   the path to the pidfile (on success).

Example:

	my $pidfile = $util->pidfile_check( pidfile=>"/var/run/changeme.pid" );
	unless ($pidfile) {
		warn "WARNING: couldn't create a process id file!: $!\n";
		exit 0;
	};

	do_a_bunch_of_cool_stuff;
	unlink $pidfile;


=item regexp_test

Prints out a string with the regexp match bracketed. Credit to Damien Conway from Perl Best Practices.

 Example:
    $util->regexp_test( 
		exp    => 'toast', 
		string => 'mailtoaster rocks',
	);

 arguments required:
   exp    - the regular expression
   string - the string you are applying the regexp to

 result:
   printed string highlighting the regexp match


=item source_warning

Checks to see if the old build sources are present. If they are, offer to remove them.

 Usage:

   $util->source_warning( 
		package => "Mail-Toaster-4.10", 
		clean   => 1, 
		src     => "/usr/local/src" 
   );

 arguments required:
   package - the name of the packages directory

 arguments optional:
   src     - the source directory to build in (/usr/local/src)
   clean   - do we try removing the existing sources? (enabled)
   timeout - how long to wait for an answer (60 seconds)

 result:
   1 - removed
   0 - failure, package exists and needs to be removed.


=item sources_get

Tries to download a set of sources files from the site and url provided. It will try first fetching a gzipped tarball and if that files, a bzipped tarball. As new formats are introduced, I will expand the support for them here.

  usage:
	$self->sources_get( 
		package => 'simscan-1.07', 
		site    => 'http://www.inter7.com',
		path    => '/simscan/',
	)

 arguments required:
   package - the software package name
   site    - the host to fetch it from
   url     - the path to the package on $site

 arguments optional:
   conf    - hashref - values from toaster-watcher.conf
   debug

This sub proved quite useful during 2005 as many packages began to be distributed in bzip format instead of the traditional gzip.


=item sudo

   my $sudo = $util->sudo();

   $util->syscmd( "$sudo rm /etc/root-owned-file" );

Often you want to run a script as an unprivileged user. However, the script may need elevated privileges for a plethora of reasons. Rather than running the script suid, or as root, configure sudo allowing the script to run system commands with appropriate permissions.

If sudo is not installed and you're running as root, it'll offer to install sudo for you. This is recommended, as is properly configuring sudo.

 arguments required:

 arguments optional:
   debug

 result:
   0 - failure
   on success, the full path to the sudo binary


=item syscmd

   Just a little wrapper around system calls, that returns any failure codes and prints out the error(s) if present. A bit of sanity testing is also done to make sure the command to execute is safe. 

      my $r = $util->syscmd( "gzip /tmp/example.txt" );
      $r ? print "ok!\n" : print "not ok.\n";

    arguments required:
      cmd     - the command to execute

    arguments optional:
      debug
      fatal

    result
      the exit status of the program you called.


=item _try_mkdir

try creating a directory using perl's builtin mkdir.


=item yes_or_no

  my $r = $util->yes_or_no( 
      "Would you like fries with that?",
      timeout  => 30
  );

	$r ? print "fries are in the bag\n" : print "no fries!\n";

 arguments required:
   none.

 arguments optional:
   question - the question to ask
   timeout  - how long to wait for an answer (in seconds)

 result:
   0 - negative (or null)
   1 - success (affirmative)


=back

=head1 AUTHOR

Matt Simerson (matt@tnpi.net)


=head1 BUGS

None known. Report any to author.


=head1 TODO

  make all errors raise exceptions
  write test cases for every method
  comments. always needs more comments.


=head1 SEE ALSO

The following are all man/perldoc pages: 

 Mail::Toaster 


=head1 COPYRIGHT

Copyright (c) 2003-2009, The Network People, Inc. All Rights Reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

Neither the name of the The Network People, Inc. nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

=cut
