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
my ($Config, $Log, $Slack);


package Bort::App {

use AnyEvent;
use AnyEvent::Log;
use AnyEvent::SlackRTM;

use Module::Pluggable ();

my @Plugins;

sub Init {
  my (undef, $ConfigFile) = @_;

  $Config = do {
    Config::Tiny->read($ConfigFile)
      or die "bort: couldn't read config '$ConfigFile': $!\n";
  };

  $Config->{_}->{log} //= "stderr";
  if ($Config->{_}->{log} eq "syslog") {
    AnyEvent::Log::ctx->log_to_syslog("local1");
  }
  else  {
    AnyEvent::Log::ctx->log_to_warn;
  }
  $Log = AnyEvent::Log::logger("info");

  $Log->("Loading plugins");

  my @SearchPath = ('Bort::Plugin');
  push @SearchPath, split(/\s+/, $Config->{_}->{plugin_path}) if $Config->{_}->{plugin_path};
  push @SearchPath, $ENV{BORT_PLUGIN_PATH} if $ENV{BORT_PLUGIN_PATH};

  Module::Pluggable->import(
    search_path => \@SearchPath,
    require => 1,
  );
  @Plugins = __PACKAGE__->plugins;
}

sub Run {
  for my $Plugin (@Plugins) {
    if ($Plugin->can("Init")) {
      $Log->("Initialising plugin $Plugin");
      $Plugin->Init;
    }
  }

  my $C = AnyEvent->condvar;

  $Slack = AnyEvent::SlackRTM->new($Config->{_}->{slack_api_token});

  $Slack->on(hello => sub {
    $Log->("Slack says hello!");
    my $W; $W = AnyEvent->timer(interval => 300, cb => sub {
      $W if 0;
      Bort->LoadNames();
    });
  });

  $Slack->on(finish => sub {
    $Log->("Slack connection lost, exiting");
    $C->send;
  });

  $Slack->on(channel_joined => sub {
    my $Data = pop @_;
    $Log->("Joined channel $Data->{channel}->{name}");
    Bort->LoadNames();
  });

  $Slack->on(channel_left => sub {
    my $Data = pop @_;
    $Log->("Left channel $Data->{channel}->{name}");
    Bort->LoadNames();
  });

  $Slack->on(group_joined => sub {
    my $Data = pop @_;
    $Log->("Joined group $Data->{group}->{name}");
    Bort->LoadNames();
  });

  $Slack->on(group_left => sub {
    my $Data = pop @_;
    $Log->("Left group $Data->{group}->{name}");
    Bort->LoadNames();
  });

  $Slack->on(message => sub {
    my $Data = pop @_;
    return if $Data->{subtype}; # ignore bot chatter, joins, etc
    return if $Data->{reply_to}; # ignore leftovers from previous connection
    return if $Data->{user} eq $Slack->metadata->{self}->{id}; # ignore messages from myself

    Bort->ProcessSlackMessage($Data);
  });

  $Log->("Connecting to Slack...");
  $Slack->start;

  $C->recv;
}

}


package Bort::Watch {

use Try::Tiny;

my (@ChannelWatches, @DirectWatches, @CommandWatches);

sub RunChannelWatches {
  my (undef, $Text) = @_;
  my $Matches = 0;
  for my $Watch (@ChannelWatches) {
    next unless
      (ref $Watch->[0] eq 'Regexp' && $Text =~ m/$Watch->[0]/) ||
      (ref $Watch->[0] eq 'CODE' && $Watch->[0]->($Text));
    try {
      $Watch->[1]->($Text);
    }
    catch {
      $Log->("$Watch->[2]: channel watch handler died: $_");
      Bort->Reply(":face_with_head_bandage: channel watch handler died, check the log");
    };
    $Matches++;
  }
  return $Matches;
}

sub RunDirectWatches {
  my (undef, $Text) = @_;
  my $Matches = 0;
  for my $Watch (@DirectWatches) {
    next unless
      (ref $Watch->[0] eq 'Regexp' && $Text =~ m/$Watch->[0]/i) ||
      (ref $Watch->[0] eq 'CODE' && $Watch->[0]->($Text));
    try {
      $Watch->[1]->($Text);
    }
    catch {
      $Log->("$Watch->[2]: direct watch handler died: $_");
      Bort->Reply(":face_with_head_bandage: direct watch handler died, check the log");
    };
    $Matches++;
  }
  return $Matches;
}

sub RunCommandWatches {
  my (undef, $Text) = @_;
  $Text =~ s{^\s*(.*)\s*$}{$1};
  $Text =~ s{\s+}{ }g;
  my ($Command, @Args) = split ' ', $Text;

  my $Matches = 0;
  for my $Watch (@CommandWatches) {
    next unless lc $Watch->[0] eq lc $Command;
    try {
      $Watch->[1]->(@Args);
    }
    catch {
      $Log->("$Watch->[2]: command watch handler died: $_");
      Bort->Reply(":face_with_head_bandage: command watch handler died, check the log");
    };
    $Matches++;
  }
  return $Matches;
}

sub AddChannelWatch {
  my (undef, $Match, $Callback) = @_;
  my ($Plugin) = caller =~ m{::([^:]+)$};
  $Plugin //= caller;
  push @ChannelWatches, [ $Match, $Callback, $Plugin ];
}

sub AddDirectWatch {
  my (undef, $Match, $Callback) = @_;
  my ($Plugin) = caller =~ m{::([^:]+)$};
  $Plugin //= caller;
  push @DirectWatches, [ $Match, $Callback, $Plugin ];
}

sub AddCommandWatch {
  my (undef, $Match, $Callback) = @_;
  my ($Plugin) = caller =~ m{::([^:]+)$};
  $Plugin //= caller;
  push @CommandWatches, [ $Match, $Callback, $Plugin ];
}

}


package Bort {

use AnyEvent;
use AnyEvent::Socket;
use AnyEvent::HTTP;
use Net::DNS::Paranoid;
use JSON::XS qw(encode_json decode_json);
use WWW::Form::UrlEncoded::PP qw(build_urlencoded); # XXX workaround crash in ::XS

sub AUTOLOAD {
  my ($Plugin) = caller =~ m{::([^:]+)$};
  $Plugin //= caller;
  use vars qw($AUTOLOAD);
  my ($Method) = $AUTOLOAD =~ m{::([^:]+)$};
  Bort->Log("$Plugin called nonexistent method $Method");
  return;
}

sub AddPluginMethod {
  my (undef, $Method, $Sub) = @_;
  no strict 'refs';
  *{"Bort::$Method"} = $Sub;

  my ($Plugin) = caller =~ m{::([^:]+)$};
  $Plugin //= caller;
  $Log->("$Plugin: added plugin method $Method");
}

sub AddChannelWatch { goto \&Bort::Watch::AddChannelWatch }
sub AddDirectWatch  { goto \&Bort::Watch::AddDirectWatch }
sub AddCommandWatch { goto \&Bort::Watch::AddCommandWatch }

my ($MyUser, $MyUserName);
my (%ChannelNames, %UserNames);
my (%ChannelByName, %UserByName);
my %UserData;

sub LoadNames {
  ($MyUser, $MyUserName) = @{$Slack->metadata->{self}}{qw(id name)};
  $Log->("Starting name/channels update...");
  Bort->SlackCall("groups.list", sub {
    my %GroupNames = map { $_->{id} => $_->{name} } @{shift->{groups}};
    Bort->SlackCall("channels.list", sub {
      %ChannelNames = (%GroupNames, map { $_->{id} => $_->{name} } @{shift->{channels}});
      %ChannelByName = reverse %ChannelNames;
      $Log->(join(' ', scalar keys %ChannelByName, "channels loaded"));
    });
  });
  Bort->SlackCall("users.list", sub {
    my $Members = shift->{members};
    %UserData = map { $_->{id} => $_ } @$Members;
    %UserNames = map { $_->{id} => $_->{name} } @$Members;
    %UserByName = reverse %UserNames;
    $Log->(join(' ', scalar keys %UserByName, "users loaded"));
    $MyUserName = $UserNames{$MyUser};
    $Log->("My name is $MyUserName [$MyUser]");
  });
}

my ($CurrentChannel, $CurrentUser, $CurrentMessageData);

sub MyUser    { $MyUser };
sub Channel   { $CurrentChannel }
sub ChannelName { shift; my $Channel = $_[-1] // $CurrentChannel; $ChannelNames{$Channel} // $Channel }
sub User    { $CurrentUser }
sub UserName  { shift; my $User = $_[-1] // $CurrentUser; $UserNames{$User} // $User }
sub MessageId   { $CurrentMessageData->{ts} };

sub MyUserName  { $MyUserName }
sub ChannelByName { $ChannelByName{$_[-1]} // $_[-1] };
sub UserByName  { $UserByName{$_[-1]} // $_[-1] };

sub UserData { shift; my $User = $_[-1] // $CurrentUser; $UserData{$User} }

sub Log {
  my (undef, @Msg) = @_;
  my ($Plugin) = caller =~ m{::([^:]+)$};
  $Plugin //= caller;

  my $NameMatch = join '|', map { "\Q$_\E" } (keys %ChannelNames, keys %UserNames);
  my $NameRE = qr/$NameMatch/;
  $Log->("$Plugin: $_") for map { s{\b($NameRE)\b}{$ChannelNames{$1} // $UserNames{$1} // $1}ger } @Msg;
}

sub Config {
  my ($Plugin) = caller =~ m{^^Bort::Plugin::([^:]+)$};
  $Plugin //= caller;

  return $Config->{$Plugin};
}

sub Send {
  my $Attachments;
  $Attachments = pop @_ if ref $_[-1];

  my (undef, $To, @Msg) = @_;

  Bort->SlackCall("chat.postMessage",
    as_user      => 1,
    channel      => $To,
    text         => join("\n", grep { defined } @Msg),
    $Attachments ? (attachments => encode_json($Attachments)) : (),
    unfurl_links => "false",
  );
}

sub SendDirect {
  my $Attachments;
  $Attachments = pop @_ if ref $_[-1];
  my (undef, $Channel, $User, @Msg) = @_;
  if (exists $ChannelNames{$Channel}) {
    Bort->Send($Channel, "$UserNames{$User}: ".(shift(@Msg) // ''), @Msg, $Attachments);
  }
  else {
    Bort->Send($Channel, @Msg, $Attachments);
  }
}

sub Say {
  my (undef, @Msg) = @_;
  Bort->Send(Bort->Channel, @Msg);
}

sub Reply {
  my (undef, @Msg) = @_;
  Bort->SendDirect(Bort->Channel, Bort->User, @Msg);
}

sub ReplyPrivate {
  my (undef, @Msg) = @_;
  Bort->SlackCall("im.open", user => Bort->User, sub {
    my $Channel = shift->{channel}->{id};
    Bort->Send($Channel, @Msg);
  });
}

# Bort->HttpRequest(...)
# Same args as AnyEvent::HTTP::http_request
# Fills in some args if not provided:
#   headers->user-agent: bort/0.01
#   cookie_jar: in-memory cookie store for whole bot
#   tcp_connect: "paranoid" connects, fail against internal hosts
sub HttpRequest {
  my $Callback = sub {};
  $Callback = pop @_ if ref $_[-1] eq 'CODE';
  my (undef, $Method, $URL, %Args) = @_;

  state $CookieJar = {};
  state $DNS = do {
    my $DNS = Net::DNS::Paranoid->new;
    $DNS->blocked_hosts(qr/^[a-z0-9-]+$/i, qr/\.internal$/i);
    $DNS
  };

  $Args{headers} //= {};
  $Args{headers}->{"user-agent"} //= "bort/0.01";

  $Args{cookie_jar} //= $CookieJar;

  $Args{tcp_connect} //= sub {
    my (undef, $Error) = $DNS->resolve($_[0]);
    if ($Error) {
      Bort->Log("error resolving $_[0]: $Error");
      return;
    }
    goto \&tcp_connect;
  };

  $URL = "$URL"; # stringify URI objects

  Bort->Log("doing $Method request to $URL") unless $Args{_quiet};

  http_request($Method => $URL, %Args, sub {
    my ($Body, $Hdr) = @_;
    unless ($Hdr->{Status} =~ m/^2/) {
      Bort->Log("request failed: $Hdr->{Status} $Hdr->{Reason}");
    }
    $Callback->($Body, $Hdr);
  });
}

sub SlackCall {
  my $Callback = sub {};
  $Callback = pop @_ if ref $_[-1] eq 'CODE';
  my (undef, $Method, %Args) = @_;

  $Args{token} = $Config->{_}->{slack_api_token};

  my $URL = "https://slack.com/api/$Method";

  Bort->HttpRequest(
    POST => $URL,
    body => build_urlencoded(\%Args),
    headers => {
      "content-type" => "application/x-www-form-urlencoded",
    },
    _quiet => 1,
    sub {
      # XXX error checking
      my $Data = decode_json(shift);
      $Callback->($Data);
    }
  );
}

sub ProcessSlackMessage {
  my (undef, $Data) = @_;

  my $Channel = $Data->{channel};
  my $User = $Data->{user};

  $CurrentChannel = $Channel;
  $CurrentUser = $User;
  $CurrentMessageData = $Data;

  my ($Name, $Text) = $Data->{text} =~ m/^(${\Bort->MyUserName}).?\s*(.+)/i;
  unless (defined $Name) {
    (my $User, $Text) = $Data->{text} =~ m/^<@([^>]+)>.?\s*(.+)/i;
    $Name = $UserNames{$User} if defined $User;
  }
  $Text = $Data->{text} unless defined $Text;

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

  if ((defined $Name && $Name eq Bort->MyUserName) || !exists $ChannelNames{$Channel}) {
    my $Matches =
      Bort::Watch->RunDirectWatches($Text) +
      Bort::Watch->RunCommandWatches($Text);
    Bort->Reply(":thinking_face: $unknown_responses[int(rand(scalar @unknown_responses))]") unless $Matches;
  }

  Bort::Watch->RunChannelWatches($Data->{text});
}

# https://api.slack.com/docs/formatting#how_to_display_formatted_messages
sub FlattenSlackText {
  my (undef, $Text) = @_;
  $Text =~ s/<[^|]+\|([^>]+)>/$1/g;
  # XXX #C channel ref
  # XXX @U user ref
  # XXX ! special
  $Text =~ s/<([^>]+)>/$1/g;
  $Text =~ s/&lt;/</g;
  $Text =~ s/&gt;/>/g;
  $Text =~ s/&amp;/&/g;
  return $Text;
}

}

1;
