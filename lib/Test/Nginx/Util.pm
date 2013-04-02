package Test::Nginx::Util;

use strict;
use warnings;

our $VERSION = '0.21';

use base 'Exporter';

use POSIX qw( SIGQUIT SIGKILL SIGTERM SIGHUP );
use File::Spec ();
use HTTP::Response;
use Cwd qw( cwd );
use List::Util qw( shuffle );
use Time::HiRes qw( sleep );
use ExtUtils::MakeMaker ();
use File::Path qw(make_path);
use File::Find qw(find);
use File::Temp qw( tempfile );
use IO::Socket::INET;
use IO::Socket::UNIX;
use Test::LongString;

our $ConfigVersion;

our $NoLongString = undef;

our $UseHup = $ENV{TEST_NGINX_USE_HUP};

our $Verbose = $ENV{TEST_NGINX_VERBOSE};

our $LatestNginxVersion = 0.008039;

our $NoNginxManager = $ENV{TEST_NGINX_NO_NGINX_MANAGER} || 0;
our $Profiling = 0;

our $InSubprocess;
our $RepeatEach = 1;
our $MAX_PROCESSES = 10;

our $NoShuffle = $ENV{TEST_NGINX_NO_SHUFFLE} || 0;

our $UseValgrind = $ENV{TEST_NGINX_USE_VALGRIND};

our $UseStap = $ENV{TEST_NGINX_USE_STAP};

our $StapOutFile = $ENV{TEST_NGINX_STAP_OUT};

our $EventType = $ENV{TEST_NGINX_EVENT_TYPE};

our $PostponeOutput = $ENV{TEST_NGINX_POSTPONE_OUTPUT};

our $Timeout = $ENV{TEST_NGINX_TIMEOUT} || 3;

our $CheckLeak = $ENV{TEST_NGINX_CHECK_LEAK} || 0;

our $ServerAddr = 'localhost';

our $StapOutFileHandle;

our @RandStrAlphabet = ('A' .. 'Z', 'a' .. 'z', '0' .. '9',
    '#', '@', '-', '_', '^');

#$SIG{CHLD} = 'IGNORE';

sub is_running ($) {
    my $pid = shift;
    return kill 0, $pid;
}

sub gen_rand_str {
    my $len = shift;

    my $s = '';
    for (my $i = 0; $i < $len; $i++) {
        my $j = int rand scalar @RandStrAlphabet;
        my $c = $RandStrAlphabet[$j];
        $s .= $c;
    }

    return $s;
}

sub no_long_string () {
    $NoLongString = 1;
}

sub server_addr (@) {
    if (@_) {

        #warn "setting server addr to $_[0]\n";
        $ServerAddr = shift;
    }
    else {
        return $ServerAddr;
    }
}

sub stap_out_fh {
    return $StapOutFileHandle;
}

sub stap_out_fname {
    return $StapOutFile;
}

sub timeout (@) {
    if (@_) {
        $Timeout = shift;
    }
    else {
        $Timeout;
    }
}

sub no_shuffle () {
    $NoShuffle = 1;
}

sub no_nginx_manager () {
    $NoNginxManager = 1;
}

sub bail_out (@);

our $NginxBinary            = $ENV{TEST_NGINX_BINARY} || 'nginx';
our $Workers                = 1;
our $WorkerConnections      = 64;
our $LogLevel               = $ENV{TEST_NGINX_LOG_LEVEL} || 'debug';
our $MasterProcessEnabled   = $ENV{TEST_NGINX_MASTER_PROCESS} || 'off';
our $DaemonEnabled          = 'on';
our $ServerPort             = $ENV{TEST_NGINX_SERVER_PORT} || $ENV{TEST_NGINX_PORT} || 1984;
our $ServerPortForClient    = $ENV{TEST_NGINX_CLIENT_PORT} || $ENV{TEST_NGINX_PORT} || 1984;
our $NoRootLocation         = 0;
our $TestNginxSleep         = $ENV{TEST_NGINX_SLEEP} || 0.05;
our $BuildSlaveName         = $ENV{TEST_NGINX_BUILDSLAVE};
our $ForceRestartOnTest     = (defined $ENV{TEST_NGINX_FORCE_RESTART_ON_TEST})
                               ? $ENV{TEST_NGINX_FORCE_RESTART_ON_TEST} : 1;

our $ChildPid;
our $UdpServerPid;
our $TcpServerPid;

sub sleep_time {
    return $TestNginxSleep;
}

sub verbose {
    return $Verbose;
}

sub server_port (@) {
    if (@_) {
        $ServerPort = shift;
    } else {
        $ServerPort;
    }
}

sub repeat_each (@) {
    if (@_) {
        if ($CheckLeak) {
            return;
        }
        $RepeatEach = shift;
    } else {
        return $RepeatEach;
    }
}

sub worker_connections (@) {
    if (@_) {
        $WorkerConnections = shift;
    } else {
        return $WorkerConnections;
    }
}

sub no_root_location () {
    $NoRootLocation = 1;
}

sub workers (@) {
    if (@_) {
        #warn "setting workers to $_[0]";
        $Workers = shift;
    } else {
        return $Workers;
    }
}

sub log_level (@) {
    if (@_) {
        $LogLevel = shift;
    } else {
        return $LogLevel;
    }
}

sub master_on () {
    if ($CheckLeak) {
        return;
    }
    $MasterProcessEnabled = 'on';
}

sub master_off () {
    $MasterProcessEnabled = 'off';
}

sub master_process_enabled (@) {
    if ($CheckLeak) {
        return;
    }

    if (@_) {
        $MasterProcessEnabled = shift() ? 'on' : 'off';
    } else {
        return $MasterProcessEnabled;
    }
}

our @EXPORT_OK = qw(
    is_running
    $NoLongString
    no_long_string
    $ServerAddr
    server_addr
    parse_time
    $UseStap
    verbose
    sleep_time
    stap_out_fh
    stap_out_fname
    bail_out
    error_log_data
    setup_server_root
    write_config_file
    get_canon_version
    get_nginx_version
    trim
    show_all_chars
    parse_headers
    run_tests
    get_pid_from_pidfile
    $ServerPortForClient
    $ServerPort
    $NginxVersion
    $PidFile
    $ServRoot
    $ConfFile
    $RunTestHelper
    $NoNginxManager
    $RepeatEach
    $CheckLeak
    timeout
    worker_connections
    workers
    master_on
    master_off
    config_preamble
    repeat_each
    master_process_enabled
    log_level
    no_shuffle
    no_root_location
    html_dir
    server_root
    server_port
    no_nginx_manager
);


if ($Profiling || $UseValgrind || $UseStap) {
    $DaemonEnabled          = 'off';
    $MasterProcessEnabled   = 'off';
}

our $ConfigPreamble = '';

sub config_preamble ($) {
    $ConfigPreamble = shift;
}

our $RunTestHelper;

our $NginxVersion;
our $NginxRawVersion;
our $TODO;

#our ($PrevRequest)
our $PrevConfig;

our $ServRoot   = $ENV{TEST_NGINX_SERVROOT} || File::Spec->catfile(cwd() || '.', 't/servroot');
our $LogDir     = File::Spec->catfile($ServRoot, 'logs');
our $ErrLogFile = File::Spec->catfile($LogDir, 'error.log');
our $AccLogFile = File::Spec->catfile($LogDir, 'access.log');
our $HtmlDir    = File::Spec->catfile($ServRoot, 'html');
our $ConfDir    = File::Spec->catfile($ServRoot, 'conf');
our $ConfFile   = File::Spec->catfile($ConfDir, 'nginx.conf');
our $PidFile    = File::Spec->catfile($LogDir, 'nginx.pid');

sub parse_time ($) {
    my $tm = shift;

    if (defined $tm) {
        if ($tm =~ s/([^_a-zA-Z])ms$/$1/) {
            $tm = $tm / 1000;
        } elsif ($tm =~ s/([^_a-zA-Z])s$/$1/) {
            # do nothing
        } else {
            # do nothing
        }
    }

    return $tm;
}

sub html_dir () {
    return $HtmlDir;
}

sub server_root () {
    return $ServRoot;
}

sub bail_out (@) {
    cleanup();
    Test::More::BAIL_OUT(@_);
}

sub kill_process ($$) {
    my ($pid, $wait) = @_;

    if ($wait) {
        eval {
            if (defined $pid) {
                if ($Verbose) {
                    warn "sending QUIT signal to $pid";
                }

                kill(SIGQUIT, $pid);
            }

            if ($Verbose) {
                warn "waitpid timeout: ", timeout();
            }

            local $SIG{ALRM} = sub { die "alarm\n" };
            alarm timeout();
            waitpid($pid, 0);
            alarm 0;
        };

        if (!$@) {
            return;
        }

        if ($Verbose) {
            warn "WARNING: child process $pid timed out.\n";
        }
    }

    my $i = 1;
    while ($i <= 20) {
        #warn "ps returns: ", system("ps -p $pid > /dev/stderr"), "\n";
        #warn "$pid is running? ", is_running($pid) ? "Y" : "N", "\n";

        if (!is_running($pid)) {
            return;
        }

        if ($Verbose) {
            warn "WARNING: killing the child process $pid.\n";
        }

        if (kill(SIGQUIT, $pid) == 0) { # send quit signal
            warn "WARNING: failed to send quit signal to the child process with PID $pid.\n";
        }

        sleep $TestNginxSleep * $i;

    } continue {
        $i++;
    }

    warn "WARNING: killing the child process $pid with force...";

    kill(SIGKILL, $pid);
    waitpid($pid, 0);

    sleep $TestNginxSleep;
}

sub cleanup () {
    if (defined $UdpServerPid) {
        kill_process($UdpServerPid, 1);
        undef $UdpServerPid;
    }

    if (defined $TcpServerPid) {
        kill_process($TcpServerPid, 1);
        undef $TcpServerPid;
    }

    if (defined $ChildPid) {
        kill_process($ChildPid, 1);
        undef $ChildPid;
    }
}

sub error_log_data () {
    # this is for logging in the log-phase which is after the serser closes the connection:
    sleep $TestNginxSleep * 3;

    open my $in, $ErrLogFile or
        return undef;
    my @lines = <$in>;
    close $in;
    return \@lines;
}

sub run_tests () {
    $NginxVersion = get_nginx_version();

    if (defined $NginxVersion) {
        #warn "[INFO] Using nginx version $NginxVersion ($NginxRawVersion)\n";
    }

    for my $block ($NoShuffle ? Test::Base::blocks() : shuffle Test::Base::blocks()) {
        run_test($block);
    }

    cleanup();
}

sub setup_server_root () {
    if (-d $ServRoot) {
        if ($UseHup) {
            find({ bydepth => 1, no_chdir => 1, wanted => sub {
                 if (-d $_) {
                     if ($_ ne $ServRoot && $_ ne $LogDir) {
                         #warn "removing directory $_";
                         rmdir $_ or warn "Failed to rmdir $_\n";
                     }

                 } else {
                     if ($_ =~ /\bnginx\.pid$/) {
                         return;
                     }

                     #warn "removing file $_";
                     system("rm $_") == 0 or warn "Failed to remove $_\n";
                 }

            }}, $ServRoot);

        } else {

            # Take special care, so we won't accidentally remove
            # real user data when TEST_NGINX_SERVROOT is mis-used.
            my $rc = system("rm -rf $ConfDir > /dev/null");
            if ($rc != 0) {
                if ($rc == -1) {
                    bail_out "Cannot remove $ConfDir: $rc: $!\n";

                } else {
                    bail_out "Can't remove $ConfDir: $rc";
                }
            }

            system("rm -rf $HtmlDir > /dev/null") == 0 or
                bail_out "Can't remove $HtmlDir";
            system("rm -rf $LogDir > /dev/null") == 0 or
                bail_out "Can't remove $LogDir";
            system("rm -rf $ServRoot/*_temp > /dev/null") == 0 or
                bail_out "Can't remove $ServRoot/*_temp";
            system("rmdir $ServRoot > /dev/null") == 0 or
                bail_out "Can't remove $ServRoot (not empty?)";
        }
    }
    if (!-d $ServRoot) {
        mkdir $ServRoot or
            bail_out "Failed to do mkdir $ServRoot\n";
    }
    if (!-d $LogDir) {
        mkdir $LogDir or
            bail_out "Failed to do mkdir $LogDir\n";
    }
    mkdir $HtmlDir or
        bail_out "Failed to do mkdir $HtmlDir\n";

    my $index_file = "$HtmlDir/index.html";

    open my $out, ">$index_file" or
        bail_out "Can't open $index_file for writing: $!\n";

    print $out '<html><head><title>It works!</title></head><body>It works!</body></html>';

    close $out;

    mkdir $ConfDir or
        bail_out "Failed to do mkdir $ConfDir\n";
}

sub write_user_files ($) {
    my $block = shift;

    my $name = $block->name;

    if ($block->user_files) {
        my $raw = $block->user_files;

        open my $in, '<', \$raw;

        my @files;
        my ($fname, $body, $date);
        while (<$in>) {
            if (/>>> (\S+)(?:\s+(.+))?/) {
                if ($fname) {
                    push @files, [$fname, $body, $date];
                }

                $fname = $1;
                $date = $2;
                undef $body;
            } else {
                $body .= $_;
            }
        }

        if ($fname) {
            push @files, [$fname, $body, $date];
        }

        for my $file (@files) {
            my ($fname, $body, $date) = @$file;
            #warn "write file $fname with content [$body]\n";

            if (!defined $body) {
                $body = '';
            }

            my $path;
            if ($fname !~ m{^/}) {
                $path = "$HtmlDir/$fname";

            } else {
                $path = $fname;
            }

            if ($path =~ /(.*)\//) {
                my $dir = $1;
                if (! -d $dir) {
                    make_path($dir) or bail_out "$name - Cannot create directory ", $dir;
                }
            }

            open my $out, ">$path" or
                bail_out "$name - Cannot open $path for writing: $!\n";
            print $out $body;
            close $out;

            if ($date) {
                my $cmd = "TZ=GMT touch -t '$date' $HtmlDir/$fname";
                system($cmd) == 0 or
                    bail_out "Failed to run shell command: $cmd\n";
            }
        }
    }
}

sub write_config_file ($$$) {
    my ($config, $http_config, $main_config) = @_;

    if ($UseHup) {
        master_on(); # config reload is buggy when master is off

    } elsif ($UseValgrind || $UseStap) {
        master_off();
    }

    $http_config = expand_env_in_config($http_config);

    if (!defined $config) {
        $config = '';
    }

    if (!defined $http_config) {
        $http_config = '';
    }

    if ($http_config =~ /\bpostpone_output\b/) {
        undef $PostponeOutput;
    }

    if (defined $PostponeOutput) {
        if ($PostponeOutput !~ /^\d+$/) {
            bail_out "Bad TEST_NGINX_POSTPOHNE_OUTPUT value: $PostponeOutput\n";
        }
        $http_config .= "\n    postpone_output $PostponeOutput;\n";
    }

    if (!defined $main_config) {
        $main_config = '';
    }

    if ($CheckLeak) {
        $LogLevel = 'warn';
        $AccLogFile = 'off';
    }

    open my $out, ">$ConfFile" or
        bail_out "Can't open $ConfFile for writing: $!\n";
    print $out <<_EOC_;
worker_processes  $Workers;
daemon $DaemonEnabled;
master_process $MasterProcessEnabled;
error_log $ErrLogFile $LogLevel;
pid       $PidFile;
env MOCKEAGAIN_VERBOSE;
env MOCKEAGAIN;
env MOCKEAGAIN_WRITE_TIMEOUT_PATTERN;
env LD_PRELOAD;
env DYLD_INSERT_LIBRARIES;
env LUA_PATH;
env LUA_CPATH;

$main_config

http {
    access_log $AccLogFile;
    #access_log off;

    default_type text/plain;
    keepalive_timeout  68;

$http_config

    server {
        listen          $ServerPort;
        server_name     'localhost';

        client_max_body_size 30M;
        #client_body_buffer_size 4k;

        # Begin preamble config...
$ConfigPreamble
        # End preamble config...

        # Begin test case config...
$config
        # End test case config.

_EOC_

    if (! $NoRootLocation) {
        print $out <<_EOC_;
        location / {
            root $HtmlDir;
            index index.html index.htm;
        }
_EOC_
    }

    print $out "    }\n";

    if ($UseHup) {
        print $out <<_EOC_;
    server {
        listen          $ServerPort;
        server_name     'Test-Nginx';

        location = /ver {
            return 200 '$ConfigVersion';
        }
    }
_EOC_
    }

    print $out <<_EOC_;
}

#timer_resolution 100ms;

events {
    #accept_mutex off;

    worker_connections  $WorkerConnections;
_EOC_

    if ($EventType) {
        print $out <<_EOC_;
    use $EventType;
_EOC_
    }

    print $out "}\n";

    close $out;
}

sub get_canon_version (@) {
    sprintf "%d.%03d%03d", $_[0], $_[1], $_[2];
}

sub get_nginx_version () {
    my $out = `$NginxBinary -V 2>&1`;
    if (!defined $out || $? != 0) {
        warn "Failed to get the version of the Nginx in PATH.\n";
    }
    if ($out =~ m{(?:nginx|ngx_openresty)/(\d+)\.(\d+)\.(\d+)}s) {
        $NginxRawVersion = "$1.$2.$3";
        return get_canon_version($1, $2, $3);
    }
    warn "Failed to parse the output of \"nginx -V\": $out\n";
    return undef;
}

sub get_pid_from_pidfile ($) {
    my ($name) = @_;

    open my $in, $PidFile or
        bail_out("$name - Failed to open the pid file $PidFile for reading: $!");
    my $pid = do { local $/; <$in> };
    chomp $pid;
    #warn "Pid: $pid\n";
    close $in;
    return $pid;
}

sub trim ($) {
    my $s = shift;
    return undef if !defined $s;
    $s =~ s/^\s+|\s+$//g;
    $s =~ s/\n/ /gs;
    $s =~ s/\s{2,}/ /gs;
    $s;
}

sub show_all_chars ($) {
    my $s = shift;
    $s =~ s/\n/\\n/gs;
    $s =~ s/\r/\\r/gs;
    $s =~ s/\t/\\t/gs;
    $s;
}

sub test_config_version ($) {
    my $name = shift;
    my $total = 35;
    my $sleep = sleep_time();
    my $nsucc = 0;

    #$ConfigVersion = '322';

    for (my $tries = 1; $tries <= $total; $tries++) {

        my $ver = `curl -s -S -H 'Host: Test-Nginx' --connect-timeout 2 'http://$ServerAddr:$ServerPort/ver'`;
        #chop $ver;

        if ($Verbose) {
            warn "$name - ConfigVersion: $ver == $ConfigVersion\n";
        }

        if ($ver eq $ConfigVersion) {
            $nsucc++;

            if ($nsucc == 5) {
                sleep $sleep;
            }

            if ($nsucc >= 10) {
                #warn "MATCHED!!!\n";
                return;
            }

            #sleep $sleep;
            next;

        } else {
            if ($nsucc) {
                if ($Verbose) {
                    warn "$name - reset nsucc $nsucc\n";
                }

                $nsucc = 0;
            }
        }

        my $wait = ($sleep + $sleep * $tries) * $tries / 2;
        if ($wait > 1) {
            $wait = 1;
        }

        if ($wait > 0.5) {
            warn "$name - waiting $wait sec for nginx to reload the configuration\n";
        }

        sleep $wait;
    }

    my $tb = Test::More->builder;
    $tb->no_ending(1);

    Test::More::fail("$name - failed to reload configuration");
}

sub parse_headers ($) {
    my $s = shift;
    my %headers;
    open my $in, '<', \$s;
    while (<$in>) {
        s/^\s+|\s+$//g;
        my $neg = ($_ =~ s/^!\s*//);
        #warn "neg: $neg ($_)";
        if ($neg) {
            $headers{$_} = undef;
        } else {
            my ($key, $val) = split /\s*:\s*/, $_, 2;
            $headers{$key} = $val;
        }
    }
    close $in;
    return \%headers;
}

sub expand_env_in_config ($) {
    my $config = shift;

    if (!defined $config) {
        return;
    }

    $config =~ s/\$(TEST_NGINX_[_A-Z0-9]+)/
        if (!defined $ENV{$1}) {
            bail_out "No environment $1 defined.\n";
        }
        $ENV{$1}/eg;

    $config;
}

sub check_if_missing_directives () {
    open my $in, $ErrLogFile or
        bail_out "check_if_missing_directives: Cannot open $ErrLogFile for reading: $!\n";

    while (<$in>) {
        #warn $_;
        if (/\[emerg\] \S+?: unknown directive "([^"]+)"/) {
            #warn "MATCHED!!! $1";
            return $1;
        }
    }

    close $in;

    #warn "NOT MATCHED!!!";

    return 0;
}

sub run_test ($) {
    my $block = shift;
    my $name = $block->name;

    if ($CheckLeak && $UseStap) {
        bail_out("TEST_NGINX_CHEKC_LEAK does not work with "
                 . "TEST_NGINX_USE_STAP");
    }

    if (!defined $ENV{TEST_NGINX_SERVER_PORT}) {
        $ENV{TEST_NGINX_SERVER_PORT} = $ServerPort;
    }

    my $config = $block->config;

    $config = expand_env_in_config($config);

    my $dry_run = 0;
    my $should_restart = 1;
    my $should_reconfig = 1;

    local $StapOutFile = $StapOutFile;

    #warn "run test\n";
    local $LogLevel = $LogLevel;
    if ($block->log_level) {
        $LogLevel = $block->log_level;
    }

    if (!defined $config) {
        if (!$NoNginxManager) {
            # Manager without config.
            if (!defined $PrevConfig) {
                bail_out("$name - No '--- config' section specified and could not get previous one. Use TEST_NGINX_NO_NGINX_MANAGER ?");
                die;
            }
            $should_reconfig = 0; # There is nothing to reconfig to.
            $should_restart = $ForceRestartOnTest;
        }
        # else: not manager without a config. This is not a problem at all.
        # setting these values to something meaningful but should not be used
        $should_restart = 0;
        $should_reconfig = 0;

    } elsif ($NoNginxManager) {
        # One config but not manager: it's worth a warning.
        Test::Base::diag("NO_NGINX_MANAGER activated: config for $name ignored");
        # Like above: setting them to something meaningful just in case.
        $should_restart = 0;
        $should_reconfig = 0;

    } else {
        # One config and manager. Restart only if forced to or if config
        # changed.
        if ((!defined $PrevConfig) || ($config ne $PrevConfig)) {
            $should_reconfig = 1;
        } else {
            $should_reconfig = 0;
        }
        if ($should_reconfig || $ForceRestartOnTest) {
            $should_restart = 1;
        } else {
            $should_restart = 0;
        }
    }

    #warn "should restart: $should_restart\n";

    my $skip_nginx = $block->skip_nginx;
    my $skip_nginx2 = $block->skip_nginx2;
    my $skip_eval = $block->skip_eval;
    my $skip_slave = $block->skip_slave;
    my ($tests_to_skip, $should_skip, $skip_reason);

    if (defined $skip_eval) {
        if ($skip_eval =~ m{
                ^ \s* (\d+) \s* : \s* (.*)
            }xs)
        {
            $tests_to_skip = $1;
            $skip_reason = "skip_eval";
            my $code = $2;
            $should_skip = eval $code;
            if ($@) {
                bail_out("$name - skip_eval - failed to eval the Perl code "
                         . "\"$code\": $@");
            }
        }
    }

    if (defined $skip_nginx) {
        if ($skip_nginx =~ m{
                ^ \s* (\d+) \s* : \s*
                    ([<>]=?) \s* (\d+)\.(\d+)\.(\d+)
                    (?: \s* : \s* (.*) )?
                \s*$}x) {
            $tests_to_skip = $1;
            my ($op, $ver1, $ver2, $ver3) = ($2, $3, $4, $5);
            $skip_reason = $6;
            #warn "$ver1 $ver2 $ver3";
            my $ver = get_canon_version($ver1, $ver2, $ver3);
            if ((!defined $NginxVersion and $op =~ /^</)
                    or eval "$NginxVersion $op $ver")
            {
                $should_skip = 1;
            }
        } else {
            bail_out("$name - Invalid --- skip_nginx spec: " .
                $skip_nginx);
            die;
        }
    } elsif (defined $skip_nginx2) {
        if ($skip_nginx2 =~ m{
                ^ \s* (\d+) \s* : \s*
                    ([<>]=?) \s* (\d+)\.(\d+)\.(\d+)
                    \s* (or|and) \s*
                    ([<>]=?) \s* (\d+)\.(\d+)\.(\d+)
                    (?: \s* : \s* (.*) )?
                \s*$}x) {
            $tests_to_skip = $1;
            my ($opa, $ver1a, $ver2a, $ver3a) = ($2, $3, $4, $5);
            my $opx = $6;
            my ($opb, $ver1b, $ver2b, $ver3b) = ($7, $8, $9, $10);
            $skip_reason = $11;
            my $vera = get_canon_version($ver1a, $ver2a, $ver3a);
            my $verb = get_canon_version($ver1b, $ver2b, $ver3b);

            if ((!defined $NginxVersion)
                or (($opx eq "or") and (eval "$NginxVersion $opa $vera"
                                        or eval "$NginxVersion $opb $verb"))
                or (($opx eq "and") and (eval "$NginxVersion $opa $vera"
                                        and eval "$NginxVersion $opb $verb")))
            {
                $should_skip = 1;
            }
        } else {
            bail_out("$name - Invalid --- skip_nginx2 spec: " .
                $skip_nginx2);
            die;
        }
    } elsif (defined $skip_slave and defined $BuildSlaveName) {
        if ($skip_slave =~ m{
              ^ \s* (\d+) \s* : \s*
                (\w+) \s* (?: (\w+) \s* )?  (?: (\w+) \s* )?
                (?: \s* : \s* (.*) )? \s*$}x)
        {
            $tests_to_skip = $1;
            my ($slave1, $slave2, $slave3) = ($2, $3, $4);
            $skip_reason = $5;
            if ((defined $slave1 and $slave1 eq "all")
                or (defined $slave1 and $slave1 eq $BuildSlaveName)
                or (defined $slave2 and $slave2 eq $BuildSlaveName)
                or (defined $slave3 and $slave3 eq $BuildSlaveName)
                )
            {
                $should_skip = 1;
            }
        } else {
            bail_out("$name - Invalid --- skip_slave spec: " .
                $skip_slave);
            die;
        }
    }

    if (!defined $skip_reason) {
        $skip_reason = "various reasons";
    }

    my $todo_nginx = $block->todo_nginx;
    my ($should_todo, $todo_reason);
    if (defined $todo_nginx) {
        if ($todo_nginx =~ m{
                ^ \s*
                    ([<>]=?) \s* (\d+)\.(\d+)\.(\d+)
                    (?: \s* : \s* (.*) )?
                \s*$}x) {
            my ($op, $ver1, $ver2, $ver3) = ($1, $2, $3, $4);
            $todo_reason = $5;
            my $ver = get_canon_version($ver1, $ver2, $ver3);
            if ((!defined $NginxVersion and $op =~ /^</)
                    or eval "$NginxVersion $op $ver")
            {
                $should_todo = 1;
            }
        } else {
            bail_out("$name - Invalid --- todo_nginx spec: " .
                $todo_nginx);
            die;
        }
    }

    if (!defined $todo_reason) {
        $todo_reason = "various reasons";
    }

    #warn "HERE";

    if (!$NoNginxManager && !$should_skip && $should_restart) {
        #warn "HERE";

        if ($UseHup) {
            $ConfigVersion = gen_rand_str(10);
        }

        if ($should_reconfig) {
            $PrevConfig = $config;
        }

        my $nginx_is_running = 1;

        #warn "pid file: ", -f $PidFile;

        if (-f $PidFile) {
            #warn "HERE";
            my $pid = get_pid_from_pidfile($name);

            #warn "PID: $pid\n";

            if (!defined $pid or $pid eq '') {
                #warn "HERE";
                undef $nginx_is_running;
                goto start_nginx;
            }

            #warn "HERE";

            if (is_running($pid)) {
                #warn "found running nginx...";

                if ($UseHup) {
                    setup_server_root();
                    write_user_files($block);
                    write_config_file($config, $block->http_config, $block->main_config);

                    if ($Verbose) {
                        warn "sending USR1 signal to $pid.\n";
                    }
                    if (system("kill -USR1 $pid") == 0) {
                        sleep $TestNginxSleep;

                        if ($Verbose) {
                            warn "sending HUP signal to $pid.\n";
                        }

                        if (system("kill -HUP $pid") == 0) {
                            sleep $TestNginxSleep * 3;

                            if ($Verbose) {
                                warn "skip starting nginx from scratch\n";
                            }

                            $nginx_is_running = 1;

                            if ($UseValgrind) {
                                warn "$name\n";
                            }

                            test_config_version($name);

                            goto request;

                        } else {
                            if ($Verbose) {
                                warn "$name - Failed to send HUP signal";
                            }
                        }

                    } else {
                        warn "$name - Failed to send USR1 signal";
                    }
                }

                if ($Verbose) {
                    warn "sending QUIT signal to $pid\n";
                }

                if (kill(SIGQUIT, $pid) == 0) { # send quit signal
                    #warn("$name - Failed to send quit signal to the nginx process with PID $pid");
                }

                sleep $TestNginxSleep;

                if (is_running($pid)) {
                    warn "WARNING: killing nginx $pid with force...";
                    kill(SIGKILL, $pid);
                    waitpid($pid, 0);
                }

                undef $nginx_is_running;

            } else {
                if (-f $PidFile) {
                    unlink $PidFile or
                        warn "WARNING: failed to remove pid file $PidFile\n";
                }

                undef $nginx_is_running;
            }

        } else {
            undef $nginx_is_running;
        }

start_nginx:

        unless ($nginx_is_running) {
            if ($Verbose) {
                warn "starting nginx from scratch\n";
            }

            #system("killall -9 nginx");

            #warn "*** Restarting the nginx server...\n";
            setup_server_root();
            write_user_files($block);
            write_config_file($config, $block->http_config, $block->main_config);
            #warn "nginx binary: $NginxBinary";
            if ( ! can_run($NginxBinary) ) {
                bail_out("$name - Cannot find the nginx executable in the PATH environment");
                die;
            }
        #if (system("nginx -p $ServRoot -c $ConfFile -t") != 0) {
        #Test::More::BAIL_OUT("$name - Invalid config file");
        #}
        #my $cmd = "nginx -p $ServRoot -c $ConfFile > /dev/null";
            if (!defined $NginxVersion) {
                $NginxVersion = $LatestNginxVersion;
            }

            my $cmd;
            if ($NginxVersion >= 0.007053) {
                $cmd = "$NginxBinary -p $ServRoot/ -c $ConfFile > /dev/null";
            } else {
                $cmd = "$NginxBinary -c $ConfFile > /dev/null";
            }

            if ($UseValgrind) {
                my $opts;

                if ($UseValgrind =~ /^\d+$/) {
                    $opts = "--tool=memcheck --leak-check=full --show-possibly-lost=no";

                    if (-f 'valgrind.suppress') {
                        $cmd = "valgrind -q $opts --gen-suppressions=all --suppressions=valgrind.suppress $cmd";
                    } else {
                        $cmd = "valgrind -q $opts --gen-suppressions=all $cmd";
                    }

                } else {
                    $opts = $UseValgrind;
                    $cmd = "valgrind -q $opts $cmd";
                }

                warn "$name\n";
                #warn "$cmd\n";

                undef $UseStap;

            } elsif ($UseStap) {

                if ($StapOutFileHandle) {
                    close $StapOutFileHandle;
                    undef $StapOutFileHandle;
                }

                if ($block->stap) {
                    my ($stap_fh, $stap_fname) = tempfile("XXXXXXX", SUFFIX => '.stp', TMPDIR => 1);
                    my $stap = $block->stap;
                    $stap =~ s/^\bS\(([^)]+)\)/probe process("nginx").statement("*\@$1")/smg;
                    $stap =~ s/^\bF\(([^\)]+)\)/probe process("nginx").function("$1")/smg;
                    $stap =~ s/^\bM\(([-\w]+)\)/probe process("nginx").mark("$1")/smg;
                    $stap =~ s/\bT\(\)/println("Fire ", pp())/smg;
                    print $stap_fh $stap;
                    close $stap_fh;

                    my ($out, $outfile);

                    if (!defined $block->stap_out && !defined $block->stap_out_like) {
                        $StapOutFile = "/dev/stderr";
                    }

                    if (!$StapOutFile) {
                        ($out, $outfile) = tempfile("XXXXXXXX", SUFFIX => '.stp-out', TMPDIR => 1);
                        close $out;

                        $StapOutFile = $outfile;

                    } else {
                        $outfile = $StapOutFile;
                    }

                    open $out, $outfile or
                        bail_out("Cannot open $outfile for reading: $!\n");

                    $StapOutFileHandle = $out;
                    if (defined $ENV{LD_PRELOAD}) {
                        $cmd = qq!LD_PRELOAD="$ENV{LD_PRELOAD}" exec $cmd!;

                    } else {
                        $cmd = "exec $cmd";
                    }

                    $cmd = "stap-nginx -c '$cmd' -o $outfile $stap_fname";

                    #warn "CMD: $cmd\n";

                    warn "$name\n";
                }
            }

            if ($Profiling || $UseValgrind || $UseStap) {
                my $pid = fork();

                if (!defined $pid) {
                    bail_out("$name - fork() failed: $!");

                } elsif ($pid == 0) {
                    # child process
                    #my $rc = system($cmd);

                    $InSubprocess = 1;

                    if ($Verbose) {
                        warn "command: $cmd\n";
                    }

                    exec "exec $cmd";

                } else {
                    # main process
                    $ChildPid = $pid;
                }

                sleep $TestNginxSleep;

            } else {
                if (system($cmd) != 0) {
                    if ($ENV{TEST_NGINX_IGNORE_MISSING_DIRECTIVES} and
                            my $directive = check_if_missing_directives())
                    {
                        $dry_run = $directive;

                    } else {
                        bail_out("$name - Cannot start nginx using command \"$cmd\".");
                    }
                }
            }

            sleep $TestNginxSleep;
        }
    }

request:

    if ($Verbose) {
        warn "preparing requesting...\n";
    }

    if ($block->init) {
        eval $block->init;
        if ($@) {
            bail_out("$name - init failed: $@");
        }
    }

    my $i = 0;
    while ($i++ < $RepeatEach) {
        #warn "Use hup: $UseHup, i: $i\n";

        if ($Verbose) {
            warn "Run the test block...\n";
        }

        if ($CheckLeak && defined $block->tcp_listen) {

            my $n = defined($block->tcp_query_len) ? 1 : 0;
            $n += defined($block->tcp_query) ? 1 : 0;

            if ($n) {
                SKIP: {
                    Test::More::skip(qq{$name -- tests skipped because embedded TCP }
                        .qq{server does not work with the "check leak" mode}, $n);
                }
            }
        }

        my $tcp_socket;
        if (!$CheckLeak && defined $block->tcp_listen) {
            my $port = $block->tcp_listen;
            if ($port !~ /^\d+$/) {
                bail_out("$name - bad tcp_listen port number: $port");
            }

            my $reply = $block->tcp_reply;
            if (!defined $reply) {
                bail_out("$name - no --- tcp_reply specified but --- tcp_listen is specified");
            }

            my $req_len = $block->tcp_query_len;

            #warn "Reply: ", $reply;

            my $err;
            for (my $i = 0; $i < 30; $i++) {
                $tcp_socket = IO::Socket::INET->new(
                    LocalHost => '127.0.0.1',
                    LocalPort => $port,
                    Proto => 'tcp',
                    Reuse => 1,
                    Listen => 5,
                    Timeout => timeout(),
                );

                if ($tcp_socket) {
                    last;
                }

                if ($!) {
                    $err = $!;
                    if ($err =~ /address already in use/i) {
                        warn "WARNING: failed to create the tcp listening socket: $err\n";
                        sleep 1;
                        next;
                    }
                }

                last;
            }

            if (!$tcp_socket && $err) {
                bail_out("$name - failed to create the tcp listening socket: $err");
            }

            if (defined $block->tcp_query || defined $req_len) {
                my $tb = Test::More->builder;
                $tb->use_numbers(0);
                $tb->no_ending(1);
            }

            my $pid = fork();

            if (!defined $pid) {
                bail_out("$name - fork() failed: $!");

            } elsif ($pid == 0) {
                # child process
                #my $rc = system($cmd);

                $InSubprocess = 1;

                if ($Verbose) {
                    warn "TCP server is listening on $port ...\n";
                }

                local $| = 1;

                my $client;

                while (1) {
                    $client = $tcp_socket->accept();
                    last if $client;
                    warn("WARNING: $name - TCP server: failed to accept: $!\n");
                    sleep $TestNginxSleep;
                }

                my $buf;

                while (1) {
                    my $b;
                    my $ret = $client->recv($b, 4096);
                    if (!defined $ret) {
                        die "failed to receive: $!\n";
                    }

                    $buf .= $b;

                    if (!$req_len || length($buf) >= $req_len) {
                        last;
                    }
                }

                if (defined $req_len) {
                    Test::More::is(length($buf), $req_len, "$name - req len ok");
                }

                if (defined $block->tcp_query) {
                    if ($NoLongString) {
                        Test::More::is($buf, $block->tcp_query, "$name - tcp_query ok");
                    } else {
                        is_string $buf, $block->tcp_query, "$name - tcp_query ok";
                    }
                }

                if ($Verbose) {
                    warn "tcp server received $buf\n";
                }

                my $delay = parse_time($block->tcp_reply_delay);
                if ($delay) {
                    if ($Verbose) {
                        warn "sleep $delay before sending TCP reply\n";
                    }
                    sleep $delay;
                }

                if (defined $reply) {
                    if (ref $reply) {
                        for my $r (@$reply) {
                            #warn "sending reply $r";
                            my $bytes = $client->send($r);
                            if (!defined $bytes) {
                                warn "WARNING: tcp server failed to send reply: $!\n";
                            }
                        }

                    } else {
                        my $bytes = $client->send($reply);
                        if (!defined $bytes) {
                            warn "WARNING: tcp server failed to send reply: $!\n";
                        }
                    }
                }

                if ($Verbose) {
                    warn "TCP server is shutting down...\n";
                }

                if (defined $block->tcp_no_close) {
                    while (1) {
                        sleep 1;
                    }
                }

                $client->close();
                $tcp_socket->close();

                exit;

            } else {
                # main process
                if ($Verbose) {
                    warn "started sub-process $pid for the TCP server\n";
                }

                $TcpServerPid = $pid;
            }
        }

        if ($CheckLeak && defined $block->udp_listen) {

            my $n = defined($block->udp_query) ? 1 : 0;

            if ($n) {
                SKIP: {
                    Test::More::skip(qq{$name -- tests skipped because embedded UDP }
                        .qq{server does not work with the "check leak" mode}, $n);
                }
            }
        }

        my ($udp_socket, $uds_socket_file);
        if (!$CheckLeak && defined $block->udp_listen) {
            my $reply = $block->udp_reply;
            if (!defined $reply) {
                bail_out("$name - no --- udp_reply specified but --- udp_listen is specified");
            }

            my $target = $block->udp_listen;
            if ($target =~ /^\d+$/) {
                my $port = $target;

                $udp_socket = IO::Socket::INET->new(
                    LocalPort => $port,
                    Proto => 'udp',
                    Reuse => 1,
                    Timeout => timeout(),
                ) or bail_out("$name - failed to create the udp listening socket: $!");

            } elsif ($target =~ m{\S+\.sock$}) {
                if (-e $target) {
                    unlink $target or die "cannot remove $target: $!";
                }

                $udp_socket = IO::Socket::UNIX->new(
                    Local => $target,
                    Type  => SOCK_DGRAM,
                    Reuse => 1,
                    Timeout => timeout(),
                ) or die "$!";

                $uds_socket_file = $target;

            } else {
                bail_out("$name - bad udp_listen target: $target");
            }

            #warn "Reply: ", $reply;

            if (defined $block->udp_query) {
                my $tb = Test::More->builder;
                $tb->use_numbers(0);
                $tb->no_ending(1);
            }

            my $pid = fork();

            if (!defined $pid) {
                bail_out("$name - fork() failed: $!");

            } elsif ($pid == 0) {
                # child process
                #my $rc = system($cmd);

                $InSubprocess = 1;

                if ($Verbose) {
                    warn "UDP server is listening on $target ...\n";
                }

                local $| = 1;

                my $buf;
                $udp_socket->recv($buf, 4096);

                if (defined $block->udp_query) {
                    if ($NoLongString) {
                        Test::More::is($buf, $block->udp_query, "$name - udp_query ok");
                    } else {
                        is_string $buf, $block->udp_query, "$name - udp_query ok";
                    }
                }

                if ($Verbose) {
                    warn "udp server received $buf\n";
                }

                my $delay = parse_time($block->udp_reply_delay);
                if ($delay) {
                    if ($Verbose) {
                        warn "sleep $delay before sending UDP reply\n";
                    }
                    sleep $delay;
                }

                if (defined $reply) {
                    if (ref $reply) {
                        for my $r (@$reply) {
                            #warn "sending reply $r";
                            my $bytes = $udp_socket->send($r);
                            if (!defined $bytes) {
                                warn "WARNING: udp server failed to send reply: $!\n";
                            }
                        }

                    } else {
                        my $bytes = $udp_socket->send($reply);
                        if (!defined $bytes) {
                            warn "WARNING: udp server failed to send reply: $!\n";
                        }
                    }
                }

                if ($Verbose) {
                    warn "UDP server is shutting down...\n";
                }

                exit;

            } else {
                # main process
                if ($Verbose) {
                    warn "started sub-process $pid for the UDP server\n";
                }

                $UdpServerPid = $pid;
            }
        }

        if ($i > 1) {
            write_user_files($block);
        }

        if ($should_skip) {
            SKIP: {
                Test::More::skip("$name - $skip_reason", $tests_to_skip);

                $RunTestHelper->($block, $dry_run);
            }

        } elsif ($should_todo) {
            TODO: {
                local $TODO = "$name - $todo_reason";

                $RunTestHelper->($block, $dry_run);
            }

        } else {
            $RunTestHelper->($block, $dry_run);
        }

        if (defined $udp_socket) {
            if (defined $UdpServerPid) {
                kill_process($UdpServerPid, 1);
                undef $UdpServerPid;
            }

            $udp_socket->close();
            undef $udp_socket;
        }

        if (defined $uds_socket_file) {
            unlink($uds_socket_file)
                or warn "failed to unlink $uds_socket_file";
        }

        if (defined $tcp_socket) {
            if (defined $TcpServerPid) {
                if ($Verbose) {
                    warn "killing TCP server, pid $TcpServerPid\n";
                }
                kill_process($TcpServerPid, 1);
                undef $TcpServerPid;
            }

            if ($Verbose) {
                warn "closing the TCP socket\n";
            }

            $tcp_socket->close();
            undef $tcp_socket;
        }
    }

    if ($StapOutFileHandle) {
        close $StapOutFileHandle;
        undef $StapOutFileHandle;
    }

    if (my $total_errlog = $ENV{TEST_NGINX_ERROR_LOG}) {
        my $errlog = $ErrLogFile;
        if (-s $errlog) {
            open my $out, ">>$total_errlog" or
                bail_out "Failed to append test case title to $total_errlog: $!\n";
            print $out "\n=== $0 $name\n";
            close $out;
            system("cat $errlog >> $total_errlog") == 0 or
                bail_out "Failed to append $errlog to $total_errlog. Abort.\n";
        }
    }

    if (($Profiling || $UseValgrind || $UseStap) && !$UseHup) {
        #warn "Found quit...";
        if (-f $PidFile) {
            #warn "found pid file...";
            my $pid = get_pid_from_pidfile($name);
            my $i = 0;
retry:
            if (is_running($pid)) {
                write_config_file($config, $block->http_config, $block->main_config);

                if ($Verbose) {
                    warn "sending QUIT signal to $pid";
                }

                if (kill(SIGQUIT, $pid) == 0) { # send quit signal
                    warn("$name - Failed to send quit signal to the nginx process with PID $pid");
                }

                sleep $TestNginxSleep;

                if (-f $PidFile) {
                    if ($i++ < 5) {
                        if ($Verbose) {
                            warn "nginx not quitted, retrying...\n";
                        }

                        goto retry;
                    }

                    if ($Verbose) {
                        warn "sending KILL signal to $pid";
                    }

                    kill(SIGKILL, $pid);
                    waitpid($pid, 0);

                    unlink $PidFile or
                        bail_out "Failed to remove pid file $PidFile\n";

                } else {
                    #warn "nginx killed";
                }

            } else {
                unlink $PidFile or
                    bail_out "Failed to remove pid file $PidFile\n";
            }
        } else {
            #warn "pid file not found";
        }
    }
}

END {
    return if $InSubprocess;

    cleanup();

    if ($UseStap || $UseValgrind || !$ENV{TEST_NGINX_NO_CLEAN}) {
        local $?; # to avoid confusing Test::Builder::_ending
        if (-f $PidFile) {
            my $pid = get_pid_from_pidfile('');
            if (!$pid) {
                bail_out "No pid found.";
            }
            if (is_running($pid)) {
                if ($Verbose) {
                    warn "sending QUIT signal to $pid";
                }

                if (kill(SIGQUIT, $pid) == 0) { # send quit signal
                    #warn("Failed to send quit signal to the nginx process with PID $pid");
                }

                sleep $TestNginxSleep;

                if (is_running($pid)) {
                    warn "WARNING: killing nginx $pid with force...";
                    kill(SIGKILL, $pid);
                    waitpid($pid, 0);
                }

            } else {
                unlink $PidFile;
            }
        }
    }
}

# check if we can run some command
sub can_run {
    my ($cmd) = @_;

    #warn "can run: @_\n";
    my $_cmd = $cmd;
    return $_cmd if (-x $_cmd or $_cmd = MM->maybe_command($_cmd));

    for my $dir ((split /$Config::Config{path_sep}/, $ENV{PATH}), '.') {
        next if $dir eq '';
        my $abs = File::Spec->catfile($dir, $_[0]);
        return $abs if (-x $abs or $abs = MM->maybe_command($abs));
    }

    return;
}

1;
