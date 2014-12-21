#!/usr/bin/perl

use strict;
use warnings;

use FCGI;
use CGI::Fast;
use CGI::Cookie;

use IO::Handle;
use IO::Select;

use Data::Dumper;
use JSON;
use Template;

# constants
sub PIPES_PER_INSTANCE() { 2 };
sub READ_BUFFER_SIZE() { 1024 };
sub USER_NAME_PASS_PATTERN() { qr/^\w+$/ };
sub SURWAY_QUESTIONS() {
    return {
         surway1 => 'Field 1',
         surway2 => 'Field 2',
         surway3 => 'Field 3',
         surway4 => 'Field 4',
         surway5 => 'Field 5',
    }
}
# end of constants

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
      run_fcgi($fcgi_pipes->[$i], $socket);
    }

    log_fork($forks, 'FCGI', $pid, $db_pipes->[$i]);
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
  waitpid($_, 0) foreach (keys %$forks);

  exit(0);
}


### Working with connections ###
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
      $fcgi_pipes->[$pipe_counter]->{read}  = $pipe->{read};
      $db_pipes->[$pipe_counter]->{write}   = $pipe->{write};
    } else {
      $fcgi_pipes->[$pipe_counter]->{write} = $pipe->{write};
      $db_pipes->[$pipe_counter]->{read}    = $pipe->{read};

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

sub listen_pipe {
  my $rh = shift;
  my $response;

  my $bytes = sysread($rh, $response, READ_BUFFER_SIZE);
  chomp($response);

  $response = decode_json($response);

  return $response;
}

sub log_fork {
  my ($log_storage, $type, $pid, $pipe) = @_;

  $log_storage->{$pid} = {
              type  => $type,
              pipes => $pipe,
  };

  return;
}

## END of working with connections ###



## DB code ###

sub run_db {
  my $pipes = shift;

  my (%DB_USERS, %DB_SESSIONS);
  print "[$$-DB] Started";

  my $select_read_handler = add_all_read_handlers($pipes);;
  my %read_handler_to_write_handler_list = build_read_to_write_handlers_map($pipes);

  while(my @ready_to_read_handlers = $select_read_handler->can_read()) {
    foreach my $rh (@ready_to_read_handlers) {
      my $response_json = listen_pipe($rh);
      my $prepared_data = process_data($response_json, \%DB_USERS, \%DB_SESSIONS); #TODO Dont like this method

      define_write_handler_and_write_to_pipe($rh, \%read_handler_to_write_handler_list, $prepared_data); #TODO Dont like this method
    }
  }

  close_all_connections($pipes);
  exit(0);
}

sub add_all_read_handlers {
  my $pipes = shift;

  my $select_read_handler = IO::Select->new();

  foreach my $pipe (@$pipes) {
    $select_read_handler->add($pipe->{read});
  }

  return $select_read_handler;
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

sub define_write_handler_and_write_to_pipe {
  my $rh = shift;
  my $handlers = shift;
  my $prepared_data = shift;

  my $wh = $handlers->{fileno($rh)};
  print $wh $prepared_data;

  return 0;
}

sub process_data {
  my $args        = shift;
  my $DB_USERS    = shift;
  my $DB_SESSIONS = shift;

  my $response = {};
  my $encoded_response;

  if(is_save_surway($args)) {
    $response = process_save_surway($args, $DB_USERS, $DB_SESSIONS);
  } elsif(is_register_or_login($args)) {
    $response = process_register_or_login($args, $DB_USERS, $DB_SESSIONS)
  } elsif(is_logout($args)) {
    $response = process_logout($args, $DB_USERS, $DB_SESSIONS);
  } elsif(is_login_from_session($args)) {
    $response = process_login_from_session($args, $DB_USERS, $DB_SESSIONS);
  } else {
    print STDERR "[$$-DB] Dont know, how to process data";
  }

  $encoded_response = encode_json($response);

  return $encoded_response;
}

sub is_save_surway {
  return defined($_[0]->{surway});
}

sub is_register_or_login {
  return  (
            defined($_[0]->{sid}) &&
            defined($_[0]->{user_name}) &&
            defined($_[0]->{user_password})
          );
}

sub is_login_from_session {
  return defined($_[0]->{sid});
}

sub is_logout {
  return defined($_[0]->{logout});
}

sub is_valid_user_name {
  my $user_name = shift;

  if($user_name =~ (USER_NAME_PASS_PATTERN)) {
    return 1
  } else {
    return 0;
  }
}

sub process_register_or_login {
  my ($args, $DB_USERS, $DB_SESSIONS) = @_;

  my $sid      = $args->{sid};
  my $name     = $args->{user_name};
  my $password = $args->{user_password};

  if(!is_valid_user_name($name) || !is_valid_user_name($password)) {
    return { errors => { not_valid_format_of_name_or_password => 1 } };
  }

  if(exists($DB_USERS->{$name})) {
    if($DB_USERS->{$name}->{password} ne $password) {
      return { errors => { not_valid_password => 1 } };
    }
  } else {
      $DB_USERS->{$name} = { password => $password, surway => {} };
  }

  $DB_SESSIONS->{$sid} = $name;

  return {
      sid => $sid,
      user_name => $name,
      surway => $DB_USERS->{$name}->{surway}
  };
}

sub process_login_from_session {
  my ($args, $DB_USERS, $DB_SESSIONS) = @_;

  my $sid = $args->{sid};

  if(exists($DB_SESSIONS->{$sid})) {
    my $name = $DB_SESSIONS->{$sid};

    return {
        sid => $sid,
        user_name => $name,
        surway => $DB_USERS->{$name}->{surway},
    };
  } else {
    return { errors => { session_expired => 1 } };
  }
}

sub process_save_surway {
  my ($args, $DB_USERS, $DB_SESSIONS) = @_;

  my $sid    = $args->{sid};
  my $surway = $args->{surway};
  my $name;

  if(exists($DB_SESSIONS->{$sid})) {
    $name = $DB_SESSIONS->{$sid};

    $DB_USERS->{$name}->{surway} = $surway;
  } else {
    return { errors => { session_expired => 1 } };
  }

  return {
      sid => $sid,
      user_name => $name,
      surway => $surway,
  };
}

sub process_logout {
  my ($args, $DB_USERS, $DB_SESSIONS) = @_;

  my $sid = $args->{sid};

  if(exists($DB_SESSIONS->{$sid})) {
    delete $DB_SESSIONS->{$sid};
  }

  return { logout => 1 };
}

### END of DB code ###



### FCGI code ###

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

  while(my $request = CGI::Fast->new) {
    my $params = $request->Vars;
    my $response;
    my $query;
    my $sid;

    my %cookies = CGI::Cookie->fetch;
    unless($sid = eval{ $cookies{sid}->value }) {
      $sid = generate_random_string();
      set_onload_session_cookie($sid);
    }
    $params->{sid} = $sid;

    $query = prepare_request_to_db($params);
    $response = write_to_db($query, $READ_HANDLER, $WRITE_HANDLER);

    process_template($response);
  }
}

sub set_onload_session_cookie {
  my $sid = shift;

  my $cookie = CGI::Cookie->new(
    -name    =>  'sid',
    -value   =>  $sid,
    -expires =>  '+3M',
  );

  print "Set-Cookie: $cookie";
  return;
}

sub prepare_request_to_db {
  my $params = shift;
  my $query_data;

  $query_data = prepare_request_params_to_db($params);

  return encode_json($query_data);
}

sub prepare_request_params_to_db {
  my $params = shift;
  my ($surway, $query_data);

  $surway     = merge_surway_data($params);
  $query_data = merge_defined_params($params);

  $query_data->{surway} = $surway;

  return $query_data;
}

sub merge_surway_data {
  my $params = shift;
  my $surway;

  map { $_ =~ /surway/ ? ( ($surway->{$_} = $params->{$_}) && delete $params->{$_} ) : () } (keys %{$params});

  return $surway;
}

sub merge_defined_params {
  my $params = shift;
  my $query_data;

  map{ defined($params->{$_}) ? ($query_data->{$_} = trim($params->{$_})) : () } (keys %{$params});

  return $query_data;
}

sub write_to_db {
  my ($query, $READ_HANDLER, $WRITE_HANDLER) = @_;
  my $response;

  print $WRITE_HANDLER $query;
  $response = listen_pipe($READ_HANDLER);

  return $response;
}

sub process_template {
  my $args = shift;

  my $template = Template->new(INCLUDE_PATH => './htdocs/tpl');

  my $template_data = {
    pid              => "$$",
    args             => $args,
    surway_questions => (SURWAY_QUESTIONS),
  };

  print "Content-type:text/html;charset=utf-8\r\n\r\n";

  if (defined $args->{surway}) {
      $template->process('surway.tt', $template_data) or die($@);
  } else {
      $template->process('login.tt', $template_data) or die($@);
  }
}

### END of FCGI code ###

sub trim {
  my $string = shift;
  $string =~ s/^\s+|\s+$//g;
  return $string;
}

sub generate_random_string {
  return sprintf("%08X", rand(0xffffffff));
}
