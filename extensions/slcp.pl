# $Header: /home/mjr/tmp/tlilycvs/lily/tigerlily2/extensions/Attic/slcp.pl,v 1.4 1999/02/25 01:06:10 neild Exp $

use strict;

use LC::Global qw($event);

=head1 NAME

slcp.pl - The lily event parser

=head1 DESCRIPTION

The parse module translates all output from the server into internal
TigerLily events.  All server protocol support resides here.  We now support
the SLCP protocol.

=head1 KNOWN BUGS

- need to queue events until SLCP sync is complete
- UI escaping is breaking SLCP parser.
- Discussion destruction handler

=back

=cut

my %keep;
$keep{USER} = {HANDLE   => 1,
               LOGIN    => 1,
	       NAME     => 1,
	       BLURB    => 1,
	       STATE    => 1};
$keep{DISC} = {HANDLE   => 1, 
               CREATION => 1,
	       NAME     => 1,
	       TITLE    => 1};

my %events =
  (
   'connect'     => undef,
   disconnect    => undef,
   attach        => undef,
   detach        => undef,
   here          => undef,
   away          => undef,
   'rename'      => 'NAME',
   blurb         => 'BLURB',
   info          => undef,
   ignore        => undef,
   unignore      => undef,
   unidle        => undef,
   public        => undef,
   private       => undef,
   create        => undef,
   destroy       => undef,
   permit        => undef,
   depermit      => undef,
   'join'        => undef,
   quit          => undef,
   retitle       => 'TITLE',
   review        => undef,
   sysmsg        => undef,
   sysalert      => undef,
   emote         => undef,
   pa            => undef,
   game          => undef,
   consult       => undef,
  );

my @login_prompts   = ('.*\(Y\/n\)\s*$',  # ' (Emacs parser hack)
		       '^--> ',
		       '^login: ',
		       '^password: ');

my @connect_prompts = ('^\&password: ',
		       '^--> ',
		       '^\* ');

my $SLCP_WARNING =
  "This server does not appear to support SLCP properly.  Tigerlily \
now requires SLCP support to function properly.  Either upgrade your Lily \
server to the latest version or use another (1.x) version of tlily.\n";


sub set_client_options {
	my($serv) = @_;
	$serv->sendln('#$# options +leaf-notify +leaf-cmd +connected');
	$serv->{OPTIONS_SET} = 1;
	return;
}


# Take raw server output, and deal with it.
sub parse_raw {
	my($event, $handler) = @_;

	my $serv = $event->{server};

	# Divide into lines.
	$serv->{pending} .= $event->{data};
	my @lines = split /\r?\n/, $serv->{pending}, -1;
	$serv->{pending}  = pop @lines;

	# Try to handle prompts; a prompt is a non-newline terminated line.
	# The difficulty is that we need to distinguish between prompts (which
	# are lines lacking newlines) and partial lines (which are lines which
	# we haven't completely read yet).
	my $prompt;
	for $prompt ($serv->{logged_in} ? @connect_prompts : @login_prompts) {
		if ($serv->{pending} =~ /($prompt)/) {
			push @lines, $1;
			substr($serv->{pending}, 0, length($1)) = "";
		}
	}

	# For general efficiency reasons, I'm not sending these as
	# events.  Should I, perhaps?  This could easily be false
	# efficiency.  Parsing everything like this is definately
	# going to kill interactive latancy, however: I recommend
	# implementing idle events, and parsing these when idle.
	foreach (@lines) {
		parse_line($serv, $_);
	}

	return;
}


# The big one: take a line from the server, and decide what it is.
sub parse_line {
	my($serv, $line) = @_;
	chomp $line;

	my $ui;
	$ui = LC::UI::name($serv->{ui_name}) if ($serv->{ui_name});

	my $cmdid;
	my %event;

	# prompts #############################################################

	my $p;
	foreach $p ($serv->{logged_in} ? @connect_prompts : @login_prompts) {
		if ($line =~ /$p/) {
			set_client_options($serv) if (!$serv->{OPTIONS_SET});
			%event = (type => 'prompt',
				  text => $line);
			$event{password} = 1 if ($line =~ /password/);
			goto found;
		}
	}


	# prefixes ############################################################

	# %command, all cores.
	if ($line =~ s/^%command \[(\d+)\] //) {
		$cmdid = $1;
	}

	# %g
	if ($line =~ s/^%g//) {
		$serv->{BELL} = 1;
	}


	# SLCP ################################################################

	# SLCP "%USER" and "%DISC" messages, used to sync up the
	# initial client state database.
	if ($line =~ /^%USER /) {

		$ui->print("(please wait, synching with SLCP)\n")
		  if ($ui && !$serv->{SLCP_SYNC});
		$serv->{SLCP_SYNC} = 1;

		my %args = SLCP_parse($line);
		foreach (keys %args) {
			delete $args{$_} unless $keep{USER}{$_};
		}

		$serv->state(%args);

		return;
	}

	if ($line =~ /^%DISC /) {
		my %args = SLCP_parse($line);
		foreach (keys %args) {
			delete $args{$_} unless $keep{DISC}{$_};
		}

		$serv->state(%args);

		return;
	}

	# SLCP "%DATA" messages. 
	if ($line =~ /^%DATA /) {
		my %args = SLCP_parse($line);

		# Sanity check: do we know all these events?
		if ($args{NAME} eq "events") {
			my $e;
			foreach $e (split /,/, $args{VALUE}) {
				if (!exists($events{lc($e)})) {
					warn "Unknown event type: \"$e\".\n";
				}
			}
		}

		$serv->state(DATA => 1, %args);

		# Debugging. :>
		return if ($serv->{logged_in});
		%event = (type   => 'text',
			  NOTIFY => 1,
			  text   => $line);
		goto found;
	}

	# SLCP %NOTIFY messages.  We pretty much just push these through to 
	# tlily's internal event system.
	if ($line =~ /^%NOTIFY /) {
		%event = SLCP_parse($line);

		# SLCP bug?!
		# Fixed, I think.  -DN
		#if ($event{EVENT} =~ /emote|public|private/) {
		#	$event{NOTIFY} = 1;
		#}

		$event{SHANDLE} = $event{SOURCE};
		$event{SOURCE}  = $serv->get_name(HANDLE => $event{SOURCE});

		if ($event{RECIPS}) {
			$event{RHANDLE} = [ split /,/, $event{RECIPS} ];
			$event{RECIPS}  =
			  join(", ",
			       map { $serv->get_name(HANDLE => $_) }
			       @{$event{RHANDLE}});
		}

		# Um.  Undef?  Don't set it at all?
		$event{VALUE} = undef if $event{EMPTY};

		# Update the state database, if necessary.
		my $param = $events{$event{EVENT}};
		if ($param) {
			$serv->state(HANDLE => $event{SHANDLE},
				     $param => $event{VALUE});
		}

		if (exists($events{$event{EVENT}})) {
			$event{type} = $event{EVENT};
		} else {
			$event{type}  = "slcp_unknown";
		}

		# This will only be used if no formatter rewrites the text.
		$event{text}  = "(notify: $event{SOURCE}";
		$event{text} .= " -> $event{RECIPS}"       if ($event{RECIPS});
		$event{text} .= ": $event{EVENT}";
		$event{text} .= " = \"$event{VALUE}\""     if ($event{VALUE});
		$event{text} .= ")";
	
		if ($event{SOURCE} eq $serv->user_name) { 
			$event{isuser} = 1;
			$event{NOTIFY} = 1; # SLCP bug.
		}

		goto found;
	}


	# other %server messages ##############################################

	# %begin (command leafing)
	if ($line =~ /^%begin \[(\d+)\] (.*)/) {
		$cmdid = $1;
		%event = (type    => 'begincmd',
			  command => $2);
		goto found;
	}

	# %end, all cores.
	if ($line =~ /^%end \[(\d+)\]/) {
		$cmdid = $1;
		%event = (type => 'endcmd');
		goto found;
	}

	# %connected
	if ($line =~ /^%connected/) {
		$serv->{logged_in} = 1;
		%event = (type => 'connected',
			  text => $line);
		goto found;
	}

	# %export_file
	if ($line =~ /^%export_file (\w+)/) {
		%event = (type => 'export',
			  response => $1);
		goto found;
	}

	# The options notification.
	if ($line =~ /^%options\s+(.*?)\s*$/) {
		my @o = split /\s+/, $1;
		%event = (type    => 'options',
			  options => \@o);

		goto found if $serv->{SLCP_OK};

		if (! ($line =~ /\+leaf-notify/ &&
		       $line =~ /\+leaf-cmd/ &&
		       $line =~ /\+connected/) ) {
			warn $SLCP_WARNING;
		} else {
			$serv->{SLCP_OK} = 1;
		}

		goto found;
	}

	# check for old cores
	if  ($line =~ /type \/HELP for an introduction/) {
		warn $SLCP_WARNING unless $serv->{SLCP_OK};
	}

	# login stuff #########################################################

	# Welcome...
	if ($line =~ /^Welcome to lily.*?at (.*?)\s*$/) {
		# Set servername to $1.
	}

	# something completely unknown ########################################

	%event = (type   => 'text',
		  NOTIFY => 1,
		  text   => $line);

	# An event has been parsed.
      found:
	$event{BELL}    = 1 if ($serv->{BELL});
	$event{COMMAND} = $cmdid if ($cmdid);
	$event{server}  = $serv;
	$event{ui_name} = $serv->{ui_name};

	$serv->{BELL} = undef;

	$event->send(\%event);
	return;
}


sub load {
	$event->event_r(type => 'slcp_data',
			call => \&parse_raw);
}


sub SLCP_parse {
    my ($line) = @_;
    my %ret;

    $line =~ /^%\S+/gc;
    while (1) {
	    # OPT=len=VAL
	    if ($line =~ /\G\s*([^\s=]+)=(\d+)=/gc) {
		    $ret{$1} = substr($line, pos($line), $2);
		    last if (pos($line) + $2 >= length($line));
		    pos($line) += $2;
	    }

	    # OPT=VAL
	    elsif ($line =~ /\G\s*([^\s=]+)=(\S+)/gc) {
		    $ret{$1} = $2;
	    }

	    # OPT
	    elsif ($line =~ /\G\s*(\S+)/gc) {
		    $ret{$1} = 1;
	    }

	    else {
		    last;
	    }
    }

    return %ret;
}


1;
