package TLily::User;

use strict;
use vars qw(@ISA @EXPORT_OK);

use Carp;
use Text::Abbrev;
use Exporter;

use TLily::Config qw(%config);

@ISA = qw(Exporter);
@EXPORT_OK = qw(&help_r &shelp_r &command_r);

=head1 NAME

TLily::User - User command manager.

=head1 DESCRIPTION

This module manages user commands (%commands), and help for these commands.

=head2 FUNCTIONS

=over 10

=cut


# All commands.  Names are commands, values are command functions.
my %commands;

# Abbreviation mapping, generated by Text::Abbrev.
my %abbrevs;

# Help pages.
my %help;

# Short help text for commands.
my %shelp;


sub init {
    TLily::Registrar::class_r("command"    => \&command_u);
    TLily::Registrar::class_r("short_help" => \&command_u);
    TLily::Registrar::class_r("help"       => \&command_u);

    TLily::Event::event_r(type  => "user_input",
			  order => "during",
			  call  => \&input_handler);

    command_r(help => \&help_command);
    shelp_r(help => "Display help pages.");
    help_r(commands => \&command_help);
    help_r(help => '
Welcome to Tigerlily!

Tigerlily is a client for the lily CMC, written entirely in 100% pure Perl.

For a list of commands, try "%help commands".
');
}


=item command_r($name, $sub)

Registers a new %command.  %commands are tracked via TLily::Registrar.

  TLily::User::command_r("quit" => sub { exit; });

=cut

sub command_r {
    my($command, $sub) = @_;
    TLily::Registrar::add("command" => $command);
    $commands{$command} = $sub;
    %abbrevs = abbrev keys %commands;
}


=item command_u($name)

Deregisters an existing %command.

  TLily::User::command_u("quit");

=cut

sub command_u {
    my($command) = @_;
    TLily::Registrar::remove("command" => $command);
    delete $commands{$command};
    %abbrevs = abbrev keys %commands;
}


=item shelp_r

Sets the short help for a command.  This is what is displayed by the
command name in the "/help commands" listing.  Short help is tracked
via TLily::Registrar.

    TLily::User::shelp_r("help" => "Display help pages.");

=cut

sub shelp_r {
    my($command, $help) = @_;
    TLily::Registrar::add("short_help" => $command);
    $shelp{$command} = $help;
}


=item shelp_u

Clears the short help for a command.

    TLily::User::shelp_u("help");

=cut

sub shelp_u {
    my($command) = @_;
    TLily::Registrar::remove("short_help" => $command);
    delete $shelp{$command};
}


=item help_r

Sets a help page.  Help is tracked via TLily::Registrar.

    TLily::User::shelp_r("lily" => $help_on_lily);

=cut

sub help_r {
    my($topic, $help) = @_;
    TLily::Registrar::add("help" => $topic);
    if (!ref($help)) {
	# Eliminate all leading newlines, and enforce only one trailing
	$help =~ s/^\n*//s; $help =~ s/\n*$/\n/s;
    }
    $help{$topic} = $help;
}


=item help_u

Clears a help page.

    TLily::User::shelp_r("lily" => $help_on_lily);

=cut

sub help_u {
    my($topic) = @_;
    TLily::Registrar::remove("help" => $topic);
    delete $help{$topic};
}


# Input handler to parse %commands.
sub input_handler {
    my($e, $h) = @_;

    return unless ($e->{text} =~ /^\s*([%\/])(\w+)\s*(.*?)\s*$/);
    my $command = $abbrevs{$2};

    return if ($1 ne "%" && !grep($_ eq $command, @{$config{slash}}));

    unless ($command) {
	$e->{ui}->print("(The \"$2\" command is unknown.)\n");
	return 1;
    }

    #$commands{$command}->($e->{ui}, $3, $command);
    $commands{$command}->($e->{ui}, $3);
    return 1;
}


# Display the "/help commands" help page.
sub command_help {
    my($ui, $arg) = @_;

    $ui->indent("? ");
    $ui->print("Tigerlily client commands:\n");

    my $c;
    foreach $c (sort keys %commands) {
	$ui->printf("  %%%-15s", $c);
	$ui->print($shelp{$c}) if ($shelp{$c});
	$ui->print("\n");
    }

    $ui->indent("");
}


# %help command.
sub help_command {
    my($ui, $arg) = @_;
    $arg = "help" if ($arg eq "");
    $arg =~ s/^%//;

    unless ($help{$arg}) {
	$ui->print("(there is no help on \"$arg\")\n");
    }

    elsif (ref($help{$arg}) eq "CODE") {
	$help{$arg}->($ui, $arg);
    }

    else {
	$ui->indent("? ");
	$ui->print($help{$arg});
	$ui->indent("");
    }
}


=back

=cut

1;
