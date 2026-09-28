package TurboPerl::Debug::Bridge;

# The Perl half of TurboPerl's integrated debugger.
#
# Devel::ebug does the debugging; this turns it into something the IDE can
# talk to.  Two reasons it exists rather than having the IDE speak to
# Devel::ebug directly:
#
#   - Devel::ebug is a Perl library, and the IDE is Free Pascal.
#   - Every time the program stops, the IDE wants the location, the call
#     stack, the visible variables, every watch expression and whatever the
#     program printed since last time.  Asking Devel::ebug for those one at
#     a time is six round trips per single step.  Here they are gathered
#     into one "stopped" message.
#
# Protocol: one JSON object per line, in both directions.  Requests carry a
# "cmd" and an optional "seq" which is echoed back.  Nothing but protocol
# ever goes to stdout; warnings and diagnostics go to stderr.
#
# Invoked as:
#   perl -I<libdir> -MTurboPerl::Debug::Bridge -e 'TurboPerl::Debug::Bridge::run()'

use strict;
use warnings;

use Devel::ebug;
use Scalar::Util qw( blessed reftype refaddr looks_like_number );

our $VERSION = '1.0';

my $JSON;

sub _json {
  return $JSON if $JSON;
  foreach my $class (qw( Cpanel::JSON::XS JSON::PP )) {
    (my $pm = "$class.pm") =~ s{::}{/}g;
    next unless eval { require $pm; 1 };
    $JSON = $class->new->utf8->canonical->allow_nonref;
    last;
  }
  die "no JSON module available (need Cpanel::JSON::XS or JSON::PP)\n"
    unless $JSON;
  return $JSON;
}

# ---------------------------------------------------------------- state

my $ebug;           # the Devel::ebug session, undef when not running
my @watches;        # expressions evaluated at every stop
my $sent_output;    # how much of the program's output the IDE already has
my $program;        # remembered so that 'restart' can start over
my @program_args;

# ---------------------------------------------------------------- output

# Real JSON booleans rather than 1 and 0.  A client in another language
# reads "finished": true without having to know that this end happens to
# spell truth as an integer; Free Pascal's fpjson, for one, will not coerce
# between the two.  A reference to 1 or 0 encodes as a boolean under both
# JSON::PP and Cpanel::JSON::XS, so this does not depend on which is loaded.
sub _bool { return $_[0] ? \1 : \0 }

sub emit {
  my($msg) = @_;
  print _json()->encode($msg), "\n";
  return;
}

sub fail {
  my($seq, $message) = @_;
  $message =~ s/\s+\z// if defined $message;
  emit({ ev => 'error', seq => $seq, message => "$message" });
  return;
}

# Values shown in the watch and variable panes have to be short enough to
# put in a list box, and must survive being turned into JSON.
sub display {
  my($value, $limit) = @_;
  return trim(summarise($value), $limit);
}

sub trim {
  my($text, $limit) = @_;
  $limit ||= 200;
  $text = "$text";    # a string in the JSON, even when it looks like a number
  $text =~ s/[\r\n\t]/ /g;
  $text = substr($text, 0, $limit - 3) . '...' if length($text) > $limit;
  return $text;
}

# A one-line picture of a value, written the way Perl would write it:
# [1, 2, 3] rather than ARRAY(0x55d0c3a8).  Devel::ebug hands back copies
# of the program's data, not the data itself, so this is free to walk them.
# Deep or long structures are cut short; display() trims the rest.
use constant {
  SUMMARY_DEPTH => 3,     # levels of nesting shown before "..."
  SUMMARY_ITEMS => 20,    # elements of one array or hash shown
};

sub summarise {
  my($value, $depth, $seen) = @_;
  $depth ||= 0;
  $seen  ||= {};

  return 'undef' unless defined $value;
  return $depth ? _quote($value) : "$value" unless ref $value;

  my $class = blessed $value;
  my $type  = reftype $value;
  my $addr  = refaddr $value;

  # Something already on the way down: a structure that contains itself.
  return '...' if $seen->{$addr};
  local $seen->{$addr} = 1;

  my $inner;
  if ($type eq 'ARRAY') {
    $inner = $depth >= SUMMARY_DEPTH && @$value ? '[...]'
           : '[' . _items(map { summarise($_, $depth + 1, $seen) } @$value) . ']';
  }
  elsif ($type eq 'HASH') {
    $inner = $depth >= SUMMARY_DEPTH && %$value ? '{...}'
           : '{' . _items(map { _key($_) . ' => ' . summarise($value->{$_}, $depth + 1, $seen) }
                          sort keys %$value) . '}';
  }
  elsif ($type eq 'SCALAR' || $type eq 'REF') {
    $inner = '\\' . summarise($$value, $depth + 1, $seen);
  }
  elsif ($type eq 'CODE') {
    $inner = 'sub { ... }';
  }
  else {
    return "$value";
  }

  return defined $class ? "$class $inner" : $inner;
}

sub _items {
  my @items = @_;
  if (@items > SUMMARY_ITEMS) {
    my $more = @items - SUMMARY_ITEMS;
    splice @items, SUMMARY_ITEMS;
    push @items, "... $more more";
  }
  return join ', ', @items;
}

sub _quote {
  my($s) = @_;
  return $s if looks_like_number($s) && $s !~ /^\s|\s$/;
  $s =~ s/(['\\])/\\$1/g;
  return "'$s'";
}

sub _key {
  my($k) = @_;
  return $k =~ /^-?[A-Za-z_]\w*\z/ ? $k : _quote($k);
}

# Devel::ebug's pad gives @arrays as a reference to a copy, which is what is
# wanted, but evaluates %hashes in scalar context and so gets only a count;
# ask for those again by reference.
sub pad_fetch {
  my($pad) = @_;
  foreach my $name (grep { /^%/ } keys %$pad) {
    my $ref = eval { $ebug->eval("\\$name") };
    $pad->{$name} = $ref if !$@ && ref $ref;
  }
  return;
}

# The same values again as a tree, for the variables pane to open out one
# level at a time.  Each node is { n => name, v => one-line summary } with
# its children in k when it has any: [0] [1] for an array, {key} for a hash,
# $* for what a scalar reference points at.  Bounded, since a stop sends
# the whole thing whether or not anyone opens it.
use constant {
  TREE_DEPTH => 8,        # levels below the variable itself
  TREE_ITEMS => 100,      # children of one node before "..."
  TREE_NODES => 2000,     # nodes in one stop, all variables together
};

sub var_tree {
  my($vars) = @_;
  my $budget = TREE_NODES;
  return [ map { _node($_, $vars->{$_}, 0, {}, \$budget) } sort keys %$vars ];
}

sub _node {
  my($name, $value, $depth, $seen, $budget) = @_;
  $$budget--;
  my %node = (n => $name,
              v => !$depth                      ? aggregate($name, $value)
                 : defined $value && !ref $value ? trim(_quote($value))
                 :                                 display($value));

  return \%node unless ref $value && $depth < TREE_DEPTH;
  my $addr = refaddr $value;
  return \%node if $seen->{$addr};
  local $seen->{$addr} = 1;

  my $type = reftype $value;
  my @kids;
  if ($type eq 'ARRAY') {
    @kids = map { [ "[$_]", $value->[$_] ] } 0 .. $#$value;
  }
  elsif ($type eq 'HASH') {
    @kids = map { [ '{' . _key($_) . '}', $value->{$_} ] } sort keys %$value;
  }
  elsif ($type eq 'SCALAR' || $type eq 'REF') {
    @kids = ([ '$*', $$value ]);
  }

  my @k;
  foreach my $kid (@kids) {
    if (@k >= TREE_ITEMS || $$budget <= 0) {
      push @k, { n => '...', v => (@kids - @k) . ' more' };
      last;
    }
    push @k, _node(@$kid, $depth + 1, $seen, $budget);
  }
  $node{k} = \@k if @k;
  return \%node;
}

# A variable's value for the panes.  Aggregates are shown in round brackets,
# as they would be written in a list assignment, to tell them apart from
# references.
sub aggregate {
  my($name, $value) = @_;
  my $text = summarise($value);
  $text = '(' . substr($text, 1, -1) . ')'
    if $name =~ /^[\@%]/ && ref $value && !blessed $value;
  return trim($text);
}

# ---------------------------------------------------------------- state report

# Everything the IDE needs to redraw itself after the program stops.
sub state_message {
  my(%extra) = @_;

  my %msg = (ev => 'stopped', %extra);

  if (!$ebug) {
    $msg{running}  = _bool(0);
    $msg{finished} = _bool(1);
    return \%msg;
  }

  $msg{running}  = _bool($ebug->running);
  $msg{finished} = _bool($ebug->finished);
  $msg{pid}      = $ebug->pid;

  # Whatever the program printed since the last stop.  Devel::ebug hands
  # back everything so far, so only the new part is sent on.
  my($out, $err) = eval { $ebug->output };
  $out = '' unless defined $out;
  $err = '' unless defined $err;
  my $all = $out . $err;
  if (length($all) > $sent_output) {
    $msg{output} = substr($all, $sent_output);
    $sent_output = length($all);
  }

  if ($ebug->finished) {
    # Nothing is on the stack any more; do not ask for a location.
    return \%msg;
  }

  $msg{file}       = $ebug->filename;
  $msg{line}       = $ebug->line + 0;
  $msg{subroutine} = $ebug->subroutine;
  $msg{package}    = $ebug->package;
  $msg{codeline}   = display($ebug->codeline, 400);

  my @stack;
  foreach my $frame (eval { $ebug->stack_trace }) {
    push @stack, {
      subroutine => scalar $frame->subroutine,
      file       => scalar $frame->filename,
      line       => $frame->line + 0,
      args       => join(', ', map { display($_, 40) } eval { $frame->args }),
    };
  }
  $msg{stack} = \@stack;

  my $pad = eval { $ebug->pad } || {};
  pad_fetch($pad);
  $msg{pad}  = { map { $_ => aggregate($_, $pad->{$_}) } keys %$pad };
  $msg{vars} = var_tree($pad);

  $msg{watches} = [ map { watch_value($_) } @watches ];

  return \%msg;
}

# A watch on a bare @array or %hash is taken to mean its contents, not the
# element count that evaluating it in scalar context would give.
sub watch_value {
  my($expr) = @_;
  my $whole = $expr =~ /^\s*([\@%]\$?[\w:]+)\s*\z/ ? $1 : undef;
  my $value = eval { $ebug->eval(defined $whole ? "\\$whole" : $expr) };
  return { expr => $expr, value => $@ ? "<error: " . display($@, 80) . ">"
                                : defined $whole ? aggregate($whole, $value)
                                : display($value) };
}

# ---------------------------------------------------------------- commands

# Ask Devel::ebug to break somewhere.  It moves forward to the next line it
# can actually break on and reports where that was, which the IDE uses to
# put its marker in the right place.
sub set_break_point {
  my($seq, $file, $line) = @_;
  my $actual = eval { $ebug->break_point($file, $line) };
  emit({
    ev     => 'breakpoint',
    seq    => $seq,
    file   => $file,
    line   => $line + 0,
    actual => (defined $actual && $actual) ? $actual + 0 : 0,
  });
  return;
}

my %HANDLER = (

  start => sub {
    my($req) = @_;
    stop_session();

    $program      = $req->{program};
    @program_args = @{ $req->{args} || [] };

    $ebug = Devel::ebug->new;
    $ebug->serializer('json');
    $ebug->program($program);
    $ebug->args(\@program_args) if @program_args;
    $ebug->backend($req->{perl} . ' -d:ebug::Backend') if $req->{perl};
    $ebug->load;

    $sent_output = 0;
    @watches     = @{ $req->{watches} || [] };

    # Breakpoints the user set before starting; report where each landed.
    foreach my $bp (@{ $req->{breakpoints} || [] }) {
      set_break_point($req->{seq}, $bp->{file}, $bp->{line});
    }

    emit(state_message(seq => $req->{seq}, started => _bool(1)));
  },

  # Movement.  Each ends with a full state report.
  run    => sub { $ebug->run;    emit(state_message(seq => $_[0]{seq})) },
  step   => sub { $ebug->step;   emit(state_message(seq => $_[0]{seq})) },
  next   => sub { $ebug->next;   emit(state_message(seq => $_[0]{seq})) },
  'return' => sub { $ebug->return; emit(state_message(seq => $_[0]{seq})) },

  # Run to a line without leaving a breakpoint behind.  If the line was not
  # breakable the break landed elsewhere, so clear whatever was actually
  # set rather than what was asked for.
  runto => sub {
    my($req) = @_;
    my $actual = $ebug->break_point($req->{file}, $req->{line});
    $ebug->run;
    $ebug->break_point_delete($req->{file}, $actual) if $actual;
    emit(state_message(seq => $req->{seq}));
  },

  undo => sub {
    my($req) = @_;
    $ebug->undo($req->{levels} || 1);
    # undo restarts the program, so the output starts over too.
    $sent_output = 0;
    emit(state_message(seq => $req->{seq}, restarted => _bool(1)));
  },

  setbp => sub {
    my($req) = @_;
    set_break_point($req->{seq}, $req->{file}, $req->{line});
  },

  clearbp => sub {
    my($req) = @_;
    $ebug->break_point_delete($req->{file}, $req->{line});
    emit({ ev => 'breakpoint', seq => $req->{seq}, file => $req->{file},
           line => $req->{line} + 0, actual => 0, cleared => _bool(1) });
  },

  eval => sub {
    my($req) = @_;
    my $value = eval { $ebug->eval($req->{expr}) };
    emit({ ev => 'value', seq => $req->{seq}, expr => $req->{expr},
           value => $@ ? "<error: " . display($@, 120) . ">" : display($value, 400) });
  },

  watch => sub {
    my($req) = @_;
    @watches = @{ $req->{watches} || [] };
    emit({ ev => 'watches', seq => $req->{seq},
           watches => [ map { watch_value($_) } @watches ] });
  },

  # The IDE signals the debuggee itself, because this process is sitting in
  # a blocking run() at the time and could not act on the request.  This is
  # here for completeness and for a stopped program.
  interrupt => sub {
    my($req) = @_;
    my $ok = eval { $ebug->interrupt } || 0;
    emit({ ev => 'interrupted', seq => $req->{seq}, ok => _bool($ok) });
  },

  status => sub { emit(state_message(seq => $_[0]{seq})) },

  stop => sub {
    my($req) = @_;
    stop_session();
    emit({ ev => 'stopped', seq => $req->{seq},
           running => _bool(0), finished => _bool(1) });
  },

  quit => sub {
    my($req) = @_;
    stop_session();
    emit({ ev => 'bye', seq => $req->{seq} });
    exit 0;
  },
);

sub stop_session {
  return unless $ebug;
  eval { $ebug->proc->die if $ebug->proc };
  undef $ebug;
  return;
}

# ---------------------------------------------------------------- main loop

sub run {
  # Protocol only on stdout, unbuffered so the IDE is never left waiting on
  # a full block.
  STDOUT->autoflush(1);

  emit({ ev => 'hello', version => $VERSION, ebug => $Devel::ebug::VERSION });

  while (my $line = <STDIN>) {
    next unless $line =~ /\S/;

    my $req = eval { _json()->decode($line) };
    if (!$req or ref $req ne 'HASH') {
      fail(undef, "could not parse request: $@");
      next;
    }

    my $cmd = $req->{cmd};
    if (!defined $cmd or !$HANDLER{$cmd}) {
      fail($req->{seq}, "unknown command: " . (defined $cmd ? $cmd : '(none)'));
      next;
    }

    if ($cmd ne 'start' and $cmd ne 'quit' and !$ebug) {
      fail($req->{seq}, "no program is loaded");
      next;
    }

    eval {
      $HANDLER{$cmd}->($req);
      1;
    } or do {
      my $error = $@ || 'unknown error';
      # A dead debuggee is a normal way for a session to end, not a crash.
      if ($ebug && !eval { $ebug->running }) {
        emit(state_message(seq => $req->{seq}));
      } else {
        fail($req->{seq}, $error);
      }
    };
  }

  stop_session();
  return;
}

1;
