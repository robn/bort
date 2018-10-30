package Bort::Plugin::InteractiveSlack;

use 5.014;
use warnings;
use strict;
use Carp qw(croak);
use JSON::XS qw(encode_json decode_json);
use Twiggy::Server;
use Atto qw(handle_request);
use Data::Dumper;

Bort->add_context_method(add_interactive_listener => \&add_listener);

my $Server;
my @Waiting;

sub init {
  my $Config = Bort->config;
  unless ($Config->{legacy_token}) {
    die "InteractiveSlack requires a legacy_token config param\n";
  }
  my $IP = $Config->{ip} // "0.0.0.0";
  my $Port = $Config->{port} // 9999;
  $Server = Twiggy::Server->new(host => $IP, port => $Port);
  $Server->register_service(Atto->psgi);
  Bort->log("listening on $IP:$Port");
}

sub add_listener {
  my ($Ctx, %args) = @_;

  my $listener = $args{listener} || croak "No listener?!\n";
  push @Waiting, $listener;
}

sub handle_request {
  my %args = @_;

  my $event = $args{payload};
  unless ($event) {
    Bort->log("Odd request to InteractiveSlack");
    return { text => "" };
  }

  $event = eval { decode_json($event); };

  if ($@) {
    Bort->log("Failed to process InteractiveSlack event: $@");
    return { text => "" };
  }

  unless (ref $event eq 'HASH') {
    Bort->log("Got non hashref event: " . Dumper($event));
    return { text => "" };
  }

  unless ($event->{token} && $event->{token} eq Bort->config->{legacy_token}) {
    Bort->log("Event token is wrong ($event->{token})");
    return { text => "" };
  }

  for my $i (0..$#Waiting) {
    my $waiting = $Waiting[$i];

    if (my $res = $waiting->maybe_handle_event($event)) {
      if ($res->{response}) {
        # We're done, move on
        splice(@Waiting, $i, 1);

        return $res->{response};
      }
    }
  }

  # Didn't handle it? Leave the buttons around
  return { text => "" };
}

1;
