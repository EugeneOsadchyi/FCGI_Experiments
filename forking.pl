#!/usr/bin/perl

use strict;
use warnings;

use FCGI;
use CGI::Fast;

use IO::Handle;
use IO::Select;
use Data::Dumper;

use constant PIPES_PER_INSTANCE => 2;

use constant NEW_USER => 0;
use constant OLD_USER => 1;
use constant NOT_VALID_VALUE => -1;

my $terminate = 0;

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

  my %DB_STORAGE;
  print "[$$-DB] Started";

  my %handlers; #TODO find better name
  my $response;
  my $buff_size = 1024;

  my $io_handler = IO::Handle->new();
  my $select_read_handler = IO::Select->new();


  for(my $i = 0; $i < scalar(@$pipes); $i++) {  #TODO find better solution (maybe extract some method)
    my $handler_id = fileno($pipes->[$i]->{read});
    $handlers{$handler_id} = $pipes->[$i]->{write};

    $select_read_handler->add($pipes->[$i]->{read});
  }

  print STDOUT "[$$-DB] I have " . $select_read_handler->count() . " READ handlers";

  while(my @ready_handlers = $select_read_handler->can_read()) {
    foreach my $rh (@ready_handlers) {
      my $wh = $handlers{fileno($rh)};
      my $bytes = sysread($rh, $response, $buff_size);
      chomp($response);


      my ($pid, $user_name) = split(",", $response);
      print STDOUT "[$$-DB] Receiced data from $pid";
      $user_name =~ s/^\s*(\w+)\s*$/$1/;

      print STDERR $user_name;
      my $prepared_data;

      if($user_name !~ /^\s*\w+\s*$/) {
        $prepared_data = NOT_VALID_VALUE;
      } elsif(exists($DB_STORAGE{$user_name})) {
        $prepared_data = join(",", OLD_USER, $user_name);
      } else {
        $DB_STORAGE{$user_name} = 1;
        $prepared_data = join(",", NEW_USER, $user_name)
      }

      print STDERR $prepared_data;
      print $wh $prepared_data;
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

  my $READ_HANDLER  = $pipe->{read};
  my $WRITE_HANDLER = $pipe->{write};

  my $buff_size = 1024;
  my $count = 0;
  my $request;
  my $response;

  while($request = CGI::Fast->new) {
    my $params = $request->Vars;

    if($params->{user_name}) {
      print "Have user name";
      print $WRITE_HANDLER "$$, " . $params->{user_name};
      my $bytes = sysread($READ_HANDLER, $response, $buff_size); #TODO make a cover method for this
    }
print STDERR "Splitting";
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
