package Test::Nginx::Util;

use strict;
use warnings;

our $VERSION = '0.29';

use base 'Exporter';

use POSIX qw( SIGQUIT SIGKILL SIGTERM SIGHUP );
use File::Spec ();
use HTTP::Response;
use Cwd qw( cwd );
use List::Util qw( shuffle );
use Time::HiRes qw( sleep );
use File::Path qw(make_path remove_tree);
use File::Find qw(find);
use File::Temp qw( tempfile :POSIX );
use Scalar::Util qw( looks_like_number );
use IO::Socket::INET;
use IO::Socket::UNIX;
use Test::LongString;
use Carp qw( croak );

our $ConfigVersion;
our $FilterHttpConfig;
my $LoadedIPCRun;

our $NoLongString = undef;
our $FirstTime = 1;

our $ReusePort = $ENV{TEST_NGINX_REUSE_PORT};

our $UseHttp3 = $ENV{TEST_NGINX_USE_HTTP3};

our $UseHttp2 = $ENV{TEST_NGINX_USE_HTTP2};

our $UseHup = $ENV{TEST_NGINX_USE_HUP};

our $UseRr = $ENV{TEST_NGINX_USE_RR};

our $Verbose = $ENV{TEST_NGINX_VERBOSE};

our $LatestNginxVersion = 0.008039;

our $NoNginxManager = $ENV{TEST_NGINX_NO_NGINX_MANAGER} || 0;
our $Profiling = 0;

sub use_http2 ($);
sub use_http3 ($);

our $InSubprocess;
our $RepeatEach = 1;
our $MAX_PROCESSES = 10;

our $LoadModules = $ENV{TEST_NGINX_LOAD_MODULES};

our $NoShuffle = $ENV{TEST_NGINX_NO_SHUFFLE} || 0;

our $UseValgrind = $ENV{TEST_NGINX_USE_VALGRIND};

our $UseStap = $ENV{TEST_NGINX_USE_STAP};

our $StapOutFile = $ENV{TEST_NGINX_STAP_OUT};

our $EventType = $ENV{TEST_NGINX_EVENT_TYPE};

our $PostponeOutput = $ENV{TEST_NGINX_POSTPONE_OUTPUT};

our $Timeout = $ENV{TEST_NGINX_TIMEOUT} || 3;

our $QuicIdleTimeout = $ENV{TEST_NGINX_QUIC_IDLE_TIMEOUT} || 0.6;

our $CheckLeak = $ENV{TEST_NGINX_CHECK_LEAK} || 0;

our $Benchmark = $ENV{TEST_NGINX_BENCHMARK} || 0;

our $BenchmarkWarmup = $ENV{TEST_NGINX_BENCHMARK_WARMUP} || 0;

our $CheckAccumErrLog = $ENV{TEST_NGINX_CHECK_ACCUM_ERR_LOG};

our $ServerAddr = '127.0.0.1';

our $ServerName = 'localhost';

our $Http3SSLCrt = $ENV{TEST_NGINX_HTTP3_CRT};
our $Http3SSLCrtKey = $ENV{TEST_NGINX_HTTP3_KEY};;

if ($UseHttp2 && $UseHttp3) {
    die "Ambiguous: both TEST_NGINX_USE_HTTP3 and TEST_NGINX_USE_HTTP2 are set.\n";
}

sub bail_out (@);

if ($UseHttp3 && (!defined $Http3SSLCrt || !defined $Http3SSLCrtKey)) {
    warn <<_EOC_;
Please generate the certificate/key pair using the following command,
and set TEST_NGINX_HTTP3_CRT and TEST_NGINX_HTTP3_KEY enviroment variables:
  openssl req -x509 -newkey rsa:4096 -keyout http3.key -out http3.crt -days \\
  7000 -nodes -subj '/CN=localhost' 2> /dev/null
_EOC_
    die "certificate/key pair not found";
}

our $ServerConfigHttp3 = '';

our $WorkerUser = $ENV{TEST_NGINX_WORKER_USER};
if (defined $WorkerUser && $WorkerUser !~ /^\w+(?:\s+\w+)?$/) {
    die "Bad value in the env TEST_NGINX_WORKER_USER: $WorkerUser\n";
}

our $StapOutFileHandle;

our @RandStrAlphabet = ('A' .. 'Z', 'a' .. 'z', '0' .. '9',
    '#', '@', '-', '_', '^');

our $PrevBlock;

our $ErrLogFilePos;

if ($Benchmark) {
    if ($UseStap) {
        warn "WARNING: TEST_NGINX_BENCHMARK and TEST_NGINX_USE_STAP "
             ."are both set and the former wins.\n";
        undef $UseStap;
    }

    if ($UseValgrind) {
        warn "WARNING: TEST_NGINX_BENCHMARK and TEST_NGINX_USE_VALGRIND "
             ."are both set and the former wins.\n";
        undef $UseValgrind;
    }

    if ($UseHup) {
        warn "WARNING: TEST_NGINX_BENCHMARK and TEST_NGINX_USE_HUP "
             ."are both set and the former wins.\n";
        undef $UseHup;
    }

    if ($CheckLeak) {
        warn "WARNING: TEST_NGINX_BENCHMARK and TEST_NGINX_CHECK_LEAK "
             ."are both set and the former wins.\n";
        undef $CheckLeak;
    }
}

if ($CheckLeak) {
    if ($UseStap) {
        warn "WARNING: TEST_NGINX_CHECK_LEAK and TEST_NGINX_USE_STAP "
             ."are both set and the former wins.\n";
        undef $UseStap;
    }

    if ($UseValgrind) {
        warn "WARNING: TEST_NGINX_CHECK_LEAK and TEST_NGINX_USE_VALGRIND "
             ."are both set and the former wins.\n";
        undef $UseValgrind;
    }

    if ($UseHup) {
        warn "WARNING: TEST_NGINX_CHECK_LEAK and TEST_NGINX_USE_HUP "
             ."are both set and the former wins.\n";
        undef $UseHup;
    }
}

if ($UseHup) {
    if ($UseStap) {
        warn "WARNING: TEST_NGINX_USE_HUP and TEST_NGINX_USE_STAP "
             ."are both set and the former wins.\n";
        undef $UseStap;
    }
}

if ($UseValgrind) {
    if ($UseStap) {
        warn "WARNING: TEST_NGINX_USE_VALGRIND and TEST_NGINX_USE_STAP "
             ."are both set and the former wins.\n";
        undef $UseStap;
    }
}

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

sub gen_rand_port (;$$) {
    my ($tries, $used_ports) = @_;

    $tries //= 1000;
    $used_ports //= {};

    my $rand_port;

    for (my $i = 0; $i < $tries; $i++) {
        my $port = int(rand 63550) + 1985;

        next if $used_ports->{$port};

        my $sock = IO::Socket::INET->new(
            LocalAddr => $ServerAddr,
            LocalPort => $port,
            Proto => 'tcp',
            Timeout => 0.1,
        );

        if (defined $sock) {
            $sock->close();
            $rand_port = $port;
            last;
        }

        if ($Verbose) {
            warn "Try again, port $port is already in use: $@\n";
        }
    }

    return $rand_port;
}

sub no_long_string () {
    $NoLongString = 1;
}

sub is_str (@) {
    my ($got, $expected, $desc) = @_;

    if (ref $expected && ref $expected eq 'Regexp') {
        return Test::More::like($got, $expected, $desc);
    }

    if ($NoLongString) {
        return Test::More::is($got, $expected, $desc);
    }

    return is_string($got, $expected, $desc);
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

sub server_name (@) {
    if (@_) {
        $ServerName = shift;

    } else {
        return $ServerName;
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

sub use_hup() {
    $UseHup = 1;
}

our @CleanupHandlers;
our @BlockPreprocessors;

our $Randomize              = $ENV{TEST_NGINX_RANDOMIZE};
our $NginxBinary            = $ENV{TEST_NGINX_BINARY} || 'nginx';
our $Workers                = 1;
our $WorkerConnections      = $ENV{TEST_NGINX_USE_HTTP3} ? 1024 : 64;
our $LogLevel               = $ENV{TEST_NGINX_LOG_LEVEL} || 'debug';
our $MasterProcessEnabled   = $ENV{TEST_NGINX_MASTER_PROCESS} || 'off';
our $DaemonEnabled          = 'on';
our $ServerPort             = $ENV{TEST_NGINX_SERVER_PORT} || $ENV{TEST_NGINX_PORT} || 1984;
our $ServerPortForClient    = $ENV{TEST_NGINX_CLIENT_PORT} || $ServerPort || 1984;
our $NoRootLocation         = 0;
our $TestNginxSleep         = $ENV{TEST_NGINX_SLEEP} || 0.015;
our $BuildSlaveName         = $ENV{TEST_NGINX_BUILDSLAVE};
our $ForceRestartOnTest     = (defined $ENV{TEST_NGINX_FORCE_RESTART_ON_TEST})
                               ? $ENV{TEST_NGINX_FORCE_RESTART_ON_TEST} : 1;
srand $$;

if ($Randomize) {
    my $tries = 1000;

    $ServerPort = gen_rand_port $tries;

    if (!defined $ServerPort) {
        bail_out "Cannot find an available listening port number after $tries attempts.\n";
    }

    $ServerPortForClient = $ServerPort;
}

our $ChildPid;
our $UdpServerPid;
our $TcpServerPid;
our @EnvToNginx;

sub env_to_nginx (@) {
    if (!@_) {
        croak "env_to_nginx: no arguments specified";
    }
    for my $v (@_) {
        if ($v !~ /^[A-Za-z_]/ || $v =~ /\n/) {
            croak "env_to_nginx: bad argument value: $v\n";
        }
        push @EnvToNginx, $v;
    }
}

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

sub server_port_for_client (@) {
    if (@_) {
        $ServerPortForClient = shift;
    } else {
        $ServerPortForClient;
    }
}

sub repeat_each (@) {
    if (@_) {
        if ($CheckLeak || $Benchmark) {
            return;
        }
        $RepeatEach = shift;
    }

    return $RepeatEach;
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

sub check_accum_error_log () {
    $CheckAccumErrLog = 1;
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

our @EXPORT = qw(
    use_http2
    use_http3
    env_to_nginx
    is_str
    check_accum_error_log
    is_running
    $NoLongString
    no_long_string
    $ServerAddr
    server_addr
    $ServerName
    server_name
    parse_time
    $UseStap
    verbose
    sleep_time
    stap_out_fh
    stap_out_fname
    bail_out
    add_cleanup_handler
    access_log_data
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
    $CheckErrorLog
    $CheckShutdownErrorLog
    $FilterHttpConfig
    $NoNginxManager
    $RepeatEach
    $CheckLeak
    $Benchmark
    $BenchmarkWarmup
    add_block_preprocessor
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
    server_port_for_client
    no_nginx_manager
    use_hup
);


if ($Profiling || $UseValgrind || $UseStap) {
    $DaemonEnabled          = 'off';
    if (!$UseValgrind) {
        $MasterProcessEnabled   = 'off';
    }
}

our $ConfigPreamble = '';

sub config_preamble ($) {
    $ConfigPreamble = shift;
}

our $RunTestHelper;
our $CheckErrorLog;
our $CheckShutdownErrorLog;

our $NginxVersion;
our $NginxRawVersion;
our $OpenSSLVersion;

sub add_block_preprocessor(&) {
    unshift @BlockPreprocessors, shift;
}

#our ($PrevRequest)
our $PrevConfig;

our $ServRoot;

if ($Randomize) {
    $ServRoot = File::Spec->rel2abs("t/servroot_" . $ServerPort);

} else {
    $ServRoot = $ENV{TEST_NGINX_SERVROOT} || File::Spec->rel2abs('t/servroot');
}
$ENV{TEST_NGINX_SERVER_ROOT} = $ServRoot;

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

sub add_cleanup_handler ($) {
   unshift @CleanupHandlers, shift;
}

sub bail_out (@) {
    cleanup();
    Test::More::BAIL_OUT(@_);
}

sub kill_process ($$$) {
    my ($pid, $wait, $name) = @_;

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

        if ($@) {
            if ($Verbose) {
                warn "$name - WARNING: child process $pid timed out.\n";
            }
        }
    }

    my $i = 1;
    my $step = $TestNginxSleep;
    while ($i <= 20) {
        #warn "ps returns: ", system("ps -p $pid > /dev/stderr"), "\n";
        #warn "$pid is running? ", is_running($pid) ? "Y" : "N", "\n";

        if (!is_running($pid)) {
            return;
        }

        if ($Verbose) {
            warn "WARNING: killing the child process $pid.\n";
        }

        if (kill(SIGTERM, $pid) == 0) { # send term signal
            warn "WARNING: failed to send term signal to the child process with PID $pid.\n";
        }

        $step *= 1.2;
        $step = 0.5 if $step > 0.5;
        sleep $step;

    } continue {
        $i++;
    }

    #system("ps aux|grep $pid > /dev/stderr");
    warn "$name - WARNING: killing the child process $pid with force...";

    if (getpgrp($pid) == $pid) {
        kill(SIGKILL, -$pid);

    } else {
        kill(SIGKILL, $pid);
    }

    waitpid($pid, 0);

    if (is_running($pid)) {
        local $SIG{ALRM} = sub { die "alarm\n" };
        alarm timeout();
        waitpid($pid, 0);
        alarm 0;
    }
}

sub cleanup () {
    if ($Verbose) {
        warn "cleaning up everything";
    }

    for my $hdl (@CleanupHandlers) {
       $hdl->();
    }

    if (defined $UdpServerPid) {
        kill_process($UdpServerPid, 1, "cleanup");
        undef $UdpServerPid;
    }

    if (defined $TcpServerPid) {
        kill_process($TcpServerPid, 1, "cleanup");
        undef $TcpServerPid;
    }

    if (defined $ChildPid) {
        kill_process($ChildPid, 1, "cleanup");
        undef $ChildPid;
    }
}

sub access_log_data () {
    sleep $TestNginxSleep * 3;

    open my $in, $AccLogFile or do {
        if ($AccLogFile ne "off") {
            die "open $AccLogFile failed: $!";
        }

        return undef;
    };

    my @lines = <$in>;

    close $in;
    return \@lines;
}

sub error_log_data () {
    # this is for logging in the log-phase which is after the server closes the connection:
    sleep $TestNginxSleep * 3;

    open my $in, $ErrLogFile or
        return undef;

    if (!$CheckAccumErrLog && $ErrLogFilePos > 0) {
        seek $in, $ErrLogFilePos, 0;
    }

    my @lines = <$in>;

    if (!$CheckAccumErrLog) {
        $ErrLogFilePos = tell($in);
    }

    close $in;
    return \@lines;
}

sub check_prev_block_shutdown_error_log () {
    my $block = $PrevBlock;

    if (!defined $block) {
        return;
    }

    my $name = $block->name;
    my $dry_run;

    if (defined $block->shutdown_error_log) {
        if ($UseHup) {
            $dry_run = 1;
        }

        if ($ENV{TEST_NGINX_NO_CLEAN}) {
            $dry_run = 1;
        }

        $CheckShutdownErrorLog->($block, $dry_run);
    }
}

sub run_tests () {
    $NginxVersion = get_nginx_version();

    if (defined $NginxVersion) {
        #warn "[INFO] Using nginx version $NginxVersion ($NginxRawVersion)\n";
    }

    if (!defined $ENV{TEST_NGINX_SERVER_PORT}) {
        $ENV{TEST_NGINX_SERVER_PORT} = $ServerPort;
    }

    for my $block ($NoShuffle ? Test::Base::blocks() : shuffle Test::Base::blocks()) {
        for my $hdl (@BlockPreprocessors) {
            $hdl->($block);
        }

        $block->set_value("name", $0 . " " . $block->name);
        run_test($block);

        $PrevBlock = $block;
    }

    cleanup();
}

sub setup_server_root ($) {
    my $first_time = shift;

    if (-d $ServRoot) {
        # Take special care, so we won't accidentally remove
        # real user data when TEST_NGINX_SERVROOT is mis-used.
        remove_tree($ConfDir, glob("$ServRoot/*_cache"),
                    glob("$ServRoot/*_temp"));

        if ($UseHup) {
            find({ bydepth => 1, no_chdir => 1, wanted => sub {
                if (! -d $_) {
                    if ($_ =~ /(?:\bnginx\.pid|\.sock|\.crt|\.key)$/) {
                        return unless $first_time;
                    }

                    #warn "removing file $_";
                    system("rm $_") == 0 or warn "Failed to remove $_\n";
                }

            }}, $ServRoot);

        } else {
            remove_tree($HtmlDir, $LogDir);
            rmdir $ServRoot or
                bail_out "Can't remove $ServRoot (not empty?): $!";
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
    if (!-d $HtmlDir) {
        mkdir $HtmlDir or
            bail_out "Failed to do mkdir $HtmlDir\n";
    }

    my $index_file = "$HtmlDir/index.html";

    open my $out, ">$index_file" or
        bail_out "Can't open $index_file for writing: $!\n";

    print $out '<html><head><title>It works!</title></head><body>It works!</body></html>';

    close $out;

    mkdir $ConfDir or
        bail_out "Failed to do mkdir $ConfDir\n";
}

sub write_user_files ($$) {
    my ($block, $rand_ports) = @_;

    my $name = $block->name;

    my $files = $block->user_files;
    if ($files) {
        if (!ref $files) {
            my $raw = $files;

            open my $in, '<', \$raw;

            $files = [];
            my ($fname, $body, $date);
            while (<$in>) {
                if (/>>> (\S+)(?:\s+(.+))?/) {
                    if ($fname) {
                        push @$files, [$fname, $body, $date];
                    }

                    $fname = $1;
                    $date = $2;
                    undef $body;
                } else {
                    $body .= $_;
                }
            }

            if ($fname) {
                push @$files, [$fname, $body, $date];
            }

        } elsif (ref $files ne 'ARRAY') {
            bail_out "$name - wrong value type: ", ref $files,
                     ", only scalar or ARRAY are accepted";
        }

        for my $file (@$files) {
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

            $body = expand_env_in_text($body, $name, $rand_ports);

            open my $out, ">$path" or
                bail_out "$name - Cannot open $path for writing: $!\n";
            binmode $out;
            #warn "write file $path with data len ", length $body;
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
    my ($block, $config, $rand_ports) = @_;

    my $name = $block->name;
    my $http_config = $block->http_config;
    my $main_config = $block->main_config;
    my $post_main_config = $block->post_main_config;
    my $err_log_file = $block->error_log_file;
    my $server_name = $block->server_name;

    if ($UseHup) {
        master_on(); # config reload is buggy when master is off

    } elsif ($UseValgrind) {
        #master_off();

    } elsif ($UseStap && defined $block->stap) {
        master_off();
    }

    $http_config = expand_env_in_text($http_config, $name, $rand_ports);

    if (!defined $config) {
        $config = '';
    }

    if (!defined $http_config) {
        $http_config = '';
    }

    if ($FilterHttpConfig) {
        $http_config = $FilterHttpConfig->($http_config)
    }

    if ($http_config =~ /\bpostpone_output\b/) {
        undef $PostponeOutput;
    }

    my $extra_http_config = '';

    if (defined $PostponeOutput) {
        if ($PostponeOutput !~ /^\d+$/) {
            bail_out "Bad TEST_NGINX_POSTPONE_OUTPUT value: $PostponeOutput\n";
        }
        $extra_http_config .= "\n    postpone_output $PostponeOutput;\n";
    }

    if (!defined $main_config) {
        $main_config = '';
    }

    if ($LoadModules) {
        my @modules = map { "load_module $_;" } grep { $_ } split /\s+/, $LoadModules;
        if (@modules) {
            $main_config .= join " ", @modules;
        }
    }

    $main_config = expand_env_in_text($main_config, $name, $rand_ports);

    if (!defined $post_main_config) {
        $post_main_config = '';
    }

    $post_main_config = expand_env_in_text($post_main_config, $name, $rand_ports);

    if ($CheckLeak || $Benchmark) {
        $LogLevel = 'warn';
        $AccLogFile = 'off';
    }

    if (!$err_log_file) {
        $err_log_file = $ErrLogFile;
    }

    if (!defined $server_name) {
        $server_name = $ServerName;
    }

    (my $quoted_server_name = $server_name) =~ s/\\/\\\\/g;
    $quoted_server_name =~ s/'/\\'/g;

    open my $out, ">$ConfFile" or
        bail_out "Can't open $ConfFile for writing: $!\n";
    print $out <<_EOC_;
worker_processes  $Workers;
daemon $DaemonEnabled;
master_process $MasterProcessEnabled;
error_log $err_log_file $LogLevel;
pid       $PidFile;
env MOCKEAGAIN_VERBOSE;
env MOCKEAGAIN;
env MOCKEAGAIN_WRITE_TIMEOUT_PATTERN;
env LD_PRELOAD;
env LD_LIBRARY_PATH;
env DYLD_INSERT_LIBRARIES;
env DYLD_FORCE_FLAT_NAMESPACE;
_EOC_

    for my $v (@EnvToNginx) {
        if ($v =~ /\s/) {
            $v = "'$v'";
        }
        print $out "env $v;\n";
    }

    my $listen_opts = '';

    $ServerConfigHttp3 = '';
    if (use_http3($block)) {
        if ($UseHttp3 && !defined $block->http3) {
            $ServerConfigHttp3 = "\n        ssl_protocols TLSv1.3;\n";

            if (defined $Http3SSLCrt) {
                $ServerConfigHttp3 .= "        ssl_certificate $Http3SSLCrt;\n";
            }

            if (defined $Http3SSLCrtKey) {
                $ServerConfigHttp3 .= "        ssl_certificate_key $Http3SSLCrtKey;\n";
            }
        }

    } elsif (use_http2($block)) {
        $listen_opts .= " http2";
    }

    if ($ReusePort) {
        $listen_opts .= " reuseport";
    }

    print $out <<_EOC_;
#env LUA_PATH;
#env LUA_CPATH;

$main_config

http {
    access_log $AccLogFile;
    #access_log off;

    default_type text/plain;
    keepalive_timeout  68;

$http_config

    server {
        listen          $ServerPort$listen_opts;
_EOC_

    # when using http3, wo both listen on tcp for http and udp for http3
    if (use_http3($block)) {
        my $quic_max_idle_timeout = ${QuicIdleTimeout};
        if ($block->quic_max_idle_timeout) {
            $quic_max_idle_timeout = $block->quic_max_idle_timeout;
        }

        $quic_max_idle_timeout = int($quic_max_idle_timeout * 1000);

        my $h3_listen_opts = $listen_opts;
        if ($h3_listen_opts !~ /\breuseport\b/) {
            $h3_listen_opts .= " reuseport";
        }

        print $out <<_EOC_;
        listen          $ServerPort$h3_listen_opts http3;
        quic_max_idle_timeout ${quic_max_idle_timeout}ms;
_EOC_
    }

    print $out <<_EOC_;
        server_name     '$server_name';

        client_max_body_size 30M;
        #client_body_buffer_size 4k;
$ServerConfigHttp3

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
        listen          $ServerPort$listen_opts;
        server_name     'Test-Nginx';

        location = /ver {
            return 200 '$ConfigVersion';
        }
    }

$extra_http_config
_EOC_
    }

    print $out <<_EOC_;
}

$post_main_config

#timer_resolution 100ms;

events {
    accept_mutex off;

    worker_connections  $WorkerConnections;
_EOC_

    if ($EventType) {
        print $out <<_EOC_;
    use $EventType;
_EOC_
    }

    print $out "}\n";

    print $out <<_EOC_;
env ASAN_OPTIONS;
env MOCKNOEAGAIN_VERBOSE;
env MOCKNOEAGAIN;
_EOC_

    if (defined $WorkerUser) {
        print $out "user $WorkerUser;\n";

    } elsif ($> == 0) {  # being root
        print $out "user root;\n";
    }

    close $out;
}

sub get_canon_version (@) {
    sprintf "%d.%03d%03d", $_[0], $_[1], $_[2];
}

sub get_canon_version_for_OpenSSL (@) {
    if (defined $_[3]) {
        return sprintf "%d.%03d%03d%03d", $_[0], $_[1], $_[2], ord($_[3]) - ord('a');
    }

    get_canon_version @_;
}

sub get_nginx_version () {
    my $out = `$NginxBinary -V 2>&1`;
    if (!defined $out || $? != 0) {
        $out //= "";
        bail_out("Failed to get the version of the Nginx in PATH: $out");
    }

    if ($out =~ m{built with OpenSSL (\d+)\.(\d+)\.(\d+)([a-z])?}s) {
        $OpenSSLVersion = get_canon_version_for_OpenSSL($1, $2, $3, $4);
    }

    if ($out =~ m{(?:nginx|openresty)[^/]*/(\d+)\.(\d+)\.(\d+)}s) {
        $NginxRawVersion = "$1.$2.$3";
        return get_canon_version($1, $2, $3);
    }

    if ($out =~ m{\w+/(\d+)\.(\d+)\.(\d+)}s) {
        $NginxRawVersion = "$1.$2.$3";
        return get_canon_version($1, $2, $3);
    }

    bail_out("Failed to parse the output of \"nginx -V\": $out\n");
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

sub test_config_version ($$) {
    my ($name, $block) = @_;
    my $total = 200;
    my $sleep = sleep_time();
    my $nsucc = 0;

    #$ConfigVersion = '322';

    for (my $tries = 1; $tries <= $total; $tries++) {

        my $extra_curl_opts = '';
        my $http_protocol = "http";

        if (use_http2($block)) {
            $extra_curl_opts .= ' --http2 --http2-prior-knowledge';
        }

        if (use_http3($block)) {
            #$extra_curl_opts .= ' --http3';
            #$http_protocol = "https";
            #server Test-Nginx only listen on http when http3 is enabled
        }

        my $cmd = "curl$extra_curl_opts -sS -H 'Host: Test-Nginx' --connect-timeout 2 '$http_protocol://$ServerAddr:$ServerPort/ver'";
        #warn $cmd;
        my $ver = `$cmd`;
        #chop $ver;

        if ($Verbose) {
            warn "$name - ConfigVersion: $ver == $ConfigVersion\n";
        }

        if ($ver eq $ConfigVersion) {
            $nsucc++;

            if ($nsucc == 5) {
                sleep $sleep;
            }

            if ($nsucc >= 20) {
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

    Test::More::fail("$name - failed to reload configuration after $total "
                     . "failed test requests");
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

sub expand_env_in_text ($$$) {
    my ($text, $name, $rand_ports) = @_;

    if (!defined $text) {
        return;
    }

    my $used_ports = {
        $ServerPort => 1,
        map { $_ => 1 } values %$rand_ports
    };

    $text =~ s/\$(TEST_NGINX_[_A-Z0-9]+)/
        my $expanded_env;

        if ($1 =~ m{^(TEST_NGINX_RAND_PORT_[0-9]+)$}) {
            if (!defined $rand_ports->{$1}) {
                my $rand_port = gen_rand_port 1000, $used_ports;

                if (!defined $rand_port) {
                    bail_out "$name - Cannot find an available listening port number for $1.\n";
                }

                $rand_ports->{$1} = $rand_port;
                $used_ports->{$rand_port} = 1;
                $expanded_env = $rand_port;

            } else {
                $expanded_env = $rand_ports->{$1};
            }
        } else {
            if (!defined $ENV{$1}) {
                bail_out "$name - No environment $1 defined.\n";
            }
            $expanded_env = $ENV{$1};
        }
        $expanded_env;
    /eg;

    $text;
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

sub run_tcp_server_tests ($$$) {
    my ($block, $tcp_socket, $tcp_query_file) = @_;

    my $name = $block->name;

    if (defined $tcp_socket) {
        my $buf = '';
        if ($tcp_query_file) {
            if (open my $in, $tcp_query_file) {
                $buf = do { local $/; <$in> };
                close $in;
            }
        }

        if (defined $block->tcp_query) {
            is_str($buf, $block->tcp_query, "$name - tcp_query ok");
        }

        if (defined $block->tcp_query_len) {
            Test::More::is(length($buf), $block->tcp_query_len, "$name - TCP query length ok");
        }
    }
}

sub run_udp_server_tests ($$$) {
    my ($block, $udp_socket, $udp_query_file) = @_;

    my $name = $block->name;

    if (defined $udp_socket) {
        my $buf = '';
        if ($udp_query_file) {
            if (!open my $in, $udp_query_file) {
                warn "WARNING: cannot open udp query file $udp_query_file for reading: $!\n";

            } else {
                $buf = do { local $/; <$in> };
                close $in;
            }
        }

        if (defined $block->udp_query) {
            is_str($buf, $block->udp_query, "$name - udp_query ok");
        }
    }
}

sub run_test ($) {
    my $block = shift;

    return if defined $block->SKIP;

    my $name = $block->name;

    my $first_time;
    if ($FirstTime) {
        $first_time = 1;
        undef $FirstTime;
    }

    my $rand_ports = {};

    my $config = $block->config;

    $config = expand_env_in_text($config, $name, $rand_ports);

    my $dry_run = 0;
    my $should_restart = 1;
    my $should_reconfig = 1;

    local $StapOutFile = $StapOutFile;

    #warn "run test\n";
    local $LogLevel = $LogLevel;
    if ($block->log_level) {
        $LogLevel = $block->log_level;
    }

    my $must_die;
    local $UseStap = $UseStap;
    local $UseValgrind = $UseValgrind;
    local $UseHup = $UseHup;
    local $Profiling = $Profiling;

    if (defined $block->must_die) {
        $must_die = $block->must_die;
        if (defined $block->stap) {
            bail_out("$name: --- stap cannot be used with --- must_die");
        }

        if ($UseStap) {
            undef $UseStap;
        }

        if ($UseValgrind) {
            undef $UseValgrind;
        }

        if ($UseHup) {
            undef $UseHup;
        }

        if ($Profiling) {
            undef $Profiling;
        }
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
    my $skip_openssl = $block->skip_openssl;
    my $skip_eval = $block->skip_eval;
    my $skip_slave = $block->skip_slave;
    my ($tests_to_skip, $should_skip, $skip_reason);

    if (defined $block->reload_fails || defined $block->http2) {
        $block->set_value("no_check_leak", 1);
    }

    if (($CheckLeak || $Benchmark) && defined $block->no_check_leak) {
        $should_skip = 1;
    }

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
            if (!$skip_reason) {
                $skip_reason = "nginx version $op $ver1.$ver2.$ver3";
            }
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

    if (defined $skip_openssl) {
        if ($skip_openssl =~ m{
                ^ \s* (\d+) \s* : \s*
                    ([<>]=?) \s* (\d+)\.(\d+)\.(\d+)([a-z])?
                    (?: \s* : \s* (.*) )?
                \s*$}x) {
            $tests_to_skip = $1;
            my ($op, $ver1, $ver2, $ver3, $ver4) = ($2, $3, $4, $5, $6);
            $skip_reason = $7;
            if (!$skip_reason) {
                if (!defined $OpenSSLVersion) {
                    $skip_reason = "Not built with OpenSSL";

                } elsif (defined $ver4) {
                    $skip_reason = "OpenSSL version $op $ver1.$ver2.$ver3$ver4";

                } else {
                    $skip_reason = "OpenSSL version $op $ver1.$ver2.$ver3";
                }
            }

            my $ver = get_canon_version_for_OpenSSL($ver1, $ver2, $ver3, $ver4);
            if (!defined $OpenSSLVersion or eval "$OpenSSLVersion $op $ver") {
                $should_skip = 1;
            }

        } else {
            bail_out("$name - Invalid --- skip_openssl spec: " .
                $skip_openssl);
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

    my $todo = $block->todo;
    if (defined $todo) {
        if ($todo =~ m{
                ^ \s* (\d+) \s* : \s* (.*)
            }xs)
        {
            $should_todo = 1;
            $tests_to_skip = $1;
            $todo_reason = $2;
        } else {
            bail_out("$name - Invalid --- todo spec: " .
                $todo);
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
                    if ($first_time) {
                        kill_process($pid, 1, $name);

                        undef $nginx_is_running;
                        goto start_nginx;
                    }

                    setup_server_root($first_time);
                    write_user_files($block, $rand_ports);
                    write_config_file($block, $config, $rand_ports);

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

                            # wait for http3 connections to timeout
                            # so older nginx can exit
                            if (use_http3($block)) {
                                my $idle_time = $QuicIdleTimeout;
                                if ($block->quic_max_idle_timeout) {
                                    $idle_time = $block->quic_max_idle_timeout;
                                }

                                sleep (0.1 + $idle_time);
                            }

                            if ($Verbose) {
                                warn "skip starting nginx from scratch\n";
                            }

                            $nginx_is_running = 1;

                            if ($UseValgrind) {
                                warn "$name\n";
                            }

                            if (defined $block->reload_fails) {
                                sleep 0.3;

                            } else {
                                test_config_version($name, $block);
                            }

                            check_prev_block_shutdown_error_log();

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

                kill_process($pid, 1, $name);

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

        check_prev_block_shutdown_error_log();

        unless ($nginx_is_running) {
            if ($Verbose) {
                warn "starting nginx from scratch\n";
            }

            #system("killall -9 nginx");

            #warn "*** Restarting the nginx server...\n";
            setup_server_root($first_time);
            write_user_files($block, $rand_ports);
            write_config_file($block, $config, $rand_ports);
            #warn "nginx binary: $NginxBinary";
            if (!can_run($NginxBinary)) {
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

            if ($UseRr) {
                $cmd = "rr record $cmd";
            }

            if ($UseValgrind) {
                my $opts;

                if ($UseValgrind =~ /^\d+$/) {
                    $opts = "--tool=memcheck --leak-check=full --show-possibly-lost=no";

                    if (-f 'valgrind.suppress') {
                        $cmd = "valgrind --num-callers=100 -q $opts --gen-suppressions=all --suppressions=valgrind.suppress $cmd";
                    } else {
                        $cmd = "valgrind --num-callers=100 -q $opts --gen-suppressions=all $cmd";
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
                    my ($stap_fh, $stap_fname) = tempfile("XXXXXXX",
                                                          SUFFIX => '.stp',
                                                          TMPDIR => 1,
                                                          UNLINK => 1);
                    my $stap = $block->stap;

                    if ($stap =~ /\$LIB([_A-Z0-9]+)_PATH\b/) {
                        my $name = $1;
                        my $libname = 'lib' . lc($name);
                        my $nginx_path = can_run($NginxBinary);
                        #warn "nginx path: ", $nginx_path;
                        my $line = `ldd $nginx_path|grep -E '$libname.*?\.so'`;
                        #warn "line: $line";
                        my $liblua_path;
                        if ($line =~ m{\S+/$libname.*?\.so(?:\.\d+)*}) {
                            $liblua_path = $&;

                        } else {
                            # static linking is used?
                            $liblua_path = $nginx_path;
                        }

                        $stap =~ s/\$LIB${name}_PATH\b/$liblua_path/gi;
                    }

                    $stap =~ s/^\bS\(([^)]+)\)/probe process("nginx").statement("*\@$1")/smg;
                    $stap =~ s/^\bF\(([^\)]+)\)/probe process("nginx").function("$1")/smg;
                    $stap =~ s/^\bM\(([-\w]+)\)/probe process("nginx").mark("$1")/smg;
                    $stap =~ s/\bT\(\)/println("Fire ", pp())/smg;
                    print $stap_fh $stap;
                    close $stap_fh;

                    my ($out, $outfile);

                    if (!defined $block->stap_out
                        && !defined $block->stap_out_like
                        && !defined $block->stap_out_unlike)
                    {
                        $StapOutFile = "/dev/stderr";
                    }

                    if (!$StapOutFile) {
                        ($out, $outfile) = tempfile("XXXXXXXX",
                                                    SUFFIX => '.stp-out',
                                                    TMPDIR => 1,
                                                    UNLINK => 1);
                        close $out;

                        $StapOutFile = $outfile;

                    } else {
                        $outfile = $StapOutFile;
                    }

                    open $out, $outfile or
                        bail_out("Cannot open $outfile for reading: $!\n");

                    $StapOutFileHandle = $out;
                    $cmd = "exec $cmd";

                    if (defined $ENV{LD_PRELOAD}) {
                        $cmd = qq!LD_PRELOAD="$ENV{LD_PRELOAD}" $cmd!;
                    }

                    if (defined $ENV{LD_LIBRARY_PATH}) {
                        $cmd = qq!LD_LIBRARY_PATH="$ENV{LD_LIBRARY_PATH}" $cmd!;
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

                    setpgrp;
                    my $tb = Test::More->builder;
                    $tb->no_ending(1);

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
                my $i = 0;
                $ErrLogFilePos = 0;
                my ($exec_failed, $coredump, $exit_code);
                my $waited = 0;

RUN_AGAIN:

                #warn "CMD: $cmd";
                system($cmd);

                my $status = $?;

                if ($status == -1) {
                    $exec_failed = 1;

                } else {
                    $exit_code = $status >> 8;

                    if ($? > (128 << 8)) {
                        $coredump = ($exit_code & 128);
                        $exit_code = ($exit_code >> 8);

                    } else {
                        $coredump = ($status & 128);
                    }
                }

                if (defined $must_die) {
                    # Always should be able to execute
                    if ($exec_failed) {
                        Test::More::fail("$name - failed to execute the nginx command line")

                    } elsif ($coredump) {
                        Test::More::fail("$name - nginx core dumped")

                    } elsif (looks_like_number($must_die)) {
                        Test::More::is($must_die, $exit_code,
                                       "$name - die with the expected exit code")

                    } else {
                        Test::More::isnt($status, 0, "$name - die as expected")
                    }

                    $CheckErrorLog->($block, undef, $dry_run, $i, 0);

                    #warn "Status: $status\n";
                    if ($status == 0) {
                        warn("WARNING: $name - nginx must die but it does ",
                             "not; killing it (req $i)");
                        my $tries = 15;
                        for (my $i = 1; $i <= $tries; $i++) {
                            if (-f $PidFile) {
                                last;
                            }
                            sleep $TestNginxSleep;
                        }
                        my $pid = get_pid_from_pidfile($name);
                        kill_process($pid, 1, $name);
                    }

                    goto RUN_AGAIN if ++$i < $RepeatEach;
                    return;
                }

                if ($status != 0) {
                    if ($ENV{TEST_NGINX_IGNORE_MISSING_DIRECTIVES} and
                            my $directive = check_if_missing_directives())
                    {
                        $dry_run = "the lack of directive $directive";

                    } else {
                        $i++;
                        my $delay = 0.1 * $i;
                        if ($delay > 1) {
                            $delay = 1;
                        }
                        sleep $delay;
                        $waited += $delay;
                        goto RUN_AGAIN if $waited < 30;
                        bail_out("$name - Cannot start nginx using command \"$cmd\" (status code $status).");
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
    $ErrLogFilePos = 0;
    while ($i++ < $RepeatEach) {
        #warn "Use hup: $UseHup, i: $i\n";

        if ($Verbose) {
            warn "Run the test block...\n";
        }

        if (($CheckLeak || $Benchmark) && defined $block->tcp_listen) {

            my $n = defined($block->tcp_query_len) ? 1 : 0;
            $n += defined($block->tcp_query) ? 1 : 0;

            if ($n) {
                SKIP: {
                    Test::More::skip(qq{$name -- tests skipped because embedded TCP }
                        .qq{server does not work with the "check leak" mode}, $n);
                }
            }
        }

        my ($tcp_socket, $tcp_query_file);
        if (!($CheckLeak || $Benchmark) && defined $block->tcp_listen) {

            my $target = $block->tcp_listen;

            my $reply = $block->tcp_reply;
            if (!defined $reply && !defined $block->tcp_shutdown) {
                bail_out("$name - no --- tcp_reply specified but --- tcp_listen is specified");
            }

            my $req_len = $block->tcp_query_len;

            if (defined $block->tcp_query || defined $req_len) {
                if (!defined $req_len) {
                    $req_len = length($block->tcp_query);
                }
                $tcp_query_file = tmpnam();
            }

            #warn "Reply: ", $reply;

            my $err;
            for (my $i = 0; $i < 30; $i++) {
                if ($target =~ /^\d+$/) {
                    $tcp_socket = IO::Socket::INET->new(
                        LocalHost => '127.0.0.1',
                        LocalPort => $target,
                        Proto => 'tcp',
                        Reuse => 1,
                        Listen => 5,
                        Timeout => timeout(),
                    );
                } elsif ($target =~ m{\S+\.sock$}) {
                    if (-e $target) {
                        unlink $target or die "cannot remove $target: $!";
                    }

                    $tcp_socket = IO::Socket::UNIX->new(
                        Local => $target,
                        Type  => SOCK_STREAM,
                        Listen => 5,
                        Timeout => timeout(),
                    );
                } else {
                    bail_out("$name - bad tcp_listen target: $target");
                }

                if ($tcp_socket) {
                    last;
                }

                if ($!) {
                    $err = $!;
                    if ($err =~ /address already in use/i) {
                        warn "WARNING: failed to create the tcp listening socket: $err\n";
                        if ($i >= 20) {
                            my $pids = `fuser -n tcp $target`;
                            if ($pids) {
                                $pids =~ s/^\s+|\s+$//g;
                                my @pids = split /\s+/, $pids;
                                for my $pid (@pids) {
                                    if ($pid == $$) {
                                        warn "WARNING: Test::Nginx leaks mocked TCP sockets on target $target\n";
                                        next;
                                    }

                                    warn "WARNING: killing process $pid listening on target $target.\n";
                                    kill_process($pid, 1, $name);
                                }
                            }
                        }
                        sleep 1;
                        next;
                    }
                }

                last;
            }

            if (!$tcp_socket && $err) {
                bail_out("$name - failed to create the tcp listening socket: $err");
            }

            my $pid = fork();

            if (!defined $pid) {
                bail_out("$name - fork() failed: $!");

            } elsif ($pid == 0) {
                # child process

                my $tb = Test::More->builder;
                $tb->no_ending(1);

                #my $rc = system($cmd);

                $InSubprocess = 1;

                if ($Verbose) {
                    warn "TCP server is listening on $target ...\n";
                }

                local $| = 1;

                my $client;

                while (1) {
                    $client = $tcp_socket->accept();
                    last if $client;
                    warn("WARNING: $name - TCP server: failed to accept: $!\n");
                    sleep $TestNginxSleep;
                }

                my ($no_read, $no_write);
                if (defined $block->tcp_shutdown) {
                    my $shutdown = $block->tcp_shutdown;
                    if ($block->tcp_shutdown_delay) {
                        sleep $block->tcp_shutdown_delay;
                    }
                    $client->shutdown($shutdown);
                    if ($shutdown == 0 || $shutdown == 2) {
                        if ($Verbose) {
                            warn "tcp server shutdown the read part.\n";
                        }
                        $no_read = 1;

                    } else {
                        if ($Verbose) {
                            warn "tcp server shutdown the write part.\n";
                        }
                        $no_write = 1;
                    }
                }

                my $buf;

                unless ($no_read) {
                    if ($Verbose) {
                        warn "TCP server reading request...\n";
                    }

                    while (1) {
                        my $b;
                        my $ret = $client->recv($b, 4096);
                        if (!defined $ret) {
                            die "failed to receive: $!\n";
                        }

                        if ($Verbose) {
                            #warn "TCP server read data: [", $b, "]\n";
                        }

                        $buf .= $b;


                        # flush read data to the file as soon as possible:

                        if ($tcp_query_file) {
                            open my $out, ">$tcp_query_file"
                                or die "cannot open $tcp_query_file for writing: $!\n";

                            if ($Verbose) {
                                warn "writing received data [$buf] to file $tcp_query_file\n";
                            }

                            print $out $buf;
                            close $out;
                        }

                        if (!$req_len || length($buf) >= $req_len) {
                            if ($Verbose) {
                                warn "len: ", length($buf), ", req len: $req_len\n";
                            }
                            last;
                        }
                    }
                }

                my $delay = parse_time($block->tcp_reply_delay);
                if ($delay) {
                    if ($Verbose) {
                        warn "sleep $delay before sending TCP reply\n";
                    }
                    sleep $delay;
                }

                unless ($no_write) {
                    if (defined $reply) {
                        if ($Verbose) {
                            warn "TCP server writing reply...\n";
                        }

                        my $ref = ref $reply;
                        if ($ref && $ref eq 'CODE') {
                            $reply = $reply->($buf);
                            $ref = ref $reply;
                        }

                        if (ref $reply) {
                            if ($ref ne 'ARRAY') {
                                bail_out('bad --- tcp_reply value');
                            }

                            for my $r (@$reply) {
                                if ($Verbose) {
                                    warn "sending reply $r";
                                }
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

        if (($CheckLeak || $Benchmark) && defined $block->udp_listen) {

            my $n = defined($block->udp_query) ? 1 : 0;

            if ($n) {
                SKIP: {
                    Test::More::skip(qq{$name -- tests skipped because embedded UDP }
                        .qq{server does not work with the "check leak" mode}, $n);
                }
            }
        }

        my ($udp_socket, $uds_socket_file, $udp_query_file);
        if (!($CheckLeak || $Benchmark) && defined $block->udp_listen) {
            my $reply = $block->udp_reply;
            if (!defined $reply) {
                bail_out("$name - no --- udp_reply specified but --- udp_listen is specified");
            }

            if (defined $block->udp_query) {
                $udp_query_file = tmpnam();
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

            my $pid = fork();

            if (!defined $pid) {
                bail_out("$name - fork() failed: $!");

            } elsif ($pid == 0) {
                # child process

                my $tb = Test::More->builder;
                $tb->no_ending(1);

                #my $rc = system($cmd);

                $InSubprocess = 1;

                if ($Verbose) {
                    warn "UDP server is listening on $target ...\n";
                }

                local $| = 1;

                if ($Verbose) {
                    warn "UDP server reading data...\n";
                }

                my $buf = '';
                my $sender = $udp_socket->recv($buf, 4096);
                #warn "sender: $sender";
                if (!defined $sender) {
                    warn "udp recv failed: $!";
                }

                if ($Verbose) {
                    warn "UDP server has got data: ", length $buf, "\n";
                }

                if ($udp_query_file) {
                    open my $out, ">$udp_query_file"
                        or die "cannot open $udp_query_file for writing: $!\n";

                    if ($Verbose) {
                        warn "writing received data [$buf] to file $udp_query_file\n";
                    }

                    print $out $buf;
                    close $out;
                }

                my $delay = parse_time($block->udp_reply_delay);
                if ($delay) {
                    if ($Verbose) {
                        warn "$name - sleep $delay before sending UDP reply\n";
                    }
                    sleep $delay;
                }

                if (defined $reply) {
                    my $ref = ref $reply;
                    if ($ref && $ref eq 'CODE') {
                        $reply = $reply->($buf);
                        $ref = ref $reply;
                    }

                    if ($ref) {
                        if ($ref ne 'ARRAY') {
                            warn("$name - Bad --- udp_reply value");
                        }

                        for my $r (@$reply) {
                            #warn "sending reply $r";
                            my $bytes = $udp_socket->send($r);
                            if (!defined $bytes) {
                                warn "$name - WARNING: udp server failed to send reply: $!\n";
                            }
                        }

                    } else {
                        if ($reply =~ /syntax error at \(eval \d+\) line \d+, near/) {
                            bail_out("$name - Bad --- udp_reply: $reply");
                        }

                        my $bytes = $udp_socket->send($reply);
                        if (!defined $bytes) {
                            warn "$name - WARNING: udp server failed to send reply: $!\n";
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
            write_user_files($block, $rand_ports);
        }

        if ($should_skip && defined $tests_to_skip) {
            SKIP: {
                Test::More::skip("$name - $skip_reason", $tests_to_skip);

                $RunTestHelper->($block, $dry_run, $i - 1);
                run_tcp_server_tests($block, $tcp_socket, $tcp_query_file);
                run_udp_server_tests($block, $udp_socket, $udp_query_file);
            }

        } elsif ($should_todo) {
            TODO: {
                Test::More::todo_skip("$name - $todo_reason", $tests_to_skip);

                $RunTestHelper->($block, $dry_run, $i - 1);
                run_tcp_server_tests($block, $tcp_socket, $tcp_query_file);
                run_udp_server_tests($block, $udp_socket, $udp_query_file);
            }

        } else {
            $RunTestHelper->($block, $dry_run, $i - 1);
            run_tcp_server_tests($block, $tcp_socket, $tcp_query_file);
            run_udp_server_tests($block, $udp_socket, $udp_query_file);
        }

        if (defined $udp_socket) {
            if (defined $UdpServerPid) {
                kill_process($UdpServerPid, 1, $name);
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
                kill_process($TcpServerPid, 1, $name);
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
                write_config_file($block, $config, $rand_ports);

                if ($Verbose) {
                    warn "sending QUIT signal to $pid";
                }

                if (kill(SIGQUIT, $pid) == 0) { # send quit signal
                    warn("$name - Failed to send quit signal to the nginx process with PID $pid");
                }

                sleep $TestNginxSleep;

                if (-f $PidFile) {
                    if ($i++ < 20) {
                        if ($Verbose) {
                            warn "nginx not quitted, retrying...\n";
                        }

                        goto retry;
                    }

                    if ($Verbose) {
                        warn "sending KILL signal to $pid";
                    }

                    # kill process group, including children
                    kill(SIGKILL, -$pid);
                    waitpid($pid, 0);

                    if (!unlink($PidFile) && -f $PidFile) {
                        bail_out "Failed to remove pid file $PidFile: $!\n";
                    }

                } else {
                    #warn "nginx killed";
                }

            } else {
                if (!unlink($PidFile) && -f $PidFile) {
                    bail_out "Failed to remove pid file $PidFile: $!\n";
                }
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
        if (defined $PidFile && -f $PidFile) {
            my $pid = get_pid_from_pidfile('');
            if (!$pid) {
                bail_out "No pid found.";
            }
            if (is_running($pid)) {
                kill_process($pid, 1, "END");

            } else {
                unlink $PidFile;
            }
        }
    }

    check_prev_block_shutdown_error_log();

    if ($Randomize) {
        if (defined $ServRoot && -d $ServRoot && $ServRoot =~ m{/t/servroot_\d+}) {
            system("rm -rf $ServRoot");
        }
    }
}

# check if we can run some command
sub can_run {
    my ($cmd) = @_;

    #warn "can run: $cmd\n";
    if ($cmd =~ m{[/\\]}) {
       if (-f $cmd && -x $cmd) {
           return $cmd;
        }

        return undef;
    }

    for my $dir ((split /$Config::Config{path_sep}/, $ENV{PATH}), '.') {
        next if $dir eq '';
        my $abs = File::Spec->catfile($dir, $cmd);
        #warn $abs;
        return $abs if -f $abs && -x $abs;
    }

    return undef;
}

sub use_http2 ($) {
    my $block = shift;

    my $cached = $block->test_nginx_enabled_http2;
    if (defined $cached) {
        return $cached;
    }

    if (defined $block->http2) {
        if ($block->raw_request) {
            bail_out("cannot use --- http2 with --- raw_request");
        }

        if ($block->pipelined_requests) {
            bail_out("cannot use --- http2 with --- pipelined_requests");
        }

        $block->set_value("test_nginx_enabled_http2", 1);

        if (!$LoadedIPCRun) {
            require IPC::Run;
            $LoadedIPCRun = 1;
        }
        return 1;
    }

    if ($UseHttp2) {
        if ($block->raw_request) {
            warn "WARNING: ", $block->name, " - using raw_request HTTP/2, will not use HTTP/2\n";
            $block->set_value("test_nginx_enabled_http2", 0);
            return undef;
        }

        if ($block->pipelined_requests) {
            warn "WARNING: ", $block->name, " - using pipelined_requests, will not use HTTP/2\n";
            $block->set_value("test_nginx_enabled_http2", 0);
            return undef;
        }

        if (!defined $block->request) {
            $block->set_value("test_nginx_enabled_http2", 0);
            return undef;
        }

        if (!ref $block->request && $block->request =~ m{HTTP/1\.0}s) {
            warn "WARNING: ", $block->name, " - explicitly rquires HTTP 1.0, so will not use HTTP/2\n";
            $block->set_value("test_nginx_enabled_http2", 0);
            return undef;
        }

        if (defined $block->http3) {
            warn "WARNING: ", $block->name, " - explicitly requires HTTP/3, so will not use HTTP/2\n";
            $block->set_value("test_nginx_enabled_http2", 0);
            return undef;
        }

        $block->set_value("test_nginx_enabled_http2", 1);

        if (!$LoadedIPCRun) {
            require IPC::Run;
            $LoadedIPCRun = 1;
        }

        return 1;
    }

    $block->set_value("test_nginx_enabled_http2", 0);
    return undef;
}


sub use_http3 ($) {
    my $block = shift;
    my $cached = $block->test_nginx_enabled_http3;

    if (defined $cached) {
        return $cached;
    }

    if (defined $block->http3) {
        if ($block->raw_request) {
            bail_out("cannot use --- http3 with --- raw_request");
        }

        if ($block->pipelined_requests) {
            bail_out("cannot use --- http3 with --- pipelined_requests");
        }

        if (defined $block->http2) {
            bail_out("cannot use --- http3 with --- http2");
        }

        $block->set_value("test_nginx_enabled_http3", 1);

        if (!$LoadedIPCRun) {
            require IPC::Run;
            $LoadedIPCRun = 1;
        }

        return 1;
    }

    if ($UseHttp3) {
        if ($block->raw_request) {
            warn "WARNING: ", $block->name, " - using raw_request HTTP/2, will not use HTTP/3\n";
            $block->set_value("test_nginx_enabled_http3", 0);
            return undef;
        }

        if ($block->pipelined_requests) {
            warn "WARNING: ", $block->name, " - using pipelined_requests, will not use HTTP/3\n";
            $block->set_value("test_nginx_enabled_http3", 0);
            return undef;
        }

        if (!defined $block->request) {
            $block->set_value("test_nginx_enabled_http3", 0);
            return undef;
        }

        if (!ref $block->request && $block->request =~ m{HTTP/1\.0}s) {
            warn "WARNING: ", $block->name, " - explicitly requires HTTP 1.0, so will not use HTTP/3\n";
            $block->set_value("test_nginx_enabled_http3", 0);
            return undef;
        }

        if (defined $block->http2) {
            warn "WARNING: ", $block->name, " - explicitly requires HTTP/2, so will not use HTTP/3\n";
            $block->set_value("test_nginx_enabled_http3", 0);
            return undef;
        }

        $block->set_value("test_nginx_enabled_http3", 1);

        if (!$LoadedIPCRun) {
            require IPC::Run;
            $LoadedIPCRun = 1;
        }
        return 1;
    }

    $block->set_value("test_nginx_enabled_http3", 0);
    return undef;
}

1;
