# -*- Perl -*-
#    TigerLily:  A client for the lily CMC, written in Perl.
#    Copyright (C) 1999-2001  The TigerLily Team, <tigerlily@tlily.org>
#                                http://www.tlily.org/tigerlily/
#
#  This program is free software; you can redistribute it and/or modify it
#  under the terms of the GNU General Public License version 2, as published
#  by the Free Software Foundation; see the included file COPYING.
#

# $Id$

package TLily::User;

use strict;
use vars qw(@ISA @EXPORT_OK);

use Carp;
use Text::Abbrev;
use Exporter;
use File::Basename;
use Pod::Text;

use TLily::ExoSafe;
use TLily::Config qw(%config);
use TLily::Utils qw(&max);
use TLily::Registrar;

@ISA = qw(Exporter);
@EXPORT_OK = qw(&help_r &shelp_r &command_r);

# Pod::Text methods only operate on filehandles.  So, if IO::String
# is available, we'll try to use that instead of tempfiles, since it
# will be faster and more reliable.
my $IOSTRING_avail;
BEGIN {
    eval { require IO::String; };
    if ($@) {
        $IOSTRING_avail = 0;
        require File::Temp;
    } else {
        $IOSTRING_avail = 1;
    }
}

=head1 NAME

TLily::User - User command manager.

=head1 SYNOPSIS

     
use TLily::User;

TLily::User::init();

TLily::User::command_r(foo => \&foo);

TLily::User::shelp_r(foo => "A Foo Command");

TLily::User::help_r(foo => "Foo does stuff .. long description");

(...)

=head1 DESCRIPTION

This module manages user commands (%commands), and help for these commands.

=head1 FUNCTIONS

=over 10

=cut


# All commands.  The key is the command name.  The value is a hashref:
#   fn  => The command subroutine.
#   reg => The command Registrar.
my %commands;

# Abbreviation mapping, generated by Text::Abbrev.
my %abbrevs;

# Help pages.
my %help;

# Short help text for commands.
my %shelp;

# Short help text for TLily::* modules:
my %shelp_modules;

=item init

Initializes the user command and help subsystems.  This command should be 
called once, from tlily.PL, during client initialization.

  TLily::User::init();

=cut

sub init {
    TLily::Registrar::class_r("command"    => \&command_u);
    TLily::Registrar::class_r("short_help" => \&command_u);
    TLily::Registrar::class_r("help"       => \&command_u);

    TLily::Event::event_r(type  => "user_input",
			  order => "during",
			  call  => \&input_handler);

    command_r(help => \&help_command);
    shelp_r(help => "Display help pages.");
    help_r(commands  => sub { help_index("commands",  @_); } );
    help_r(variables => sub { help_index("variables", @_); } );
    help_r(concepts  => sub { help_index("concepts", @_); } );
    help_r(internals => sub { help_index("internals", @_); } );
    help_r(extensions => sub { help_index("extensions", @_); } );
    help_r(help => '
Welcome to Tigerlily!

Tigerlily is a client for the lily CMC, written entirely in 100% pure Perl.

For general information on how to use tlily, try "%help concepts".
For a list of commands, try "%help commands".
For a list of configuration variables, try "%help variables".
For a list of available extensions, try "%help extensions".
If you\'re interested in tlily\'s guts, try "%help internals".
');
    
    rebuild_internal_help_idx(rootdir => "$::TL_LIBDIR",
                              filter => "TLily",
                              index => "internals");

    rebuild_internal_help_idx(rootdir => "$::TL_EXTDIR",
                              index => "extensions");
}


sub rebuild_internal_help_idx {
    my %args = @_;
    my %idx_seen;

    my @files = ExoSafe::list_files($args{'rootdir'}, $args{'filter'});

    foreach my $path (@files) {
        next unless ($path =~ /\.pm$|\.pl$|\.pod$/);

        my ($name, $dir) = fileparse($path);
        $dir =~ s|/$||;

        my $index = $dir;
        $index =~ s|^\Q$args{'rootdir'}\E|$args{'index'}|;
        $index =~ s|/|::|g;
        my @dirs = split(/::/, $index);

        my $fd = ExoSafe::fetch($path);

        my $namehead = 0;
        my $found = 0;
        while(<$fd>) {
            if (/=head1 NAME/) { $namehead = 1; next }
            if (/=head1/) { $namehead = 0; last; }
            next unless $namehead;
            next if (/^\s*$/);

            # If we've gotten this far, we now have the NAME pod section.
            # Grab it.
            my ($desc) = /-\s*(.*)\s*$/;

            # Short help for this file
            shelp_r("${index}::$name" => $desc, $index);
            # Long help (POD) for this file.
            help_r("${index}::$name" => "POD:$path");

            $found++;
            last;
        }
        close($fd);

        # If we saw no POD docs, don't bother building the parent index;
        # If another file is encountered in the same index space that has
        # POD docs, it will trigger the index build.
        next unless $found;

        # Now create parent indices
        for (my $elem = $#dirs; $elem >= 0; $elem--) {
            my $seen_idx = join('::', @dirs[0 .. $elem]);
            next if $idx_seen{$seen_idx}++;

            # Listing for this index (Will list all the items in this index).
            help_r($seen_idx => sub { help_index($seen_idx, @_); } );

            # Short help for this index (in super-index)
            next if $elem == 0;
            my $parent_idx = join('::', @dirs[0 .. ($elem-1)]);
            shelp_r($seen_idx => '(index)',  $parent_idx);
        }

    }
}


=item rebuild_file_help_idx($directory [, index => "indexname"] [, prefix => "prefix")

Rebuilds the file-based on-line help directories.  This portion of the online
help is used for viewing the POD documentation in the files that make up 
tigerlily and its extensions.

The first arguement is the pathname of the directory to search for POD docs.
The index named argument is the name of the index to insert the short help
into for anything found in the directory.
The prefix named argument makes the command recurse into subdirectories, and
is intended for use on Perl module hierarchies.  It is the string to
start the name of anything found in the directory to be searched.  The
function will automatically build up a name for each module found that is
qualified relative to the prefix you first passed in.

The function will only catalog files that contain useable POD documentation,
and will ignore any directory trees that do not contain any such files.

This is primarily used internally, and is not currently exported.

=cut

sub rebuild_file_help_idx {
    my $dir = shift;
    my %args = @_;

    opendir(DIR, "$dir") ||
        warn "Can't opendir $dir: $!\n";
    my @files = readdir(DIR);
    closedir(DIR);

    my $prefix = $args{'prefix'};
    my $module;   
    my $count = 0;
    foreach $module (@files) {
        next if ($module =~ /^\./);

        local(*F);
        my $file = "$dir/$module";
        if ( -f "$file" ) {
            next unless ($file =~ /\.pm$|\.pl$|\.pod$/);

            open(F,"<$file") ||
              warn "Can't open $file: $!\n";
	   
            my $namehead=0;
            while(<F>) {
                if (/=head1 NAME/) { $namehead = 1; next }
                if (/=head1/) { $namehead = 0; last; }
                next unless $namehead;
                next if (/^\s*$/);
                my ($desc) = /-\s*(.*)\s*$/;
                shelp_r("${prefix}$module" => $desc, "$args{'index'}");
                help_r($args{'index'} => sub { help_index("$args{'index'}", @_); } );
                help_r("${prefix}$module" => "POD:$file");
                $count++;
                last;
            }
        } elsif ( -d "$file" && defined($args{'prefix'}) ) {
            my $found = rebuild_file_help_idx($file,
              index => $args{'prefix'} .  $module,
              prefix => $args{'prefix'} . $module . '::');
            shelp_r("$args{'prefix'}$module"  => "(index)", "$args{'index'}")
              if ($found);
        }
    }
    return $count;
}

=item command_r($name, $sub)

Registers a new %command.  %commands are tracked via TLily::Registrar.

  TLily::User::command_r("foo" => sub {
       my ($ui,$args) = @_;
       $ui->print("You typed %foo $args\n");
    });

The function reference in the second parameter will be invoked when the 
%command is typed, and passed two arguments: a UI object and a scalar
containing any arguments to the %command. 

=cut

sub command_r {
    my($command, $sub) = @_;
    TLily::Registrar::add("command" => $command);
    $commands{$command} = { sub => $sub,
			    reg => TLily::Registrar::default() };
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

Registers a short help page for a topic.  This will be displayed when
the user requests a help index listing, such as "%help commands".  It
takes a topic, the short description, and an optional index specification.
If the index is not specified, "commands" is assumed.
Short help pages are tracked via TLily::Registrar.

    TLily::User::shelp_r("help" => "Display help pages.");
    TLily::User::shelp_r("paste" => "Pasting multi-line text.", "concepts");

=cut

sub shelp_r {
    my($command, $help, $index) = @_;
    TLily::Registrar::add("short_help" => $command);
    if (! $index) {
	$index = "commands";
	$command = "%" . $command;
    }
    $shelp{$index}{$command} = $help;
}


=item shelp_u

De-registers a short help page.

    TLily::User::shelp_u("help");

=cut

sub shelp_u {
    my($command) = @_;
    TLily::Registrar::remove("short_help" => $command);
    foreach (keys %shelp) {
	delete $shelp{$_}{$command};
    }
}


=item help_r

Sets a help page.  Help is tracked via TLily::Registrar.

    TLily::User::help_r("lily" => $help_on_lily);

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



=head1 HANDLERS

=over 10

=item input_handler

Input handler to parse %commands.
This is registered automatically by init().    

=cut

sub input_handler {
    my($e, $h) = @_;

    return unless ($e->{text} =~ /^\s*([%\/])(\w+)\s*(.*?)\s*$/);
    my $char = $1;
    my $command = $abbrevs{lc($2)};

    unless (length($command) > 0 || $char eq '/' ) {
	$e->{ui}->print("(The \"$2\" command is unknown.)\n");
	return 1;
    }

    return if ($char ne "%" && !TLily::Config::ask($command));

    #$commands{$command}->($e->{ui}, $3, $command);
    $commands{$command}{reg}->push_default() if $commands{$command}{reg};
    $commands{$command}{sub}->($e->{ui}, $3, $e->{startup});
    TLily::Registrar::pop_default($commands{$command}{reg})
      if $commands{$command}{reg};
    return 1;
}


=item help_index

Help handler to display the contents of a help index.
This is registered automatically by init().    

=cut

sub help_index {
    my($index, $ui, $arg) = @_;

    $ui->indent("? ");
    $ui->print("Tigerlily client $index:\n");

    my $length = 0;
    foreach (sort keys %{$shelp{$index}}) {
        $length = max($length, length($_));
    }
    $length += 3;

    my $c;
    foreach $c (sort keys %{$shelp{$index}}) {
	$ui->printf("  %-${length}s", $c);
	$ui->print($shelp{$index}{$c}) if ($shelp{$index}{$c});
	$ui->print("\n");
    }

    $ui->indent("");
}

=item help_command

Command handler to provide the %help command.
This is registered automatically by init().    

=cut

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
    
    elsif ($help{$arg} =~ /^POD:(\S+)/) {
        my $in_fh = ExoSafe::fetch($1);
        my $out_fh;
        my $parser = Pod::Text->new(sentence => 0, width => 77);

        # If IO::String is available, we'll use that, since it will
        # be faster and more reliable than tempfiles.
        if ($IOSTRING_avail) {
            $out_fh = IO::String->new(my $out_str);
        } else {
            $out_fh = File::Temp->new(UNLINK => 1, SUFFIX => '.txt');
        }

        $parser->parse_from_filehandle($in_fh, $out_fh);
        seek($out_fh, 0, 0);
        local $/ = undef;

        $ui->indent("? ");
        $ui->print(<$out_fh>);
        $ui->indent("");
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
