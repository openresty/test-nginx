#line 1
package Test::Builder;

use 5.006;
use strict;
use warnings;

our $VERSION = '1.302171';

BEGIN {
    if( $] < 5.008 ) {
        require Test::Builder::IO::Scalar;
    }
}

use Scalar::Util qw/blessed reftype weaken/;

use Test2::Util qw/USE_THREADS try get_tid/;
use Test2::API qw/context release/;
# Make Test::Builder thread-safe for ithreads.
BEGIN {
    warn "Test::Builder was loaded after Test2 initialization, this is not recommended."
        if Test2::API::test2_init_done() || Test2::API::test2_load_done();

    if (USE_THREADS && ! Test2::API::test2_ipc_disabled()) {
        require Test2::IPC;
        require Test2::IPC::Driver::Files;
        Test2::IPC::Driver::Files->import;
        Test2::API::test2_ipc_enable_polling();
        Test2::API::test2_no_wait(1);
    }
}

use Test2::Event::Subtest;
use Test2::Hub::Subtest;

use Test::Builder::Formatter;
use Test::Builder::TodoDiag;

our $Level = 1;
our $Test = $ENV{TB_NO_EARLY_INIT} ? undef : Test::Builder->new;

sub _add_ts_hooks {
    my $self = shift;

    my $hub = $self->{Stack}->top;

    # Take a reference to the hash key, we do this to avoid closing over $self
    # which is the singleton. We use a reference because the value could change
    # in rare cases.
    my $epkgr = \$self->{Exported_To};

    #$hub->add_context_aquire(sub {$_[0]->{level} += $Level - 1});

    $hub->pre_filter(sub {
        my ($active_hub, $e) = @_;

        my $epkg = $$epkgr;
        my $cpkg = $e->{trace} ? $e->{trace}->{frame}->[0] : undef;

        no strict 'refs';
        no warnings 'once';
        my $todo;
        $todo = ${"$cpkg\::TODO"} if $cpkg;
        $todo = ${"$epkg\::TODO"} if $epkg && !$todo;

        return $e unless defined($todo);
        return $e unless length($todo);

        # Turn a diag into a todo diag
        return Test::Builder::TodoDiag->new(%$e) if ref($e) eq 'Test2::Event::Diag';

        $e->set_todo($todo) if $e->can('set_todo');
        $e->add_amnesty({tag => 'TODO', details => $todo});

        # Set todo on ok's
        if ($e->isa('Test2::Event::Ok')) {
            $e->set_effective_pass(1);

            if (my $result = $e->get_meta(__PACKAGE__)) {
                $result->{reason} ||= $todo;
                $result->{type}   ||= 'todo';
                $result->{ok}       = 1;
            }
        }

        return $e;
    }, inherit => 1);
}

{
    no warnings;
    INIT {
        use warnings;
        Test2::API::test2_load() unless Test2::API::test2_in_preload();
    }
}

sub new {
    my($class) = shift;
    unless($Test) {
        $Test = $class->create(singleton => 1);

        Test2::API::test2_add_callback_post_load(
            sub {
                $Test->{Original_Pid} = $$ if !$Test->{Original_Pid} || $Test->{Original_Pid} == 0;
                $Test->reset(singleton => 1);
                $Test->_add_ts_hooks;
            }
        );

        # Non-TB tools normally expect 0 added to the level. $Level is normally 1. So
        # we only want the level to change if $Level != 1.
        # TB->ctx compensates for this later.
        Test2::API::test2_add_callback_context_aquire(sub { $_[0]->{level} += $Level - 1 });

        Test2::API::test2_add_callback_exit(sub { $Test->_ending(@_) });

        Test2::API::test2_ipc()->set_no_fatal(1) if Test2::API::test2_has_ipc();
    }
    return $Test;
}

sub create {
    my $class = shift;
    my %params = @_;

    my $self = bless {}, $class;
    if ($params{singleton}) {
        $self->{Stack} = Test2::API::test2_stack();
    }
    else {
        $self->{Stack} = Test2::API::Stack->new;
        $self->{Stack}->new_hub(
            formatter => Test::Builder::Formatter->new,
            ipc       => Test2::API::test2_ipc(),
        );

        $self->reset(%params);
        $self->_add_ts_hooks;
    }

    return $self;
}

sub ctx {
    my $self = shift;
    context(
        # 1 for our frame, another for the -1 off of $Level in our hook at the top.
        level   => 2,
        fudge   => 1,
        stack   => $self->{Stack},
        hub     => $self->{Hub},
        wrapped => 1,
        @_
    );
}

sub parent {
    my $self = shift;
    my $ctx = $self->ctx;
    my $chub = $self->{Hub} || $ctx->hub;
    $ctx->release;

    my $meta = $chub->meta(__PACKAGE__, {});
    my $parent = $meta->{parent};

    return undef unless $parent;

    return bless {
        Original_Pid => $$,
        Stack => $self->{Stack},
        Hub => $parent,
    }, blessed($self);
}

sub child {
    my( $self, $name ) = @_;

    $name ||= "Child of " . $self->name;
    my $ctx = $self->ctx;

    my $parent = $ctx->hub;
    my $pmeta = $parent->meta(__PACKAGE__, {});
    $self->croak("You already have a child named ($pmeta->{child}) running")
        if $pmeta->{child};

    $pmeta->{child} = $name;

    # Clear $TODO for the child.
    my $orig_TODO = $self->find_TODO(undef, 1, undef);

    my $subevents = [];

    my $hub = $ctx->stack->new_hub(
        class => 'Test2::Hub::Subtest',
    );

    $hub->pre_filter(sub {
        my ($active_hub, $e) = @_;

        # Turn a diag into a todo diag
        return Test::Builder::TodoDiag->new(%$e) if ref($e) eq 'Test2::Event::Diag';

        return $e;
    }, inherit => 1) if $orig_TODO;

    $hub->listen(sub { push @$subevents => $_[1] });

    $hub->set_nested( $parent->nested + 1 );

    my $meta = $hub->meta(__PACKAGE__, {});
    $meta->{Name} = $name;
    $meta->{TODO} = $orig_TODO;
    $meta->{TODO_PKG} = $ctx->trace->package;
    $meta->{parent} = $parent;
    $meta->{Test_Results} = [];
    $meta->{subevents} = $subevents;
    $meta->{subtest_id} = $hub->id;
    $meta->{subtest_uuid} = $hub->uuid;
    $meta->{subtest_buffered} = $parent->format ? 0 : 1;

    $self->_add_ts_hooks;

    $ctx->release;
    return bless { Original_Pid => $$, Stack => $self->{Stack}, Hub => $hub, no_log_results => $self->{no_log_results} }, blessed($self);
}

sub finalize {
    my $self = shift;
    my $ok = 1;
    ($ok) = @_ if @_;

    my $st_ctx = $self->ctx;
    my $chub = $self->{Hub} || return $st_ctx->release;

    my $meta = $chub->meta(__PACKAGE__, {});
    if ($meta->{child}) {
        $self->croak("Can't call finalize() with child ($meta->{child}) active");
    }

    local $? = 0;     # don't fail if $subtests happened to set $? nonzero

    $self->{Stack}->pop($chub);

    $self->find_TODO($meta->{TODO_PKG}, 1, $meta->{TODO});

    my $parent = $self->parent;
    my $ctx = $parent->ctx;
    my $trace = $ctx->trace;
    delete $ctx->hub->meta(__PACKAGE__, {})->{child};

    $chub->finalize($trace->snapshot(hid => $chub->hid, nested => $chub->nested), 1)
        if $ok
        && $chub->count
        && !$chub->no_ending
        && !$chub->ended;

    my $plan   = $chub->plan || 0;
    my $count  = $chub->count;
    my $failed = $chub->failed;
    my $passed = $chub->is_passing;

    my $num_extra = $plan =~ m/\D/ ? 0 : $count - $plan;
    if ($count && $num_extra != 0) {
        my $s = $plan == 1 ? '' : 's';
        $st_ctx->diag(<<"FAIL");
Looks like you planned $plan test$s but ran $count.
FAIL
    }

    if ($failed) {
        my $s = $failed == 1 ? '' : 's';

        my $qualifier = $num_extra == 0 ? '' : ' run';

        $st_ctx->diag(<<"FAIL");
Looks like you failed $failed test$s of $count$qualifier.
FAIL
    }

    if (!$passed && !$failed && $count && !$num_extra) {
        $st_ctx->diag(<<"FAIL");
All assertions inside the subtest passed, but errors were encountered.
FAIL
    }

    $st_ctx->release;

    unless ($chub->bailed_out) {
        my $plan = $chub->plan;
        if ( $plan && $plan eq 'SKIP' ) {
            $parent->skip($chub->skip_reason, $meta->{Name});
        }
        elsif ( !$chub->count ) {
            $parent->ok( 0, sprintf q[No tests run for subtest "%s"], $meta->{Name} );
        }
        else {
            $parent->{subevents}  = $meta->{subevents};
            $parent->{subtest_id} = $meta->{subtest_id};
            $parent->{subtest_uuid} = $meta->{subtest_uuid};
            $parent->{subtest_buffered} = $meta->{subtest_buffered};
            $parent->ok( $chub->is_passing, $meta->{Name} );
        }
    }

    $ctx->release;
    return $chub->is_passing;
}

sub subtest {
    my $self = shift;
    my ($name, $code, @args) = @_;
    my $ctx = $self->ctx;
    $ctx->throw("subtest()'s second argument must be a code ref")
        unless $code && reftype($code) eq 'CODE';

    $name ||= "Child of " . $self->name;


    $_->($name,$code,@args)
        for Test2::API::test2_list_pre_subtest_callbacks();

    $ctx->note("Subtest: $name");

    my $child = $self->child($name);

    my $start_pid = $$;
    my $st_ctx;
    my ($ok, $err, $finished, $child_error);
    T2_SUBTEST_WRAPPER: {
        my $ctx = $self->ctx;
        $st_ctx = $ctx->snapshot;
        $ctx->release;
        $ok = eval { local $Level = 1; $code->(@args); 1 };
        ($err, $child_error) = ($@, $?);

        # They might have done 'BEGIN { skip_all => "whatever" }'
        if (!$ok && $err =~ m/Label not found for "last T2_SUBTEST_WRAPPER"/ || (blessed($err) && blessed($err) eq 'Test::Builder::Exception')) {
            $ok  = undef;
            $err = undef;
        }
        else {
            $finished = 1;
        }
    }

    if ($start_pid != $$ && !$INC{'Test2/IPC.pm'}) {
        warn $ok ? "Forked inside subtest, but subtest never finished!\n" : $err;
        exit 255;
    }

    my $trace = $ctx->trace;

    if (!$finished) {
        if(my $bailed = $st_ctx->hub->bailed_out) {
            my $chub = $child->{Hub};
            $self->{Stack}->pop($chub);
            $ctx->bail($bailed->reason);
        }
        my $code = $st_ctx->hub->exit_code;
        $ok = !$code;
        $err = "Subtest ended with exit code $code" if $code;
    }

    my $st_hub  = $st_ctx->hub;
    my $plan  = $st_hub->plan;
    my $count = $st_hub->count;

    if (!$count && (!defined($plan) || "$plan" ne 'SKIP')) {
        $st_ctx->plan(0) unless defined $plan;
        $st_ctx->diag('No tests run!');
    }

    $child->finalize($st_ctx->trace);

    $ctx->release;

    die $err unless $ok;

    $? = $child_error if defined $child_error;

    return $st_hub->is_passing;
}

sub name {
    my $self = shift;
    my $ctx = $self->ctx;
    release $ctx, $ctx->hub->meta(__PACKAGE__, {})->{Name};
}

sub reset {    ## no critic (Subroutines::ProhibitBuiltinHomonyms)
    my ($self, %params) = @_;

    Test2::API::test2_unset_is_end();

    # We leave this a global because it has to be localized and localizing
    # hash keys is just asking for pain.  Also, it was documented.
    $Level = 1;

    $self->{no_log_results} = $ENV{TEST_NO_LOG_RESULTS} ? 1 : 0
        unless $params{singleton};

    $self->{Original_Pid} = Test2::API::test2_in_preload() ? -1 : $$;

    my $ctx = $self->ctx;
    my $hub = $ctx->hub;
    $ctx->release;
    unless ($params{singleton}) {
        $hub->reset_state();
        $hub->_tb_reset();
    }

    $ctx = $self->ctx;

    my $meta = $ctx->hub->meta(__PACKAGE__, {});
    %$meta = (
        Name         => $0,
        Ending       => 0,
        Done_Testing => undef,
        Skip_All     => 0,
        Test_Results => [],
        parent       => $meta->{parent},
    );

    $self->{Exported_To} = undef unless $params{singleton};

    $self->{Orig_Handles} ||= do {
        my $format = $ctx->hub->format;
        my $out;
        if ($format && $format->isa('Test2::Formatter::TAP')) {
            $out = $format->handles;
        }
        $out ? [@$out] : [];
    };

    $self->use_numbers(1);
    $self->no_header(0) unless $params{singleton};
    $self->no_ending(0) unless $params{singleton};
    $self->reset_outputs;

    $ctx->release;

    return;
}


my %plan_cmds = (
    no_plan  => \&no_plan,
    skip_all => \&skip_all,
    tests    => \&_plan_tests,
);

sub plan {
    my( $self, $cmd, $arg ) = @_;

    return unless $cmd;

    my $ctx = $self->ctx;
    my $hub = $ctx->hub;

    $ctx->throw("You tried to plan twice") if $hub->plan;

    local $Level = $Level + 1;

    if( my $method = $plan_cmds{$cmd} ) {
        local $Level = $Level + 1;
        $self->$method($arg);
    }
    else {
        my @args = grep { defined } ( $cmd, $arg );
        $ctx->throw("plan() doesn't understand @args");
    }

    release $ctx, 1;
}


sub _plan_tests {
    my($self, $arg) = @_;

    my $ctx = $self->ctx;

    if($arg) {
        local $Level = $Level + 1;
        $self->expected_tests($arg);
    }
    elsif( !defined $arg ) {
        $ctx->throw("Got an undefined number of tests");
    }
    else {
        $ctx->throw("You said to run 0 tests");
    }

    $ctx->release;
}


sub expected_tests {
    my $self = shift;
    my($max) = @_;

    my $ctx = $self->ctx;

    if(@_) {
        $self->croak("Number of tests must be a positive integer.  You gave it '$max'")
          unless $max =~ /^\+?\d+$/;

        $ctx->plan($max);
    }

    my $hub = $ctx->hub;

    $ctx->release;

    my $plan = $hub->plan;
    return 0 unless $plan;
    return 0 if $plan =~ m/\D/;
    return $plan;
}


sub no_plan {
    my($self, $arg) = @_;

    my $ctx = $self->ctx;

    if (defined $ctx->hub->plan) {
        warn "Plan already set, no_plan() is a no-op, this will change to a hard failure in the future.";
        $ctx->release;
        return;
    }

    $ctx->alert("no_plan takes no arguments") if $arg;

    $ctx->hub->plan('NO PLAN');

    release $ctx, 1;
}


sub done_testing {
    my($self, $num_tests) = @_;

    my $ctx = $self->ctx;

    my $meta = $ctx->hub->meta(__PACKAGE__, {});

    if ($meta->{Done_Testing}) {
        my ($file, $line) = @{$meta->{Done_Testing}}[1,2];
        local $ctx->hub->{ended}; # OMG This is awful.
        $self->ok(0, "done_testing() was already called at $file line $line");
        $ctx->release;
        return;
    }
    $meta->{Done_Testing} = [$ctx->trace->call];

    my $plan = $ctx->hub->plan;
    my $count = $ctx->hub->count;

    # If done_testing() specified the number of tests, shut off no_plan
    if( defined $num_tests ) {
        $ctx->plan($num_tests) if !$plan || $plan eq 'NO PLAN';
    }
    elsif ($count && defined $num_tests && $count != $num_tests) {
        $self->ok(0, "planned to run @{[ $self->expected_tests ]} but done_testing() expects $num_tests");
    }
    else {
        $num_tests = $self->current_test;
    }

    if( $self->expected_tests && $num_tests != $self->expected_tests ) {
        $self->ok(0, "planned to run @{[ $self->expected_tests ]} ".
                     "but done_testing() expects $num_tests");
    }

    $ctx->plan($num_tests) if $ctx->hub->plan && $ctx->hub->plan eq 'NO PLAN';

    $ctx->hub->finalize($ctx->trace, 1);

    release $ctx, 1;
}


sub has_plan {
    my $self = shift;

    my $ctx = $self->ctx;
    my $plan = $ctx->hub->plan;
    $ctx->release;

    return( $plan ) if $plan && $plan !~ m/\D/;
    return('no_plan') if $plan && $plan eq 'NO PLAN';
    return(undef);
}


sub skip_all {
    my( $self, $reason ) = @_;

    my $ctx = $self->ctx;

    $ctx->hub->meta(__PACKAGE__, {})->{Skip_All} = $reason || 1;

    # Work around old perl bug
    if ($] < 5.020000) {
        my $begin = 0;
        my $level = 0;
        while (my @call = caller($level++)) {
            last unless @call && $call[0];
            next unless $call[3] =~ m/::BEGIN$/;
            $begin++;
            last;
        }
        # HACK!
        die 'Label not found for "last T2_SUBTEST_WRAPPER"' if $begin && $ctx->hub->meta(__PACKAGE__, {})->{parent};
    }

    $ctx->plan(0, SKIP => $reason);
}


sub exported_to {
    my( $self, $pack ) = @_;

    if( defined $pack ) {
        $self->{Exported_To} = $pack;
    }
    return $self->{Exported_To};
}


sub ok {
    my( $self, $test, $name ) = @_;

    my $ctx = $self->ctx;

    # $test might contain an object which we don't want to accidentally
    # store, so we turn it into a boolean.
    $test = $test ? 1 : 0;

    # In case $name is a string overloaded object, force it to stringify.
    no  warnings qw/uninitialized numeric/;
    $name = "$name" if defined $name;

    # Profiling showed that the regex here was a huge time waster, doing the
    # numeric addition first cuts our profile time from ~300ms to ~50ms
    $self->diag(<<"    ERR") if 0 + $name && $name =~ /^[\d\s]+$/;
    You named your test '$name'.  You shouldn't use numbers for your test names.
    Very confusing.
    ERR
    use warnings qw/uninitialized numeric/;

    my $trace = $ctx->{trace};
    my $hub   = $ctx->{hub};

    my $result = {
        ok => $test,
        actual_ok => $test,
        reason => '',
        type => '',
        (name => defined($name) ? $name : ''),
    };

    $hub->{_meta}->{+__PACKAGE__}->{Test_Results}[ $hub->{count} ] = $result unless $self->{no_log_results};

    my $orig_name = $name;

    my @attrs;
    my $subevents  = delete $self->{subevents};
    my $subtest_id = delete $self->{subtest_id};
    my $subtest_uuid = delete $self->{subtest_uuid};
    my $subtest_buffered = delete $self->{subtest_buffered};
    my $epkg = 'Test2::Event::Ok';
    if ($subevents) {
        $epkg = 'Test2::Event::Subtest';
        push @attrs => (subevents => $subevents, subtest_id => $subtest_id, subtest_uuid => $subtest_uuid, buffered => $subtest_buffered);
    }

    my $e = bless {
        trace => bless( {%$trace}, 'Test2::EventFacet::Trace'),
        pass  => $test,
        name  => $name,
        _meta => {'Test::Builder' => $result},
        effective_pass => $test,
        @attrs,
    }, $epkg;
    $hub->send($e);

    $self->_ok_debug($trace, $orig_name) unless($test);

    $ctx->release;
    return $test;
}

sub _ok_debug {
    my $self = shift;
    my ($trace, $orig_name) = @_;

    my $is_todo = $self->in_todo;

    my $msg = $is_todo ? "Failed (TODO)" : "Failed";

    my (undef, $file, $line) = $trace->call;
    if (defined $orig_name) {
        $self->diag(qq[  $msg test '$orig_name'\n  at $file line $line.\n]);
    }
    else {
        $self->diag(qq[  $msg test at $file line $line.\n]);
    }
}

sub _diag_fh {
    my $self = shift;
    local $Level = $Level + 1;
    return $self->in_todo ? $self->todo_output : $self->failure_output;
}

sub _unoverload {
    my ($self, $type, $thing) = @_;

    return unless ref $$thing;
    return unless blessed($$thing) || scalar $self->_try(sub{ $$thing->isa('UNIVERSAL') });
    {
        local ($!, $@);
        require overload;
    }
    my $string_meth = overload::Method( $$thing, $type ) || return;
    $$thing = $$thing->$string_meth();
}

sub _unoverload_str {
    my $self = shift;

    $self->_unoverload( q[""], $_ ) for @_;
}

sub _unoverload_num {
    my $self = shift;

    $self->_unoverload( '0+', $_ ) for @_;

    for my $val (@_) {
        next unless $self->_is_dualvar($$val);
        $$val = $$val + 0;
    }
}

# This is a hack to detect a dualvar such as $!
sub _is_dualvar {
    my( $self, $val ) = @_;

    # Objects are not dualvars.
    return 0 if ref $val;

    no warnings 'numeric';
    my $numval = $val + 0;
    return ($numval != 0 and $numval ne $val ? 1 : 0);
}


sub is_eq {
    my( $self, $got, $expect, $name ) = @_;

    my $ctx = $self->ctx;

    local $Level = $Level + 1;

    if( !defined $got || !defined $expect ) {
        # undef only matches undef and nothing else
        my $test = !defined $got && !defined $expect;

        $self->ok( $test, $name );
        $self->_is_diag( $got, 'eq', $expect ) unless $test;
        $ctx->release;
        return $test;
    }

    release $ctx, $self->cmp_ok( $got, 'eq', $expect, $name );
}


sub is_num {
    my( $self, $got, $expect, $name ) = @_;
    my $ctx = $self->ctx;
    local $Level = $Level + 1;

    if( !defined $got || !defined $expect ) {
        # undef only matches undef and nothing else
        my $test = !defined $got && !defined $expect;

        $self->ok( $test, $name );
        $self->_is_diag( $got, '==', $expect ) unless $test;
        $ctx->release;
        return $test;
    }

    release $ctx, $self->cmp_ok( $got, '==', $expect, $name );
}


sub _diag_fmt {
    my( $self, $type, $val ) = @_;

    if( defined $$val ) {
        if( $type eq 'eq' or $type eq 'ne' ) {
            # quote and force string context
            $$val = "'$$val'";
        }
        else {
            # force numeric context
            $self->_unoverload_num($val);
        }
    }
    else {
        $$val = 'undef';
    }

    return;
}


sub _is_diag {
    my( $self, $got, $type, $expect ) = @_;

    $self->_diag_fmt( $type, $_ ) for \$got, \$expect;

    local $Level = $Level + 1;
    return $self->diag(<<"DIAGNOSTIC");
         got: $got
    expected: $expect
DIAGNOSTIC

}

sub _isnt_diag {
    my( $self, $got, $type ) = @_;

    $self->_diag_fmt( $type, \$got );

    local $Level = $Level + 1;
    return $self->diag(<<"DIAGNOSTIC");
         got: $got
    expected: anything else
DIAGNOSTIC
}


sub isnt_eq {
    my( $self, $got, $dont_expect, $name ) = @_;
    my $ctx = $self->ctx;
    local $Level = $Level + 1;

    if( !defined $got || !defined $dont_expect ) {
        # undef only matches undef and nothing else
        my $test = defined $got || defined $dont_expect;

        $self->ok( $test, $name );
        $self->_isnt_diag( $got, 'ne' ) unless $test;
        $ctx->release;
        return $test;
    }

    release $ctx, $self->cmp_ok( $got, 'ne', $dont_expect, $name );
}

sub isnt_num {
    my( $self, $got, $dont_expect, $name ) = @_;
    my $ctx = $self->ctx;
    local $Level = $Level + 1;

    if( !defined $got || !defined $dont_expect ) {
        # undef only matches undef and nothing else
        my $test = defined $got || defined $dont_expect;

        $self->ok( $test, $name );
        $self->_isnt_diag( $got, '!=' ) unless $test;
        $ctx->release;
        return $test;
    }

    release $ctx, $self->cmp_ok( $got, '!=', $dont_expect, $name );
}


sub like {
    my( $self, $thing, $regex, $name ) = @_;
    my $ctx = $self->ctx;

    local $Level = $Level + 1;

    release $ctx, $self->_regex_ok( $thing, $regex, '=~', $name );
}

sub unlike {
    my( $self, $thing, $regex, $name ) = @_;
    my $ctx = $self->ctx;

    local $Level = $Level + 1;

    release $ctx, $self->_regex_ok( $thing, $regex, '!~', $name );
}


my %numeric_cmps = map { ( $_, 1 ) } ( "<", "<=", ">", ">=", "==", "!=", "<=>" );

# Bad, these are not comparison operators. Should we include more?
my %cmp_ok_bl = map { ( $_, 1 ) } ( "=", "+=", ".=", "x=", "^=", "|=", "||=", "&&=", "...");

sub cmp_ok {
    my( $self, $got, $type, $expect, $name ) = @_;
    my $ctx = $self->ctx;

    if ($cmp_ok_bl{$type}) {
        $ctx->throw("$type is not a valid comparison operator in cmp_ok()");
    }

    my ($test, $succ);
    my $error;
    {
        ## no critic (BuiltinFunctions::ProhibitStringyEval)

        local( $@, $!, $SIG{__DIE__} );    # isolate eval

        my($pack, $file, $line) = $ctx->trace->call();

        # This is so that warnings come out at the caller's level
        $succ = eval qq[
#line $line "(eval in cmp_ok) $file"
\$test = (\$got $type \$expect);
1;
];
        $error = $@;
    }
    local $Level = $Level + 1;
    my $ok = $self->ok( $test, $name );

    # Treat overloaded objects as numbers if we're asked to do a
    # numeric comparison.
    my $unoverload
      = $numeric_cmps{$type}
      ? '_unoverload_num'
      : '_unoverload_str';

    $self->diag(<<"END") unless $succ;
An error occurred while using $type:
------------------------------------
$error
------------------------------------
END

    unless($ok) {
        $self->$unoverload( \$got, \$expect );

        if( $type =~ /^(eq|==)$/ ) {
            $self->_is_diag( $got, $type, $expect );
        }
        elsif( $type =~ /^(ne|!=)$/ ) {
            no warnings;
            my $eq = ($got eq $expect || $got == $expect)
                && (
                    (defined($got) xor defined($expect))
                 || (length($got)  !=  length($expect))
                );
            use warnings;

            if ($eq) {
                $self->_cmp_diag( $got, $type, $expect );
            }
            else {
                $self->_isnt_diag( $got, $type );
            }
        }
        else {
            $self->_cmp_diag( $got, $type, $expect );
        }
    }
    return release $ctx, $ok;
}

sub _cmp_diag {
    my( $self, $got, $type, $expect ) = @_;

    $got    = defined $got    ? "'$got'"    : 'undef';
    $expect = defined $expect ? "'$expect'" : 'undef';

    local $Level = $Level + 1;
    return $self->diag(<<"DIAGNOSTIC");
    $got
        $type
    $expect
DIAGNOSTIC
}

sub _caller_context {
    my $self = shift;

    my( $pack, $file, $line ) = $self->caller(1);

    my $code = '';
    $code .= "#line $line $file\n" if defined $file and defined $line;

    return $code;
}


sub BAIL_OUT {
    my( $self, $reason ) = @_;

    my $ctx = $self->ctx;

    $self->{Bailed_Out} = 1;

    $ctx->bail($reason);
}


{
    no warnings 'once';
    *BAILOUT = \&BAIL_OUT;
}

sub skip {
    my( $self, $why, $name ) = @_;
    $why ||= '';
    $name = '' unless defined $name;
    $self->_unoverload_str( \$why );

    my $ctx = $self->ctx;

    $ctx->hub->meta(__PACKAGE__, {})->{Test_Results}[ $ctx->hub->count ] = {
        'ok'      => 1,
        actual_ok => 1,
        name      => $name,
        type      => 'skip',
        reason    => $why,
    } unless $self->{no_log_results};

    $name =~ s|#|\\#|g;    # # in a name can confuse Test::Harness.
    $name =~ s{\n}{\n# }sg;
    $why =~ s{\n}{\n# }sg;

    my $tctx = $ctx->snapshot;
    $tctx->skip('', $why);

    return release $ctx, 1;
}


sub todo_skip {
    my( $self, $why ) = @_;
    $why ||= '';

    my $ctx = $self->ctx;

    $ctx->hub->meta(__PACKAGE__, {})->{Test_Results}[ $ctx->hub->count ] = {
        'ok'      => 1,
        actual_ok => 0,
        name      => '',
        type      => 'todo_skip',
        reason    => $why,
    } unless $self->{no_log_results};

    $why =~ s{\n}{\n# }sg;
    my $tctx = $ctx->snapshot;
    $tctx->send_event( 'Skip', todo => $why, todo_diag => 1, reason => $why, pass => 0);

    return release $ctx, 1;
}


sub maybe_regex {
    my( $self, $regex ) = @_;
    my $usable_regex = undef;

    return $usable_regex unless defined $regex;

    my( $re, $opts );

    # Check for qr/foo/
    if( _is_qr($regex) ) {
        $usable_regex = $regex;
    }
    # Check for '/foo/' or 'm,foo,'
    elsif(( $re, $opts )        = $regex =~ m{^ /(.*)/ (\w*) $ }sx              or
          ( undef, $re, $opts ) = $regex =~ m,^ m([^\w\s]) (.+) \1 (\w*) $,sx
    )
    {
        $usable_regex = length $opts ? "(?$opts)$re" : $re;
    }

    return $usable_regex;
}

sub _is_qr {
    my $regex = shift;

    # is_regexp() checks for regexes in a robust manner, say if they're
    # blessed.
    return re::is_regexp($regex) if defined &re::is_regexp;
    return ref $regex eq 'Regexp';
}

sub _regex_ok {
    my( $self, $thing, $regex, $cmp, $name ) = @_;

    my $ok           = 0;
    my $usable_regex = $self->maybe_regex($regex);
    unless( defined $usable_regex ) {
        local $Level = $Level + 1;
        $ok = $self->ok( 0, $name );
        $self->diag("    '$regex' doesn't look much like a regex to me.");
        return $ok;
    }

    {
        my $test;
        my $context = $self->_caller_context;

        {
            ## no critic (BuiltinFunctions::ProhibitStringyEval)

            local( $@, $!, $SIG{__DIE__} );    # isolate eval

            # No point in issuing an uninit warning, they'll see it in the diagnostics
            no warnings 'uninitialized';

            $test = eval $context . q{$test = $thing =~ /$usable_regex/ ? 1 : 0};
        }

        $test = !$test if $cmp eq '!~';

        local $Level = $Level + 1;
        $ok = $self->ok( $test, $name );
    }

    unless($ok) {
        $thing = defined $thing ? "'$thing'" : 'undef';
        my $match = $cmp eq '=~' ? "doesn't match" : "matches";

        local $Level = $Level + 1;
        $self->diag( sprintf <<'DIAGNOSTIC', $thing, $match, $regex );
                  %s
    %13s '%s'
DIAGNOSTIC

    }

    return $ok;
}


sub is_fh {
    my $self     = shift;
    my $maybe_fh = shift;
    return 0 unless defined $maybe_fh;

    return 1 if ref $maybe_fh  eq 'GLOB';    # its a glob ref
    return 1 if ref \$maybe_fh eq 'GLOB';    # its a glob

    return eval { $maybe_fh->isa("IO::Handle") } ||
           eval { tied($maybe_fh)->can('TIEHANDLE') };
}


sub level {
    my( $self, $level ) = @_;

    if( defined $level ) {
        $Level = $level;
    }
    return $Level;
}


sub use_numbers {
    my( $self, $use_nums ) = @_;

    my $ctx = $self->ctx;
    my $format = $ctx->hub->format;
    unless ($format && $format->can('no_numbers') && $format->can('set_no_numbers')) {
        warn "The current formatter does not support 'use_numbers'" if $format;
        return release $ctx, 0;
    }

    $format->set_no_numbers(!$use_nums) if defined $use_nums;

    return release $ctx, $format->no_numbers ? 0 : 1;
}

BEGIN {
    for my $method (qw(no_header no_diag)) {
        my $set = "set_$method";
        my $code = sub {
            my( $self, $no ) = @_;

            my $ctx = $self->ctx;
            my $format = $ctx->hub->format;
            unless ($format && $format->can($set)) {
                warn "The current formatter does not support '$method'" if $format;
                $ctx->release;
                return
            }

            $format->$set($no) if defined $no;

            return release $ctx, $format->$method ? 1 : 0;
        };

        no strict 'refs';    ## no critic
        *$method = $code;
    }
}

sub no_ending {
    my( $self, $no ) = @_;

    my $ctx = $self->ctx;

    $ctx->hub->set_no_ending($no) if defined $no;

    return release $ctx, $ctx->hub->no_ending;
}

sub diag {
    my $self = shift;
    return unless @_;

    my $text = join '' => map {defined($_) ? $_ : 'undef'} @_;

    if (Test2::API::test2_in_preload()) {
        chomp($text);
        $text =~ s/^/# /msg;
        print STDERR $text, "\n";
        return 0;
    }

    my $ctx = $self->ctx;
    $ctx->diag($text);
    $ctx->release;
    return 0;
}


sub note {
    my $self = shift;
    return unless @_;

    my $text = join '' => map {defined($_) ? $_ : 'undef'} @_;

    if (Test2::API::test2_in_preload()) {
        chomp($text);
        $text =~ s/^/# /msg;
        print STDOUT $text, "\n";
        return 0;
    }

    my $ctx = $self->ctx;
    $ctx->note($text);
    $ctx->release;
    return 0;
}


sub explain {
    my $self = shift;

    local ($@, $!);
    require Data::Dumper;

    return map {
        ref $_
          ? do {
            my $dumper = Data::Dumper->new( [$_] );
            $dumper->Indent(1)->Terse(1);
            $dumper->Sortkeys(1) if $dumper->can("Sortkeys");
            $dumper->Dump;
          }
          : $_
    } @_;
}


sub output {
    my( $self, $fh ) = @_;

    my $ctx = $self->ctx;
    my $format = $ctx->hub->format;
    $ctx->release;
    return unless $format && $format->isa('Test2::Formatter::TAP');

    $format->handles->[Test2::Formatter::TAP::OUT_STD()] = $self->_new_fh($fh)
        if defined $fh;

    return $format->handles->[Test2::Formatter::TAP::OUT_STD()];
}

sub failure_output {
    my( $self, $fh ) = @_;

    my $ctx = $self->ctx;
    my $format = $ctx->hub->format;
    $ctx->release;
    return unless $format && $format->isa('Test2::Formatter::TAP');

    $format->handles->[Test2::Formatter::TAP::OUT_ERR()] = $self->_new_fh($fh)
        if defined $fh;

    return $format->handles->[Test2::Formatter::TAP::OUT_ERR()];
}

sub todo_output {
    my( $self, $fh ) = @_;

    my $ctx = $self->ctx;
    my $format = $ctx->hub->format;
    $ctx->release;
    return unless $format && $format->isa('Test::Builder::Formatter');

    $format->handles->[Test::Builder::Formatter::OUT_TODO()] = $self->_new_fh($fh)
        if defined $fh;

    return $format->handles->[Test::Builder::Formatter::OUT_TODO()];
}

sub _new_fh {
    my $self = shift;
    my($file_or_fh) = shift;

    my $fh;
    if( $self->is_fh($file_or_fh) ) {
        $fh = $file_or_fh;
    }
    elsif( ref $file_or_fh eq 'SCALAR' ) {
        # Scalar refs as filehandles was added in 5.8.
        if( $] >= 5.008 ) {
            open $fh, ">>", $file_or_fh
              or $self->croak("Can't open scalar ref $file_or_fh: $!");
        }
        # Emulate scalar ref filehandles with a tie.
        else {
            $fh = Test::Builder::IO::Scalar->new($file_or_fh)
              or $self->croak("Can't tie scalar ref $file_or_fh");
        }
    }
    else {
        open $fh, ">", $file_or_fh
          or $self->croak("Can't open test output log $file_or_fh: $!");
        _autoflush($fh);
    }

    return $fh;
}

sub _autoflush {
    my($fh) = shift;
    my $old_fh = select $fh;
    $| = 1;
    select $old_fh;

    return;
}


sub reset_outputs {
    my $self = shift;

    my $ctx = $self->ctx;
    my $format = $ctx->hub->format;
    $ctx->release;
    return unless $format && $format->isa('Test2::Formatter::TAP');
    $format->set_handles([@{$self->{Orig_Handles}}]) if $self->{Orig_Handles};

    return;
}


sub carp {
    my $self = shift;
    my $ctx = $self->ctx;
    $ctx->alert(join "", @_);
    $ctx->release;
}

sub croak {
    my $self = shift;
    my $ctx = $self->ctx;
    $ctx->throw(join "", @_);
    $ctx->release;
}


sub current_test {
    my( $self, $num ) = @_;

    my $ctx = $self->ctx;
    my $hub = $ctx->hub;

    if( defined $num ) {
        $hub->set_count($num);

        unless ($self->{no_log_results}) {
            # If the test counter is being pushed forward fill in the details.
            my $test_results = $ctx->hub->meta(__PACKAGE__, {})->{Test_Results};
            if ($num > @$test_results) {
                my $start = @$test_results ? @$test_results : 0;
                for ($start .. $num - 1) {
                    $test_results->[$_] = {
                        'ok'      => 1,
                        actual_ok => undef,
                        reason    => 'incrementing test number',
                        type      => 'unknown',
                        name      => undef
                    };
                }
            }
            # If backward, wipe history.  Its their funeral.
            elsif ($num < @$test_results) {
                $#{$test_results} = $num - 1;
            }
        }
    }
    return release $ctx, $hub->count;
}


sub is_passing {
    my $self = shift;

    my $ctx = $self->ctx;
    my $hub = $ctx->hub;

    if( @_ ) {
        my ($bool) = @_;
        $hub->set_failed(0) if $bool;
        $hub->is_passing($bool);
    }

    return release $ctx, $hub->is_passing;
}


sub summary {
    my($self) = shift;

    return if $self->{no_log_results};

    my $ctx = $self->ctx;
    my $data = $ctx->hub->meta(__PACKAGE__, {})->{Test_Results};
    $ctx->release;
    return map { $_ ? $_->{'ok'} : () } @$data;
}


sub details {
    my $self = shift;

    return if $self->{no_log_results};

    my $ctx = $self->ctx;
    my $data = $ctx->hub->meta(__PACKAGE__, {})->{Test_Results};
    $ctx->release;
    return @$data;
}


sub find_TODO {
    my( $self, $pack, $set, $new_value ) = @_;

    my $ctx = $self->ctx;

    $pack ||= $ctx->trace->package || $self->exported_to;
    $ctx->release;

    return unless $pack;

    no strict 'refs';    ## no critic
    no warnings 'once';
    my $old_value = ${ $pack . '::TODO' };
    $set and ${ $pack . '::TODO' } = $new_value;
    return $old_value;
}

sub todo {
    my( $self, $pack ) = @_;

    local $Level = $Level + 1;
    my $ctx = $self->ctx;
    $ctx->release;

    my $meta = $ctx->hub->meta(__PACKAGE__, {todo => []})->{todo};
    return $meta->[-1]->[1] if $meta && @$meta;

    $pack ||= $ctx->trace->package;

    return unless $pack;

    no strict 'refs';    ## no critic
    no warnings 'once';
    return ${ $pack . '::TODO' };
}

sub in_todo {
    my $self = shift;

    local $Level = $Level + 1;
    my $ctx = $self->ctx;
    $ctx->release;

    my $meta = $ctx->hub->meta(__PACKAGE__, {todo => []})->{todo};
    return 1 if $meta && @$meta;

    my $pack = $ctx->trace->package || return 0;

    no strict 'refs';    ## no critic
    no warnings 'once';
    my $todo = ${ $pack . '::TODO' };

    return 0 unless defined $todo;
    return 0 if "$todo" eq '';
    return 1;
}

sub todo_start {
    my $self = shift;
    my $message = @_ ? shift : '';

    my $ctx = $self->ctx;

    my $hub = $ctx->hub;
    my $filter = $hub->pre_filter(sub {
        my ($active_hub, $e) = @_;

        # Turn a diag into a todo diag
        return Test::Builder::TodoDiag->new(%$e) if ref($e) eq 'Test2::Event::Diag';

        # Set todo on ok's
        if ($hub == $active_hub && $e->isa('Test2::Event::Ok')) {
            $e->set_todo($message);
            $e->set_effective_pass(1);

            if (my $result = $e->get_meta(__PACKAGE__)) {
                $result->{reason} ||= $message;
                $result->{type}   ||= 'todo';
                $result->{ok}       = 1;
            }
        }

        return $e;
    }, inherit => 1);

    push @{$ctx->hub->meta(__PACKAGE__, {todo => []})->{todo}} => [$filter, $message];

    $ctx->release;

    return;
}

sub todo_end {
    my $self = shift;

    my $ctx = $self->ctx;

    my $set = pop @{$ctx->hub->meta(__PACKAGE__, {todo => []})->{todo}};

    $ctx->throw('todo_end() called without todo_start()') unless $set;

    $ctx->hub->pre_unfilter($set->[0]);

    $ctx->release;

    return;
}


sub caller {    ## no critic (Subroutines::ProhibitBuiltinHomonyms)
    my( $self ) = @_;

    my $ctx = $self->ctx;

    my $trace = $ctx->trace;
    $ctx->release;
    return wantarray ? $trace->call : $trace->package;
}


sub _try {
    my( $self, $code, %opts ) = @_;

    my $error;
    my $return;
    {
        local $!;               # eval can mess up $!
        local $@;               # don't set $@ in the test
        local $SIG{__DIE__};    # don't trip an outside DIE handler.
        $return = eval { $code->() };
        $error = $@;
    }

    die $error if $error and $opts{die_on_fail};

    return wantarray ? ( $return, $error ) : $return;
}

sub _ending {
    my $self = shift;
    my ($ctx, $real_exit_code, $new) = @_;

    unless ($ctx) {
        my $octx = $self->ctx;
        $ctx = $octx->snapshot;
        $octx->release;
    }

    return if $ctx->hub->no_ending;
    return if $ctx->hub->meta(__PACKAGE__, {})->{Ending}++;

    # Don't bother with an ending if this is a forked copy.  Only the parent
    # should do the ending.
    return unless $self->{Original_Pid} == $$;

    my $hub = $ctx->hub;
    return if $hub->bailed_out;

    my $plan  = $hub->plan;
    my $count = $hub->count;
    my $failed = $hub->failed;
    my $passed = $hub->is_passing;
    return unless $plan || $count || $failed;

    # Ran tests but never declared a plan or hit done_testing
    if( !$hub->plan and $hub->count ) {
        $self->diag("Tests were run but no plan was declared and done_testing() was not seen.");

        if($real_exit_code) {
            $self->diag(<<"FAIL");
Looks like your test exited with $real_exit_code just after $count.
FAIL
            $$new ||= $real_exit_code;
            return;
        }

        # But if the tests ran, handle exit code.
        if($failed > 0) {
            my $exit_code = $failed <= 254 ? $failed : 254;
            $$new ||= $exit_code;
            return;
        }

        $$new ||= 254;
        return;
    }

    if ($real_exit_code && !$count) {
        $self->diag("Looks like your test exited with $real_exit_code before it could output anything.");
        $$new ||= $real_exit_code;
        return;
    }

    return if $plan && "$plan" eq 'SKIP';

    if (!$count) {
        $self->diag('No tests run!');
        $$new ||= 255;
        return;
    }

    if ($real_exit_code) {
        $self->diag(<<"FAIL");
Looks like your test exited with $real_exit_code just after $count.
FAIL
        $$new ||= $real_exit_code;
        return;
    }

    if ($plan eq 'NO PLAN') {
        $ctx->plan( $count );
        $plan = $hub->plan;
    }

    # Figure out if we passed or failed and print helpful messages.
    my $num_extra = $count - $plan;

    if ($num_extra != 0) {
        my $s = $plan == 1 ? '' : 's';
        $self->diag(<<"FAIL");
Looks like you planned $plan test$s but ran $count.
FAIL
    }

    if ($failed) {
        my $s = $failed == 1 ? '' : 's';

        my $qualifier = $num_extra == 0 ? '' : ' run';

        $self->diag(<<"FAIL");
Looks like you failed $failed test$s of $count$qualifier.
FAIL
    }

    if (!$passed && !$failed && $count && !$num_extra) {
        $ctx->diag(<<"FAIL");
All assertions passed, but errors were encountered.
FAIL
    }

    my $exit_code = 0;
    if ($failed) {
        $exit_code = $failed <= 254 ? $failed : 254;
    }
    elsif ($num_extra != 0) {
        $exit_code = 255;
    }
    elsif (!$passed) {
        $exit_code = 255;
    }

    $$new ||= $exit_code;
    return;
}

# Some things used this even though it was private... I am looking at you
# Test::Builder::Prefix...
sub _print_comment {
    my( $self, $fh, @msgs ) = @_;

    return if $self->no_diag;
    return unless @msgs;

    # Prevent printing headers when compiling (i.e. -c)
    return if $^C;

    # Smash args together like print does.
    # Convert undef to 'undef' so its readable.
    my $msg = join '', map { defined($_) ? $_ : 'undef' } @msgs;

    # Escape the beginning, _print will take care of the rest.
    $msg =~ s/^/# /;

    local( $\, $", $, ) = ( undef, ' ', '' );
    print $fh $msg;

    return 0;
}

# This is used by Test::SharedFork to turn on IPC after the fact. Not
# documenting because I do not want it used. The method name is borrowed from
# Test::Builder 2
# Once Test2 stuff goes stable this method will be removed and Test::SharedFork
# will be made smarter.
sub coordinate_forks {
    my $self = shift;

    {
        local ($@, $!);
        require Test2::IPC;
    }
    Test2::IPC->import;
    Test2::API::test2_ipc_enable_polling();
    Test2::API::test2_load();
    my $ipc = Test2::IPC::apply_ipc($self->{Stack});
    $ipc->set_no_fatal(1);
    Test2::API::test2_no_wait(1);
}

sub no_log_results { $_[0]->{no_log_results} = 1 }

1;

__END__

#line 2121


