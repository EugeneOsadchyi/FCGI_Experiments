#!/usr/bin/perl

use strict;
use warnings;

use FCGI;
use Data::Dumper;

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

    my $path    = $ARGV[0];
    my $backlog = int($ARGV[1]);
    my $count   = int($ARGV[2]);

    print "[$$-Manager] Starting...";

    my $socket = FCGI::OpenSocket($path, $backlog);
    if(!$socket) {
        print "[$$-Manager] Error. Failed to open socket.";
        exit();
    }

pipe(FCGI_READ, FCGI_WRITE);
pipe(DB_READ, DB_WRITE);

FCGI_WRITE->autoflush(1);
DB_WRITE->autoflush(1);

    my $pid;
    my %pids;

    unless ($pid = fork()) {
        close(FCGI_READ) or warn "[$$-DB] Can't close FCGI_READ";
        process_db(\*DB_READ, \*FCGI_WRITE);
        exit(0);
    }

    $pids{$pid} = 'DB';

    for (1..$count) {
        unless($pid = fork()) {
            close(DB_READ) or warn "[$$-FCGI] Can't close DB_READ";
            process_fcgi(\*FCGI_READ, \*DB_WRITE, $socket);
            exit(0);
        }
        $pids{$pid} = 'FCGI';
    }

    print "[$$-Manager] Stated all childs. Waiting for signal...\n";

    FCGI::CloseSocket($socket);

    print "[$$-Manager] Closed socket";
    sleep while(!$terminate);

    print "[$$-Manager] Terminating all FCGIs and exiting...\n";

    exit(0);
}

sub process_fcgi {
    my ($FCGI_READ, $DB_WRITE, $socket) = @_;

    print "[$$-FCGI] Created";

    my $count = 0;
    my $request = FCGI::Request(
       \*STDIN, \*STDOUT, \*STDERR,
       \%ENV, int($socket || 0), 1
    );

    while($request->Accept() >= 0) {
        print "Content-type:text/plain;charset=utf-8\r\n\r\n";
        print "[$$]";
        print "Counter: $count";
        ++$count;

        print $DB_WRITE "$count";
    }

    print "[$$-FCGI] Closing...";

    close($DB_WRITE)    or warn "[$$-FCGI] Can\'t close \$DB_WRITE. Reason: $@";
    close($FCGI_READ)   or warn "[$$-FCGI] Can\'t close \$FCGI_READ. Reason: $@";
}

sub process_db {
    my ($DB_READ, $FCGI_WRITE) = @_;
    my $data;

    print "[$$-DB] Started";

    my $response;
    while($response = <$DB_READ>) {
        chomp($response);
        #last if($response eq 'close');
        print STDOUT "[$$-DB] Response from FCGI: \"$response\"";
    }

    print "[$$-DB] Closing...";

    close($DB_READ)     or warn "[$$-DB] Can\'t close \$DB_READ";
    close($FCGI_WRITE)  or warn "[$$-DB] Can\'t close \$FCGI_WRITE";
}
