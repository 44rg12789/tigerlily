# -*- Perl -*-
# $Header: /home/mjr/tmp/tlilycvs/lily/tigerlily2/extensions/server.pl,v 1.18 1999/04/27 18:13:09 neild Exp $

use strict;

use TLily::UI;
use TLily::Server::SLCP;
use TLily::Event;


sub connect_command {
    my($ui, $arg) = @_;
    my(@argv) = split /\s+/, $arg;
    TLily::Event::keepalive();

    my($host, $port, $user, $pass) = @argv;

    if (!defined $host) {
	if (!defined($config{server})) {
	    $ui->print("(no default server specified)\n");
	    return;
	}

	$host = $config{server};
	$port = $config{port};
    }

    # Expand host aliases.
    if (!defined($port) && $config{server_info}) {
	foreach my $i (@{$config{server_info}}) {
	    if ($host eq $i->{alias}) {
		($host, $port) = ($i->{host}, $i->{port});
		last;
	    }
	}
    }

    # Pick out autologin information.
    if ($config{server_info}) {
	foreach my $i (@{$config{server_info}}) {
	    if ($host eq $i->{host}) {
		$port = $i->{port} if (!defined $port);
		if ($port == $i->{port}) {
		    ($user, $pass) = ($i->{user}, $i->{pass});
		    last;
		}
	    }
	}
    }

    my $server;
    $server = TLily::Server::SLCP->new(host      => $host,
				       port      => $port,
				       user      => $user,
				       password  => $pass,
				       'ui_name' => $ui->name);
    return unless $server;

    $server->activate();
}
command_r('connect' => \&connect_command);
shelp_r('connect' => "Connect to a server.");
help_r('connect' => "
Usage: %connect [host] [port]

Create a new connection to a server.
");


sub close_command {
    my($ui, $arg) = @_;
    my(@argv) = split /\s+/, $arg;
    TLily::Event::keepalive();

    my $server = TLily::Server::name();
    if (!$server) {
	$ui->print("(you are not currently connected to a server)\n");
	return;
    }

    $ui->print("(closing connection to \"", scalar($server->name()), "\")\n");
    $server->terminate();
    return;
}
command_r('close' => \&close_command);
shelp_r('close' => "Close the connection to the current server.");
help_r('close' => "
Usage: %close

Close the connection to the current server.
");


sub next_server {
    my($ui, $command, $key) = @_;

    my @server = TLily::Server::name();
    my $server = TLily::Server::name() || $server[-1];

    my $idx = 0;
    foreach (@server) {
	last if ($_ == $server);
	$idx++;
    }

    $idx = ($idx + 1) % @server;
    $server = $server[$idx];
    $server->activate();
    $ui->print("(switching to server \"", scalar($server->name()), "\")\n");
    return;
}
TLily::UI::command_r("next-server" => \&next_server);
TLily::UI::bind("C-q" => "next-server");


sub send_handler {
    my($e, $h) = @_;
    $e->{server}->sendln(join(",",@{$e->{RECIPS}}),$e->{dtype},$e->{text});
}
event_r(type => 'user_send',
	call => \&send_handler);

sub to_server {
    my($e, $h) = @_;
    my $server = server_name();

    if (! $server) {
	# we aren't connected to a server
	return 1;
    }

    $server->command($e->{ui}, $e->{text});
}
event_r(type  => "user_input",
	order => "after",
	call  => \&to_server);
