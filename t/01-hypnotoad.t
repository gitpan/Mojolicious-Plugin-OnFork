#!/usr/bin/env perl

use Mojo::Base -strict;
use Test::More;
use File::Spec::Functions qw(catdir catfile);
use File::Temp 'tempdir';
use FindBin;
use IO::Socket::INET;
use Mojo::IOLoop::Server;
use Mojo::UserAgent;
use Mojo::Util 'spurt';

# Disable IPv6 and libev
BEGIN {
  $ENV{MOJO_NO_IPV6} = 1;
  $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll';
}

plan skip_all => 'set TEST_HYPNOTOAD to enable this test (developer only!)'
    unless $ENV{TEST_HYPNOTOAD};

# Find hypnotoad script
my ($p, $hypnotoad);
for (split ':', $ENV{PATH} || '.') {
    $p = catfile($_, 'hypnotoad');
    if (-x $p) { $hypnotoad = $p; last; }
};


plan skip_all => 'hypnotoad script not found - skipping this test'
    unless $hypnotoad;

# Prepare script
my $dir = tempdir CLEANUP => 1;
my $script = catdir $dir, 'myapp.pl';
my $port1  = Mojo::IOLoop::Server->generate_port;
my $port2  = Mojo::IOLoop::Server->generate_port;

spurt <<EOF, $script;
use Mojolicious::Lite;

plugin Config => {
    default => {
	hypnotoad => {
	    accepts => 1,
	    listen => ['http://127.0.0.1:$port1', 'http://127.0.0.1:$port2'],
	    workers => 2
	}
    }
};

app->log->level('fatal');

srand;

get '/' => sub {shift->render(text => \$\$ . ':' . rand)};

app->start;
EOF

open my $start, '-|', $^X, $hypnotoad, $script;
sleep 1
    until IO::Socket::INET->new(
	Proto    => 'tcp',
	PeerAddr => '127.0.0.1',
	PeerPort => $port2
    );
my $old = _pid();

my $ua = Mojo::UserAgent->new;
my (@pid, @rand);

# Application is alive
my $tx = $ua->get("http://127.0.0.1:$port1/");
ok $tx->is_finished, 'transaction is finished';
is $tx->res->code, 200, 'right status';
($pid[0], $rand[0]) = split ':', $tx->res->body, 2;

# Application is alive (second port)
$tx = $ua->get("http://127.0.0.1:$port2/");
ok $tx->is_finished, 'transaction is finished';
is $tx->res->code, 200, 'right status';
($pid[1], $rand[1]) = split ':', $tx->res->body, 2;
isnt $pid[1], $pid[0], 'second port was served by other worker';
is $rand[1], $rand[0], 'both workers return same random value';

# Same result
$tx = $ua->get("http://127.0.0.1:$port1/");
ok $tx->is_finished, 'transaction is finished';
is $tx->res->code, 200, 'right status';
($pid[2], $rand[2]) = split ':', $tx->res->body, 2;
is $pid[2], $pid[0], '2nd request on 1st port served by 1st worker';
isnt $rand[2], $rand[0], 'got a new random value';

# Same result (second port)
$tx = $ua->get("http://127.0.0.1:$port2/");
ok $tx->is_finished, 'transaction is finished';
is $tx->res->code, 200, 'right status';
($pid[3], $rand[3]) = split ':', $tx->res->body, 2;
is $pid[3], $pid[3], '2nd request on 2nd port served by 2nd worker';
is $rand[3], $rand[2], 'both workers return same random value';

# Update script
spurt <<EOF, $script;
use Mojolicious::Lite;

plugin Config => {
    default => {
	hypnotoad => {
	    accepts => 1,
	    listen => ['http://127.0.0.1:$port1', 'http://127.0.0.1:$port2'],
	    workers => 2
	}
    }
};

plugin OnFork => sub { srand };

app->log->level('fatal');

srand;

get '/' => sub {shift->render(text => \$\$ . ':' . rand)};

app->start;
EOF

open my $hot_deploy, '-|', $^X, $hypnotoad, $script;

# Remove keep alive connections
$ua = Mojo::UserAgent->new;

# Wait for hot deployment to finish
while (1) {
    sleep 1;
    next unless my $new = _pid();
    last if $new ne $old;
}

# Application has been reloaded
$tx = $ua->get("http://127.0.0.1:$port1/");
ok $tx->is_finished, 'transaction is finished';
is $tx->res->code, 200,            'right status';
($pid[0], $rand[0]) = split ':', $tx->res->body, 2;

# Application has been reloaded (second port)
$tx = $ua->get("http://127.0.0.1:$port2/");
ok $tx->is_finished, 'transaction is finished';
is $tx->res->code, 200,            'right status';
($pid[1], $rand[1]) = split ':', $tx->res->body, 2;
isnt $pid[1], $pid[0], 'second port was served by other worker';
isnt $rand[1], $rand[0], 'both workers return different random values';

# Same result
$tx = $ua->get("http://127.0.0.1:$port1/");
ok $tx->is_finished, 'transaction is finished';
is $tx->res->code, 200,            'right status';
($pid[2], $rand[2]) = split ':', $tx->res->body, 2;
is $pid[2], $pid[0], '2nd request on 1st port served by 1st worker';
isnt $rand[2], $rand[0], 'new random value differs from 1st random value';
isnt $rand[2], $rand[1], 'new random value differs from 2nd random value';

# Same result (second port)
$tx = $ua->get("http://127.0.0.1:$port2/");
ok $tx->is_finished, 'transaction is finished';
is $tx->res->code, 200,            'right status';
($pid[3], $rand[3]) = split ':', $tx->res->body, 2;
is $pid[3], $pid[3], '2nd request on 2nd port served by 2nd worker';
isnt $rand[3], $rand[0], 'new random value differs from 1st random value';
isnt $rand[3], $rand[1], 'new random value differs from 2nd random value';
isnt $rand[3], $rand[2], 'new random value differs from 3rd random value';

done_testing;

# Stop
open my $stop, '-|', $^X, $hypnotoad, $script, '-s';
sleep 1
    while IO::Socket::INET->new(
	Proto    => 'tcp',
	PeerAddr => '127.0.0.1',
	PeerPort => $port2
    );

sub _pid {
    return undef unless open my $file, '<', catdir($dir, 'hypnotoad.pid');
    my $pid = <$file>;
    chomp $pid;
    return $pid;
}
