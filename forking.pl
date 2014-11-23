#!/usr/bin/perl

use strict;
use warnings;

use FCGI;
use CGI::Fast;

use IO::Select;
use Data::Dumper;

my $terminate = 0;
my $PIPES_PER_INSTANCE = 2;

$\ = "\n";

$SIG{INT} = sub { $terminate = 1 };
$SIG{CHLD} = sub {};

&main;

sub main {
  if(scalar @ARGV < 3) {
      print "[$$-Manager] Error. Usage: path backlog count";
      exit(1);
  }

  print "[$$-Manager] Starting...";

  my $path    = $ARGV[0];
  my $backlog = int($ARGV[1]);
  my $count   = int($ARGV[2]);

  my $socket = FCGI::OpenSocket($path, $backlog) or die "[$$-Manager] Error. Failed to open socket.";

  my $pid;
  my %forks;

  print "[$$-Manager] Initializing pipes...";
  my ($fcgi_pipes, $db_pipes) = init_pipes($count);

  print "[$$-Manager] Starting FCGI childs...";
  for(my $i = 0; $i < $count; $i++) {
    unless($pid = fork()) {
      close_pipes($db_pipes);
      run_fcgi($$fcgi_pipes[$i], $socket);
    }

    log_fork(\%forks, 'FCGI', $pid, $$db_pipes[$i]); #TODO what I should store here as read/write pipes
  }
  close_pipes($fcgi_pipes);

  print "[$$-Manager] Starting DB...";
  unless ($pid = fork()) {
      run_db($db_pipes);
  }
  log_fork(\%forks, 'DB', $pid); #TODO what I should store here as read/write pipes

  print "[$$-Manager] Stated all childs.\n" . Dumper(\%forks);

  FCGI::CloseSocket($socket);

  print "[$$-Manager] Closed socket";
  sleep while(!$terminate);

  print "[$$-Manager] Terminating all FCGIs";

  waitpid($_, 0) foreach (keys %forks);

  print "[$$-Manager] Exiting...";
  exit(0);
}

sub init_pipes {
  my $instance_count = shift;
  my $fcgi_pipes;
  my $db_pipes;

  my $pipe_counter = 0;

  for(my $i = 0; $i < $instance_count * $PIPES_PER_INSTANCE; $i++) {
    my $pipe = open_pipe();

    if($i % 2 == 0) {
      $$fcgi_pipes[ $pipe_counter ]->{read}  = $pipe->{read};
      $$db_pipes[ $pipe_counter]->{write}    = $pipe->{write};
    } else {
      $$fcgi_pipes[ $pipe_counter ]->{write} = $pipe->{write};
      $$db_pipes[ $pipe_counter ]->{read}    = $pipe->{read};

      $pipe_counter++;
    }
  }

  return ($fcgi_pipes, $db_pipes);
}

sub open_pipe {
  my ($READ, $WRITE);

  pipe($READ, $WRITE);
  $WRITE->autoflush(1);

  return {
    read  => $READ,
    write => $WRITE
  };
}

sub close_pipes {
  my $pipes = shift;

  $pipes = [$pipes] if(ref($pipes) eq 'HASH');

  foreach my $pipe (@{$pipes}) {
    close($pipe->{write}) or warn "[$$] Can't close WRITE pipe";
    close($pipe->{read})  or warn "[$$] Can't close READ pipe";
  }

  return;
}

sub log_fork {
  my ($log_storage, $type, $pid, $pipe) = @_;

  $log_storage->{$pid} = {
              type  => $type,
              pipes => $pipe,
  };
}

sub run_db {
  my $pipes = shift;

  print "[$$-DB] Started";

  my $response;
  my $buff_size = 1024;
  my $select_read_handler = IO::Select->new();


  for(my $i = 0; $i < scalar(@$pipes); $i++) {
    $select_read_handler->add($pipes->[$i]->{read});
    # my $WRITE = $pipes->[$i]->{write};
  }

  print STDOUT "[$$-DB] I have " . $select_read_handler->count() . " READ handlers";

  while(my @ready_handlers = $select_read_handler->can_read()) {
    foreach my $rh (@ready_handlers) {
      my $bytes = sysread($rh, $response, $buff_size);
      chomp($response);

      print STDOUT "[$$-DB] I received message \"$response\"";
    }
  }

  close_pipes($pipes);
  print "[$$-DB] Closed pipes...";

  exit(0);
}

sub run_fcgi {
    my ($pipe, $socket) = @_;

    $CGI::Fast::Ext_Request = FCGI::Request(
      \*STDIN, \*STDOUT, \*STDERR,
      \%ENV, int($socket || 0), 1
    );

    print "[$$-FCGI] Created";

    handle_fcgi_requests($pipe);

    close_pipes($pipe);
    print "[$$-FCGI] Closed pipes...";

    exit(0);
}

sub handle_fcgi_requests {
  my $pipe = shift;

  my $READ  = $pipe->{read};
  my $WRITE = $pipe->{write};

  my $count = 0;
  my $request;

  while($request = CGI::Fast->new) {
    print $WRITE "I'm $$";
    # print "Content-type:text/plain;charset=utf-8\r\n\r\n";
    # print "[$$]\n";
    # print "Counter: $count";
    # ++$count;
    #
    # print $WRITE "$count";

    build_html($request);
  }
}

sub build_html {
  my $request = shift;
  my $params = $request->Vars;

  print "Content-type:text/html;charset=utf-8\r\n\r\n";

  print <<EOD;
<!DOCTYPE html>
<html>
  <head>
  <meta http-equiv="Content-Type" content="text/html; charset=utf-8">
EOD
print "<title>Welcome</title>";
print <<EOD;
  </head>
  <body>
EOD

print "<h3>I'm [$$-FCGI] instance</h3>";


if((keys %$params) != 0) {
  build_welcome_html();
} else {
  build_login_html();
}

print <<EOD;
  </body>
<html>
EOD
}

sub build_login_html {
  print <<EOD;
  <h1>LOGIN<h1>
<html>
EOD
}

sub build_welcome_html {
  print <<EOD;
  <h1>WELCOME</h1>
EOD
}
