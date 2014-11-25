#!/usr/bin/perl

use strict;
use warnings;

use FCGI;
use CGI::Fast;

use IO::Handle;
use IO::Select;
use Data::Dumper;

use constant PIPES_PER_INSTANCE => 2;
use constant READ_BUFFER_SIZE   => 1024;

use constant NEW_USER         => 0;
use constant OLD_USER         => 1;
use constant NOT_VALID_VALUE  => -1;

my $terminate = 0;

$\ = "\n";

$SIG{INT} = sub { $terminate = 1 };
$SIG{CHLD} = sub {};

&main;

sub main {
  if(scalar @ARGV < 3) {
      print "[$$-Manager] Error. Usage: path backlog count";
      exit();
  }

  print "[$$-Manager] Starting...\n";

  my $path    = $ARGV[0];
  my $backlog = int($ARGV[1]);
  my $count   = int($ARGV[2]);

  my $socket = FCGI::OpenSocket($path, $backlog) or die "[$$-Manager] Error. Failed to open socket.";

  my $pid;
  my $forks = {};

  my ($fcgi_pipes, $db_pipes) = init_pipes($count);

  print "[$$-Manager] Starting FCGI childs...";
  for(my $i = 0; $i < $count; $i++) {
    unless($pid = fork()) {
      close_pipes($db_pipes);
      run_fcgi(${$fcgi_pipes}[$i], $socket);
    }

    log_fork($forks, 'FCGI', $pid, ${$db_pipes}[$i]);
  }
  close_pipes($fcgi_pipes);

  print "[$$-Manager] Starting DB...";
  unless ($pid = fork()) {
      run_db($db_pipes);
  }
  log_fork($forks, 'DB', $pid);

  FCGI::CloseSocket($socket);

  print "[$$-Manager] Stated all childs. In deep sleep mode now...";
  sleep while(!$terminate);

  print "[$$-Manager] Terminating all child processes";
  waitpid($_, 0) foreach (keys %{$forks});

  exit(0);
}

sub close_all_connections {
  my $socket;
  my $pipes;

  FCGI::CloseSocket($socket) if($socket);
  close_pipes($pipes) if($pipes);

  return;
}

sub init_pipes {
  my $instance_count = shift;
  my $fcgi_pipes;
  my $db_pipes;

  my $pipe_counter = 0;

  for(my $i = 0; $i < $instance_count * PIPES_PER_INSTANCE; $i++) {
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

sub open_pipe() {
  my ($READ, $WRITE);

  pipe($READ, $WRITE);
  $WRITE->autoflush(1);

  return {
    read  => $READ,
    write => $WRITE
  };
}

sub close_pipes($) {
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

  return;
}

sub run_db {
  my $pipes = shift;

  my %DB_STORAGE;
  print "[$$-DB] Started";

  my %read_handler_to_write_handler_list;
  my $response;

  my $select_read_handler = IO::Select->new();

  %read_handler_to_write_handler_list = build_read_to_write_handlers_map($pipes);
  $select_read_handler = add_all_read_handlers($select_read_handler, $pipes);

  while(my @ready_to_read_handlers = $select_read_handler->can_read()) {
    foreach my $rh (@ready_to_read_handlers) {
      my $response = listen_pipe($rh);
      my $prepared_data = process_data($response, \%DB_STORAGE); #TODO Dont like this method

      define_write_handler_and_write_to_pipe($rh, \%read_handler_to_write_handler_list, $prepared_data); #TODO Dont like this method
    }
  }

  print "[$$-DB] Closing all connections and exiting...";
  close_all_connections($pipes);

  exit(0);
}

sub build_read_to_write_handlers_map {
  my $pipes = shift;

  my %handlers;
  my $handler_id;

  foreach my $pipe (@$pipes) {
    $handler_id = fileno($pipe->{read});
    $handlers{$handler_id} = $pipe->{write};
  }

  return %handlers;
}

sub add_all_read_handlers {
  my $select_read_handler = shift;
  my $pipes = shift;

  foreach my $pipe (@$pipes) {
    $select_read_handler->add($pipe->{read});
  }

  return $select_read_handler;
}

sub listen_pipe {
  my $rh = shift;
  my $response;

  my $bytes = sysread($rh, $response, READ_BUFFER_SIZE);
  chomp($response);

  return $response;
}

sub define_write_handler_and_write_to_pipe {
  my $rh = shift;
  my $handlers = shift;
  my $prepared_data = shift;

  my $wh = $handlers->{fileno($rh)};
  print $wh $prepared_data;

  return 0;
}

sub process_data {
  my $response = shift;
  my $DB_STORAGE = shift;
  my $prepared_data;

  my ($pid, $user_name) = split(",", $response);
  $user_name =~ s/^\s*(\w+)\s*$/$1/;

  if($user_name !~ /\w+/) {
    $prepared_data = NOT_VALID_VALUE;
  } elsif(exists($DB_STORAGE->{$user_name})) {
    $prepared_data = join(",", OLD_USER, $user_name);
  } else {
    $DB_STORAGE->{$user_name} = 1;
    $prepared_data = join(",", NEW_USER, $user_name)
  }

  return $prepared_data;
}


sub run_fcgi {
    my ($pipe, $socket) = @_;

    $CGI::Fast::Ext_Request = FCGI::Request(
      \*STDIN, \*STDOUT, \*STDERR,
      \%ENV, int($socket || 0), 1
    );

    print "[$$-FCGI] Started";

    handle_fcgi_requests($pipe);

    print "[$$-FCGI] Closing all connections and exiting...";
    close_all_connections($socket, $pipe);

    exit(0);
}

sub handle_fcgi_requests {
  my $pipe = shift;

  my $READ_HANDLER  = $pipe->{read};
  my $WRITE_HANDLER = $pipe->{write};

  my $request;

  while($request = CGI::Fast->new) {
    my $response;
    my $params = $request->Vars;

    if($params->{user_name}) {
      print $WRITE_HANDLER "$$, " . $params->{user_name};
      $response = listen_pipe($READ_HANDLER);
    }

    my @fields = split(",", $response);

    build_html(\@fields);
  }
}

sub build_html {
  my $response = shift;

  my ($status, $user_name) = @{$response};

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

print "<h3>[$$-FCGI]</h3>";


if($user_name) {
  build_welcome_html($status, $user_name);
} else {
  build_login_html($status);
}

print <<EOD;
  </body>
<html>
EOD
}

sub build_login_html {
  my $status= shift;

  print "<h1>LOGIN<h1>";
  print "<h3 style='color:red;'>You entered not valid data</h3>" if($status == NOT_VALID_VALUE);
  print <<EOD;
  <form id="login_form" enctype="multipart/form-data" method="post">
    <input id="user_name" name="user_name" placeholder="User Name"/>
  <button type="submit">Send</button>
  </form>
<html>
EOD
}

sub build_welcome_html {
  my ($status, $user_name) = @_;

  print "<h1>WELCOME</h1>";
  print "<p>" . ($status == NEW_USER ? "You just created new user " : "You logged in as "). "$user_name</p>";
}
