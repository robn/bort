# ABSTRACT: A pluggable Slack bot

use 5.014;
use warnings;
use strict;

# there's three packages in this file
#
# Bort: the public API for plugins. Everything in this package must be safe for
#     plugins to call
# Bort::App: the app startup and mainloop. This is only called from the run script
# Bort::Watch: the watch registry. The Add* methods are callable from plugins;
#        the corresponding methods in Bort delegate to these
#
# They're in the same file because there is some data they need to share, which
# are declared at the top (right below this comment).

# data shared across packages
my ($config, $log, $slack);


package Bort::App {

use AnyEvent;
use AnyEvent::Log ();
use AnyEvent::SlackRTM;

use Module::Pluggable ();

my @plugins;

sub init {
  my (undef, $config_file) = @_;

  $config = do {
    Config::Tiny->read($config_file)
      or die "bort: couldn't read config '$config_file': $!\n";
  };

  $config->{_}->{log} //= "stderr";
  if ($config->{_}->{log} eq "syslog") {
    AnyEvent::Log::ctx->log_to_syslog("local1");
  }
  else  {
    AnyEvent::Log::ctx->log_to_warn;
  }
  $log = AnyEvent::Log::logger("info");

  $log->("Loading plugins");

  my @search_path = ('Bort::Plugin');
  push @search_path, split(/\s+/, $config->{_}->{plugin_path}) if $config->{_}->{plugin_path};
  push @search_path, $ENV{BORT_PLUGIN_PATH} if $ENV{BORT_PLUGIN_PATH};

  Module::Pluggable->import(
    search_path => \@search_path,
    require => 1,
  );
  @plugins = __PACKAGE__->plugins;
}

sub run {
  for my $plugin (@plugins) {
    if ($plugin->can("init")) {
      $log->("Initialising plugin $plugin");
      $plugin->init;
    }
  }

  my $cv = AnyEvent->condvar;

  $slack = AnyEvent::SlackRTM->new($config->{_}->{slack_api_token});

  $slack->on(hello => sub {
    $log->("Slack says hello!");
    my $w; $w = AnyEvent->timer(interval => 300, cb => sub {
      $w if 0;
      Bort->load_names;
      Bort->load_team;
    });
  });

  $slack->on(finish => sub {
    $log->("Slack connection lost, exiting");
    $cv->send;
  });

  $slack->on(channel_joined => sub {
    my $data = pop @_;
    $log->("Joined channel $data->{channel}->{name}");
    Bort->load_names;
  });

  $slack->on(channel_left => sub {
    my $data = pop @_;
    $log->("Left channel $data->{channel}->{name}");
    Bort->load_names;
  });

  $slack->on(group_joined => sub {
    my $data = pop @_;
    $log->("Joined group $data->{group}->{name}");
    Bort->load_names;
  });

  $slack->on(group_left => sub {
    my $data = pop @_;
    $log->("Left group $data->{group}->{name}");
    Bort->load_names;
  });

  $slack->on(message => sub {
    my $data = pop @_;
    return if $data->{subtype}; # ignore bot chatter, joins, etc
    return if $data->{reply_to}; # ignore leftovers from previous connection

    # ignore messages from bots
    my $userdata = Bort->user_data($data->{user});
    return if $userdata && $userdata->{is_bot};

    Bort->process_slack_message($data);
  });

  $log->("Connecting to Slack...");
  $slack->start;

  $cv->recv;
}

}


package Bort::Watch {

use Try::Tiny;

my (@channel_watches, @direct_watches, @command_watches);

sub run_channel_watches {
  my (undef, $ctx, $text) = @_;
  my $matches = 0;
  for my $watch (@channel_watches) {
    next unless
      (ref $watch->[0] eq 'Regexp' && $text =~ m/$watch->[0]/) ||
      (ref $watch->[0] eq 'CODE' && $watch->[0]->($text));
    try {
      $watch->[1]->($ctx, $text);
    }
    catch {
      $log->("$watch->[2]: channel watch handler died: $_");
      $ctx->reply(":face_with_head_bandage: channel watch handler died, check the log");
    };
    $matches++;
  }
  return $matches;
}

sub run_direct_watches {
  my (undef, $ctx, $text) = @_;
  my $matches = 0;
  for my $watch (@direct_watches) {
    next unless
      (ref $watch->[0] eq 'Regexp' && $text =~ m/$watch->[0]/i) ||
      (ref $watch->[0] eq 'CODE' && $watch->[0]->($text));
    try {
      $watch->[1]->($ctx, $text);
    }
    catch {
      $log->("$watch->[2]: direct watch handler died: $_");
      $ctx->reply(":face_with_head_bandage: direct watch handler died, check the log");
    };
    $matches++;
  }
  return $matches;
}

sub run_command_watches {
  my (undef, $ctx, $text) = @_;
  $text =~ s{^\s*(.*)\s*$}{$1};
  $text =~ s{\s+}{ }g;
  my ($command, @args) = split ' ', $text;

  my $matches = 0;
  for my $watch (@command_watches) {
    next unless lc $watch->[0] eq lc $command;
    try {
      $watch->[1]->($ctx, @args);
    }
    catch {
      $log->("$watch->[2]: command watch handler died: $_");
      $ctx->reply(":face_with_head_bandage: command watch handler died, check the log");
    };
    $matches++;
  }
  return $matches;
}

sub add_channel_watch {
  my (undef, $match, $callback) = @_;
  my ($plugin) = caller =~ m{::([^:]+)$};
  $plugin //= caller;
  push @channel_watches, [ $match, $callback, $plugin ];
}

sub add_direct_watch {
  my (undef, $match, $callback) = @_;
  my ($plugin) = caller =~ m{::([^:]+)$};
  $plugin //= caller;
  push @direct_watches, [ $match, $callback, $plugin ];
}

sub add_command_watch {
  my (undef, $match, $callback) = @_;
  my ($plugin) = caller =~ m{::([^:]+)$};
  $plugin //= caller;
  push @command_watches, [ $match, $callback, $plugin ];
}

}


package Bort::MessageContext {

sub new {
  my ($class, %args) = @_;
  return bless \%args, $class;
}

sub channel { shift->{channel} }
sub user    { shift->{user} }
sub data    { shift->{data} }

sub channel_name { Bort->channel_name(shift->channel) }
sub user_name    { Bort->user_name(shift->user) }
sub user_data    { Bort->user_data(shift->user) }

sub message_id { shift->data->{ts} }
sub message_url {
  my ($self) = @_;
  sprintf("https://%s.slack.com/archives/%s/p%s%s",
    Bort->team->{domain},
    $self->channel_name,
    split('\.', $self->message_id),
  );
}

sub say {
  my ($self, @msg) = @_;
  Bort->send($self->channel, @msg);
}

sub reply {
  my ($self, @msg) = @_;
  Bort->send_direct($self->channel, $self->user, @msg);
}

sub reply_private {
  my ($self, @msg) = @_;
  Bort->slack_call("im.open", user => $self->user, sub {
    my $channel = shift->{channel}->{id};
    Bort->send($channel, @msg);
  });
}

}


package Bort {

use AnyEvent;
use AnyEvent::Socket ();
use AnyEvent::HTTP ();
use Net::DNS::Paranoid;
use JSON::XS qw(encode_json decode_json);
use WWW::Form::UrlEncoded::PP qw(build_urlencoded); # XXX workaround crash in ::XS
use Text::SlackEmoji;

sub AUTOLOAD {
  my ($plugin) = caller =~ m{::([^:]+)$};
  $plugin //= caller;
  use vars qw($AUTOLOAD);
  my ($method) = $AUTOLOAD =~ m{::([^:]+)$};
  Bort->log("$plugin called nonexistent method $method");
  return;
}

sub add_plugin_method {
  my (undef, $method, $sub) = @_;
  no strict 'refs';
  *{"Bort::$method"} = $sub;

  my ($plugin) = caller =~ m{::([^:]+)$};
  $plugin //= caller;
  $log->("$plugin: added plugin method $method");
}

sub add_context_method {
  my (undef, $method, $sub) = @_;
  no strict 'refs';
  *{"Bort::MessageContext::$method"} = $sub;

  my ($plugin) = caller =~ m{::([^:]+)$};
  $plugin //= caller;
  $log->("$plugin: added context method $method");
}

sub add_channel_watch { goto \&Bort::Watch::add_channel_watch }
sub add_direct_watch  { goto \&Bort::Watch::add_direct_watch }
sub add_command_watch { goto \&Bort::Watch::add_command_watch }

my ($my_user, $my_user_name);
my (%channel_names, %user_names);
my (%channel_by_name, %user_by_name);
my %user_data;
my %team_data;

sub load_names {
  ($my_user, $my_user_name) = @{$slack->metadata->{self}}{qw(id name)};
  $log->("Starting name/channels update...");
  Bort->slack_call("groups.list", sub {
    my %group_names = map { $_->{id} => $_->{name} } @{shift->{groups}};
    Bort->slack_call("channels.list", sub {
      %channel_names = (%group_names, map { $_->{id} => $_->{name} } @{shift->{channels}});
      %channel_by_name = reverse %channel_names;
      $log->(join(' ', scalar keys %channel_by_name, "channels loaded"));
    });
  });
  Bort->slack_call("users.list", sub {
    my $members = shift->{members};
    %user_data = map { $_->{id} => $_ } @$members;
    %user_names = map { $_->{id} => $_->{name} } @$members;
    %user_by_name = reverse %user_names;
    $log->(join(' ', scalar keys %user_by_name, "users loaded"));
    $my_user_name = $user_names{$my_user};
    $log->("My name is $my_user_name [$my_user]");
  });
}

sub load_team {
  $log->("Loading team info...");
  Bort->slack_call("team.info", sub {
    %team_data = %{shift->{team}};
  });
}


sub my_user      { $my_user }
sub channel_name { shift; my $channel = $_[-1]; $channel_names{$channel} // $channel }
sub user_name    { shift; my $user = $_[-1]; $user_names{$user} // $user }

sub my_user_name    { $my_user_name }
sub channel_by_name { $channel_by_name{$_[-1]} // $_[-1] };
sub user_by_name    { $user_by_name{$_[-1]} // $_[-1] };

sub user_data { shift; my $user = $_[-1]; $user_data{$user} }

sub team { \%team_data };

sub log {
  my (undef, @msg) = @_;
  my ($plugin) = caller =~ m{^Bort::Plugin::([^:]+)$};
  $plugin //= caller;

  my $name_match = join '|', map { "\Q$_\E" } (keys %channel_names, keys %user_names);
  my $name_re = qr/$name_match/;
  $log->("$plugin: $_") for map { s{\b($name_re)\b}{$channel_names{$1} // $user_names{$1} // $1}ger } @msg;
}

sub config {
  my ($plugin) = caller =~ m{^Bort::Plugin::([^:]+)$};
  $plugin //= caller;

  return $config->{$plugin};
}

sub send {
  my $attachments;
  $attachments = pop @_ if ref $_[-1];

  my (undef, $to, @msg) = @_;

  Bort->slack_call("chat.postMessage",
    as_user      => 1,
    channel      => $to,
    text         => join("\n", grep { defined } @msg),
    $attachments ? (attachments => encode_json($attachments)) : (),
    unfurl_links => "false",
  );
}

sub send_direct {
  my $attachments;
  $attachments = pop @_ if ref $_[-1];
  my (undef, $channel, $user, @msg) = @_;
  if (exists $channel_names{$channel}) {
    Bort->send($channel, "$user_names{$user}: ".(shift(@msg) // ''), @msg, $attachments);
  }
  else {
    Bort->send($channel, @msg, $attachments);
  }
}

# Bort->http_request(...)
# Same args as AnyEvent::HTTP::http_request
# Fills in some args if not provided:
#   headers->user-agent: bort/0.01
#   cookie_jar: in-memory cookie store for whole bot
#   tcp_connect: "paranoid" connects, fail against internal hosts
sub http_request {
  my $callback = sub {};
  $callback = pop @_ if ref $_[-1] eq 'CODE';
  my (undef, $method, $url, %args) = @_;

  state $cookie_jar = {};
  state $dns = Net::DNS::Paranoid->new;

  state $user_agent = 'bort/'.($Bort::VERSION // 'dev');

  $args{headers} //= {};
  $args{headers}->{"user-agent"} //= $user_agent;

  $args{cookie_jar} //= $cookie_jar;

  $args{tcp_connect} //= sub ($$$;$) {
    my ($host, $port, $connect, $prepare) = @_;
    my ($ip, $error) = $dns->resolve($host);
    if ($error) {
      Bort->log("error resolving $host $error");
      return;
    }
    AnyEvent::Socket::tcp_connect($ip->[0], $port, $connect, $prepare);
  };

  $url = "$url"; # stringify URI objects

  Bort->log("doing $method request to $url") unless $args{_quiet};

  AnyEvent::HTTP::http_request($method => $url, %args, sub {
    my ($body, $headers) = @_;
    unless ($headers->{Status} =~ m/^2/) {
      Bort->log("request failed: $headers->{Status} $headers->{Reason}");
    }
    $callback->($body, $headers);
  });
}

sub slack_call {
  my $callback = sub {};
  $callback = pop @_ if ref $_[-1] eq 'CODE';
  my (undef, $method, %args) = @_;

  $args{token} = $config->{_}->{slack_api_token};

  my $url = "https://slack.com/api/$method";

  Bort->http_request(
    POST => $url,
    body => build_urlencoded(\%args),
    headers => {
      "content-type" => "application/x-www-form-urlencoded",
    },
    _quiet => 1,
    sub {
      # XXX error checking
      my $data = decode_json(shift);
      $callback->($data);
    }
  );
}

sub process_slack_message {
  my (undef, $data) = @_;

  my $channel = $data->{channel};
  my $user = $data->{user};

  my $ctx = Bort::MessageContext->new(
    channel => $channel,
    user    => $user,
    data    => $data,
  );

  my ($name, $text) = $data->{text} =~ m/^(${\Bort->my_user_name})\s*[,:;\s]\s*(.+)/i;
  unless (defined $name) {
    (my $user, $text) = $data->{text} =~ m/^<@([^>]+)>\s*[,:;\s]\s*(.+)/i;
    $name = $user_names{$user} if defined $user;
  }
  $text = $data->{text} unless defined $text;

  # XXX hardcoded, really?
  my @unknown_responses = (
    "Sorry, what's that?",
    "Wat?",
    "Hmm?",
    "Nope.",
    "I got nothing.",
    "Yeah, nah.",
    "I could try, but it's probably not going to work.",
    "No, you do it.",
    "I can't!",
    "It's too hard!",
    "But it's cold outside and I'm frightened!",
  );

  if ((defined $name && $name eq $my_user_name) || !exists $channel_names{$channel}) {
    my $matches =
      Bort::Watch->run_direct_watches($ctx, $text) +
      Bort::Watch->run_command_watches($ctx, $text);
    $ctx->reply(":thinking_face: $unknown_responses[int(rand(scalar @unknown_responses))]") unless $matches;
  }

  Bort::Watch->run_channel_watches($ctx, $data->{text});
}

# https://api.slack.com/docs/formatting#how_to_display_formatted_messages
sub flatten_slack_text {
  my (undef, $text) = @_;

  my $emoji = Text::SlackEmoji->emoji_map;

  $text =~ s/<[^|]+\|([^>]+)>/$1/g;
  $text =~ s{:([-+a-z0-9_]+):}{$emoji->{$1} // ":$1:"}ge;
  $text =~ s{#(C\w{8})}{'#'.Bort->channel_name($1)}ge;
  $text =~ s{\@(U\w{8})}{'@'.Bort->user_name($1)}ge;
  # XXX ! special
  $text =~ s/<([^>]+)>/$1/g;
  $text =~ s/&lt;/</g;
  $text =~ s/&gt;/>/g;
  $text =~ s/&amp;/&/g;

  return $text;
}

}

1;
